import AppKit
import Foundation

/// Starts the already installed local embedding runtime when its dedicated port is absent.
@MainActor
final class AgentEmbeddingService {
    struct Configuration: Decodable {
        let endpoint: String
        let applicationBundleID: String
        let executableRelativePath: String
        let manifestRelativePath: String
        let requestTimeoutSeconds: Double
        let maximumLaunchAttempts: Int

        /// Accepts only the packaged local runtime and the existing embedding model.
        var isValid: Bool {
            endpoint == "http://127.0.0.1:18741"
                && applicationBundleID == "com.electron.ollama"
                && executableRelativePath == "Contents/Resources/ollama"
                && manifestRelativePath == "manifests/registry.ollama.ai/library/qwen3-embedding/0.6b"
                && requestTimeoutSeconds > 0 && requestTimeoutSeconds <= 2
                && (1...3).contains(maximumLaunchAttempts)
        }
    }

    private struct Manifest: Decodable {
        struct Blob: Decodable { let digest: String; let size: Int64 }
        let config: Blob
        let layers: [Blob]
    }

    static let shared = AgentEmbeddingService()
    private let configuration: Configuration?
    private let models: URL
    private var child: Process?
    private var identity: AgentIndexProcessIdentity?
    private var generation = 0
    private var attempts = 0
    private var probing = false

    /// Resolves packaged settings without starting a process or downloading a model.
    private init() {
        if let url = Bundle.main.url(forResource: "AgentEmbeddingConfig", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode(Configuration.self, from: data), value.isValid {
            configuration = value
        } else { configuration = nil }
        models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.profileDirectoryName)
            .appendingPathComponent("agent-index/models", isDirectory: true)
    }

    /// Reuses a listener or makes a bounded attempt to start the installed local runtime.
    ///
    /// Returns:
    ///   Nothing. Missing software, models or a failed runtime remain visible through
    ///   AgentsView's embedding status while lexical search stays available.
    func ensureAvailable() async {
        guard !probing, let configuration, !Task.isCancelled else { return }
        if let child, child.isRunning { return }
        let owner = generation
        probing = true
        defer { if generation == owner { probing = false } }
        guard await portIsAbsent(configuration), generation == owner, !Task.isCancelled,
              attempts < configuration.maximumLaunchAttempts,
              Self.modelFilesExist(in: models, manifestPath: configuration.manifestRelativePath),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: configuration.applicationBundleID),
              Bundle(url: application)?.bundleIdentifier == configuration.applicationBundleID else { return }
        let executable = application.appendingPathComponent(configuration.executableRelativePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        attempts += 1
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "OLLAMA_HOST": "127.0.0.1:18741",
            "OLLAMA_MODELS": models.path,
            "OLLAMA_NO_CLOUD": "1",
            "OLLAMA_NOPRUNE": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        do {
            try process.run()
            child = process
            identity = AgentIndexProcessIdentity.read(pid: process.processIdentifier)
            if identity == nil {
                if process.isRunning { process.terminate() }
                child = nil
            }
        } catch {
            child = nil
            identity = nil
        }
    }

    /// Stops only a runtime started by this service; a preexisting listener is never signalled.
    func stop() {
        generation &+= 1
        probing = false
        attempts = 0
        if let child, child.isRunning, let identity,
           AgentIndexProcessIdentity.read(pid: identity.pid) == identity {
            child.terminate()
        }
        child = nil
        identity = nil
    }

    /// Checks all manifest-referenced blobs without loading model weights into memory.
    ///
    /// Args:
    ///   directory: Private model cache prepared during installation.
    ///   manifestPath: Validated model manifest path relative to the cache.
    ///
    /// Returns:
    ///   Whether the manifest and each expected local blob exist at the recorded size.
    static func modelFilesExist(in directory: URL, manifestPath: String) -> Bool {
        guard !manifestPath.hasPrefix("/"), !manifestPath.split(separator: "/").contains("..") else { return false }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let url = directory.appendingPathComponent(manifestPath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 65_536, let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.layers.isEmpty, manifest.layers.count <= 32 else { return false }
        return ([manifest.config] + manifest.layers).allSatisfy { blob in
            guard blob.digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
                  blob.size > 0 else { return false }
            let file = directory.appendingPathComponent("blobs")
                .appendingPathComponent(blob.digest.replacingOccurrences(of: ":", with: "-"))
                .resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return false }
            return values.isRegularFile == true && values.fileSize.map(Int64.init) == blob.size
        }
    }

    /// Probes the dedicated local port without treating a timeout or unknown listener as permission to replace it.
    ///
    /// Args:
    ///   configuration: Validated local endpoint and two-second maximum deadline.
    ///
    /// Returns:
    ///   True only when the OS reports that no service accepts a connection.
    private func portIsAbsent(_ configuration: Configuration) async -> Bool {
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        options.urlCache = nil
        options.httpCookieStorage = nil
        options.httpShouldSetCookies = false
        options.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        options.timeoutIntervalForResource = configuration.requestTimeoutSeconds
        let session = URLSession(configuration: options, delegate: EmbeddingProbeNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: configuration.endpoint + "/api/version") else { return false }
        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeoutSeconds)
        request.httpMethod = "HEAD"
        do {
            _ = try await session.data(for: request)
            return false
        } catch let error as URLError { return error.code == .cannotConnectToHost }
        catch { return false }
    }
}

private final class EmbeddingProbeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Keeps the local health probe on its original endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
