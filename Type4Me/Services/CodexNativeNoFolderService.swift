import AppKit
import Darwin
import Foundation

/// Opens Codex's native folderless composer through its document-opening entry point.
actor CodexNativeNoFolderService {
    struct Configuration: Codable, Sendable {
        var timeoutSeconds: Double = 15
        var pollIntervalSeconds: Double = 0.1
        var maximumRetainedRequests = 4_096
        var maximumPromptUTF16Units = 4_000
        var maximumPromptBytes = 16_000
        var maximumURLBytes = 48_000
        var maximumStateBytes = 4_194_304
        var maximumLogBytes = 2_097_152
        var maximumLogFiles = 256
        var maximumLogLineBytes = 65_536
        var logReadChunkBytes = 65_536
        var logLookbackDays = 2

        /// Reads the packaged non-secret limits without hiding missing or invalid resources.
        ///
        /// Args:
        ///   bundle: Application bundle containing the production configuration.
        ///
        /// Returns:
        ///   Validated native-opening limits.
        ///
        /// Raises:
        ///   AgentDesktopLauncherError: The packaged resource is absent or invalid.
        static func bundled(in bundle: Bundle = .main) throws -> Self {
            guard let url = bundle.url(forResource: "CodexNativeNoFolderConfig", withExtension: "json") else {
                throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
            }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try value.validate()
            return value
        }

        /// Rejects settings that could permit unbounded reads, retention, or waiting.
        ///
        /// Raises:
        ///   AgentDesktopLauncherError: A configured bound is invalid.
        func validate() throws {
            guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60,
                  pollIntervalSeconds.isFinite, pollIntervalSeconds > 0, pollIntervalSeconds <= timeoutSeconds,
                  (1...16_384).contains(maximumRetainedRequests),
                  (1...16_000).contains(maximumPromptUTF16Units),
                  (1...65_536).contains(maximumPromptBytes),
                  (1...131_072).contains(maximumURLBytes),
                  (1...16_777_216).contains(maximumStateBytes),
                  (1...16_777_216).contains(maximumLogBytes),
                  (1...1_024).contains(maximumLogFiles),
                  maximumLogLineBytes > 0, maximumLogLineBytes <= maximumLogBytes,
                  logReadChunkBytes > 0, logReadChunkBytes <= maximumLogBytes,
                  (1...3).contains(logLookbackDays) else {
                throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
            }
        }
    }

    enum ServiceError: LocalizedError, Equatable {
        case retentionLimit

        var errorDescription: String? {
            L("任务附件存储已满，暂时无法从 MyType 新建无文件夹任务。",
              "Task attachment storage is full. MyType cannot create another folderless task yet.")
        }
    }

    typealias Sleep = @Sendable (Double) async throws -> Void
    typealias ApplicationValidator = @Sendable (URL) -> Bool
    typealias ApplicationOpener = @Sendable (URL, URL, TimeInterval) async throws -> Void
    typealias LogFilesProvider = @Sendable (Date, Configuration) throws -> [URL]

    static let shared = CodexNativeNoFolderService()
    private let homeDirectory: URL
    private let requestRootDirectory: URL
    private let configuration: Configuration?
    private let applicationValidator: ApplicationValidator
    private let applicationOpener: ApplicationOpener
    private let logFilesProvider: LogFilesProvider?
    private let sleep: Sleep
    private var isOpening = false

    /// Creates a native opener with injectable operating-system boundaries.
    ///
    /// Args:
    ///   homeDirectory: Home containing native Codex state and logs.
    ///   requestRootDirectory: Private task-attachment store; never used as a workspace.
    ///   configuration: Explicit test limits, or nil to require the packaged resource.
    ///   applicationValidator: Optional bundle identity verifier.
    ///   applicationOpener: Optional native document/deep-link opener.
    ///   logFilesProvider: Optional bounded log-file discovery for fixtures.
    ///   sleep: Optional polling wait for deterministic cancellation tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requestRootDirectory: URL? = nil,
        configuration: Configuration? = nil,
        applicationValidator: ApplicationValidator? = nil,
        applicationOpener: ApplicationOpener? = nil,
        logFilesProvider: LogFilesProvider? = nil,
        sleep: Sleep? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.requestRootDirectory = requestRootDirectory ?? AppIdentity.appSupportDirectory()
            .appendingPathComponent("LaunchRequests/Codex", isDirectory: true)
        self.configuration = configuration
        self.applicationValidator = applicationValidator ?? {
            AgentDesktopLauncherService.isValidApplication(at: $0, bundleIdentifier: AgentDesktopApplication.codex.bundleIdentifier)
        }
        self.applicationOpener = applicationOpener ?? Self.openNativeURL
        self.logFilesProvider = logFilesProvider
        self.sleep = sleep ?? { try await Task.sleep(for: .seconds($0)) }
    }

    /// Opens a native No Folder draft and confirms its persisted target state without sending.
    ///
    /// Native logs lack a request ID. A fresh document event plus exact project and
    /// prompt state confirms the draft's observable state, not unique event attribution,
    /// attachment binding, thread creation, or message delivery.
    ///
    /// Args:
    ///   applicationURL: Verified Codex desktop bundle.
    ///   prompt: Exact original task, also retained as the draft's text attachment.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: Native receipts or app identity cannot be confirmed.
    ///   ServiceError: Retained task attachments reached the configured capacity.
    ///   CancellationError: The caller cancelled; previously opened attachments remain intact.
    func open(applicationURL: URL, prompt: String) async throws {
        try Task.checkCancellation()
        guard !isOpening else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        isOpening = true
        defer { isOpening = false }
        let config: Configuration
        do {
            config = try configuration ?? Configuration.bundled()
            try config.validate()
        } catch { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !prompt.contains("\0") else {
            throw AgentDesktopLauncherError.invalidPrompt
        }
        guard prompt.utf16.count <= config.maximumPromptUTF16Units, prompt.utf8.count <= config.maximumPromptBytes else {
            throw AgentDesktopLauncherError.promptTooLong
        }
        guard applicationValidator(applicationURL) else { throw AgentDesktopLauncherError.applicationRemoved(.codex) }
        let destination = try Self.draftURL(prompt: prompt, configuration: config)
        let startedAt = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + config.timeoutSeconds
        var cursors = try captureLogCursors(at: startedAt, configuration: config)
        let taskFilename = Self.taskFilename
        let request = try createRequest(prompt: prompt, filename: taskFilename, configuration: config)
        var exposed = false
        do {
            try checkDeadline(deadline)
            try writeRecord(request, filename: taskFilename, status: "opening", createdAt: startedAt)
            // Once opening is attempted, the original app may hold this attachment indefinitely.
            exposed = true
            try await applicationOpener(applicationURL, request.appendingPathComponent(taskFilename), remaining(deadline))
            var receiptSeen = false
            var scannedBytes = 0
            while true {
                try checkDeadline(deadline)
                if !receiptSeen {
                    receiptSeen = try consumeFileReceipt(
                        cursors: &cursors, scannedBytes: &scannedBytes, since: startedAt, configuration: config
                    )
                }
                if receiptSeen, try readState(configuration: config)?.isProjectless == true { break }
                try await sleep(min(config.pollIntervalSeconds, remaining(deadline)))
            }
            guard applicationValidator(applicationURL),
                  try readState(configuration: config)?.isProjectless == true else {
                throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
            }
            try checkDeadline(deadline)
            try await applicationOpener(applicationURL, destination, remaining(deadline))
            while true {
                try checkDeadline(deadline)
                // Codex does not rewrite an identical prompt. Unrelated state-file
                // writes cannot strengthen this check: only the target state matters.
                if let state = try readState(configuration: config), state.isProjectless, state.prompt == prompt {
                    try writeRecord(request, filename: taskFilename, status: "draft-state-confirmed", createdAt: startedAt)
                    DebugFileLogger.log("codex native no-folder draft_state_confirmed=true request=\(request.lastPathComponent)")
                    return
                }
                try await sleep(min(config.pollIntervalSeconds, remaining(deadline)))
            }
        } catch {
            if exposed {
                do { try writeRecord(request, filename: taskFilename, status: error is CancellationError ? "cancelled" : "unverified", createdAt: startedAt) }
                catch { DebugFileLogger.log("codex native no-folder receipt_write_failed=true") }
            } else {
                do { try FileManager.default.removeItem(at: request) }
                catch { DebugFileLogger.log("codex native no-folder unexposed_cleanup_failed=true") }
            }
            if error is CancellationError { throw CancellationError() }
            DebugFileLogger.log("codex native no-folder draft_state_confirmed=false request=\(request.lastPathComponent)")
            throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
        }
    }

    private static var taskFilename: String { AppLanguage.current == .zh ? "任务.txt" : "Task.txt" }

    /// Creates a path-free native link while preserving literal plus signs and newlines.
    private static func draftURL(prompt: String, configuration: Configuration) throws -> URL {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [URLQueryItem(name: "mode", value: "codex"), URLQueryItem(name: "prompt", value: prompt)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.absoluteString.utf8.count <= configuration.maximumURLBytes else {
            throw AgentDesktopLauncherError.promptTooLong
        }
        return url
    }

    /// Fails before another side effect after cancellation or the shared opening deadline.
    private func checkDeadline(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard remaining(deadline) > 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
    }

    /// Returns the remaining monotonic time for the current attempt.
    private func remaining(_ deadline: TimeInterval) -> TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    /// Retains a private original-task attachment without inventing an agent workspace.
    private func createRequest(prompt: String, filename: String, configuration: Configuration) throws -> URL {
        try Self.ensurePrivateDirectory(requestRootDirectory)
        guard chmod(requestRootDirectory.path, 0o700) == 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        let entries = try FileManager.default.contentsOfDirectory(at: requestRootDirectory, includingPropertiesForKeys: nil)
        guard entries.count < configuration.maximumRetainedRequests else {
            DebugFileLogger.log("codex native no-folder retention_limit_reached=true")
            throw ServiceError.retentionLimit
        }
        let directory = requestRootDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try Self.writePrivateFile(Data(prompt.utf8), to: directory.appendingPathComponent(filename))
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Creates missing private container components and rejects linked or foreign directories.
    private static func ensurePrivateDirectory(_ url: URL) throws {
        var attributes = stat()
        if lstat(url.path, &attributes) != 0 {
            guard errno == ENOENT, url.path != "/" else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
            try ensurePrivateDirectory(url.deletingLastPathComponent())
            guard mkdir(url.path, 0o700) == 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
            return
        }
        guard attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_uid == getuid() else {
            throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
        }
    }

    /// Writes one new mode-0600 attachment or receipt without following a destination symlink.
    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    /// Updates non-secret request metadata while keeping its original task attachment immutable.
    private func writeRecord(_ directory: URL, filename: String, status: String, createdAt: Date) throws {
        let record: [String: Any] = ["schema": 1, "requestID": directory.lastPathComponent,
                                     "createdAt": createdAt.timeIntervalSince1970, "status": status,
                                     "attachment": filename, "submitted": false]
        let temporary = directory.appendingPathComponent(".receipt-\(UUID().uuidString).json")
        try Self.writePrivateFile(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys), to: temporary)
        guard rename(temporary.path, directory.appendingPathComponent("receipt.json").path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
        }
    }

    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        /// Captures file identity and revision without storing file content.
        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            seconds = value.st_mtimespec.tv_sec
            nanoseconds = value.st_mtimespec.tv_nsec
        }
    }

    private struct LogCursor {
        var stamp: FileStamp
        var offset: UInt64
        var pending = Data()
    }

    private struct NativeState {
        let isProjectless: Bool
        let prompt: String?
    }

    /// Opens only a regular file owned by this user and captures its descriptor-backed identity.
    private static func ownedFile(_ url: URL) throws -> (FileHandle, FileStamp) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size >= 0 else {
            Darwin.close(descriptor)
            throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), FileStamp(attributes))
    }

    /// Lists a bounded set of recent native logs without recursively scanning the user profile.
    private func logFiles(at date: Date, configuration: Configuration) throws -> [URL] {
        if let logFilesProvider {
            let files = try logFilesProvider(date, configuration)
            guard files.count <= configuration.maximumLogFiles else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
            return files
        }
        let root = homeDirectory.appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var result: [URL] = []
        for day in 0..<configuration.logLookbackDays {
            guard let date = calendar.date(byAdding: .day, value: -day, to: date) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let directory = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            result += files.filter { $0.pathExtension == "log" }
            guard result.count <= configuration.maximumLogFiles else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        }
        return result
    }

    /// Records EOF positions before opening so historical receipts cannot authorize this task.
    private func captureLogCursors(at date: Date, configuration: Configuration) throws -> [URL: LogCursor] {
        var cursors: [URL: LogCursor] = [:]
        for url in try logFiles(at: date, configuration: configuration) {
            let (handle, stamp) = try Self.ownedFile(url)
            try handle.close()
            cursors[url] = LogCursor(stamp: stamp, offset: UInt64(stamp.size))
        }
        return cursors
    }

    /// Reads only appended native log bytes and accepts a fresh document-opening receipt.
    private func consumeFileReceipt(
        cursors: inout [URL: LogCursor], scannedBytes: inout Int,
        since: Date, configuration: Configuration
    ) throws -> Bool {
        var found = false
        for url in try logFiles(at: Date(), configuration: configuration) {
            let (handle, stamp) = try Self.ownedFile(url)
            defer { try? handle.close() }
            var cursor = cursors[url] ?? LogCursor(stamp: stamp, offset: 0)
            if cursor.stamp.device != stamp.device || cursor.stamp.inode != stamp.inode || cursor.offset > UInt64(stamp.size) {
                cursor = LogCursor(stamp: stamp, offset: 0)
            }
            try handle.seek(toOffset: cursor.offset)
            while cursor.offset < UInt64(stamp.size) {
                let capacity = configuration.maximumLogBytes - scannedBytes
                guard capacity > 0 else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
                let count = min(configuration.logReadChunkBytes, capacity, Int(UInt64(stamp.size) - cursor.offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard !data.isEmpty else { break }
                cursor.offset += UInt64(data.count)
                scannedBytes += data.count
                cursor.pending.append(data)
                while let newline = cursor.pending.firstIndex(of: 10) {
                    let line = cursor.pending[..<newline]
                    if line.count <= configuration.maximumLogLineBytes,
                       let text = String(data: line, encoding: .utf8), Self.isFileReceipt(text, since: since) {
                        found = true
                    }
                    cursor.pending.removeSubrange(...newline)
                }
                guard cursor.pending.count <= configuration.maximumLogLineBytes else {
                    throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)
                }
            }
            cursor.stamp = stamp
            cursors[url] = cursor
        }
        return found
    }

    /// Rejects embedded log text and stale timestamps when recognizing the native receipt.
    private static func isFileReceipt(_ line: String, since: Date) -> Bool {
        guard let space = line.firstIndex(of: " "),
              line[line.index(after: space)...] == "info Opened desktop files in projectless task fileCount=1 fileExtensions=[\"txt\"]" else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let timestamp = formatter.date(from: String(line[..<space])) else { return false }
        let minimum = floor(since.timeIntervalSince1970 * 1_000) / 1_000
        return timestamp.timeIntervalSince1970 >= minimum
    }

    /// Reads only bounded native state and extracts project selection plus the new draft's text.
    private func readState(configuration: Configuration) throws -> NativeState? {
        let url = homeDirectory.appendingPathComponent(".codex/.codex-global-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (handle, stamp) = try Self.ownedFile(url)
        defer { try? handle.close() }
        guard stamp.size <= configuration.maximumStateBytes else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        let data = try handle.read(upToCount: configuration.maximumStateBytes + 1) ?? Data()
        guard data.count <= configuration.maximumStateBytes else { throw AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex) }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, FileStamp(after) == stamp,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let atoms = value["electron-persisted-atom-state"] as? [String: Any]
        let drafts = atoms?["composer-prompt-drafts-v2"] as? [String: Any]
        let draft = drafts?["new-conversation"]
        let prompt: String?
        if let draft = draft as? String { prompt = draft }
        else if let object = draft as? [String: Any] {
            if let text = object["prompt"] as? String { prompt = text }
            else if let stored = object["prompt"] as? [String: Any], let document = stored["document"] as? [String: Any] {
                prompt = Self.documentText(document)
            } else { prompt = nil }
        } else { prompt = nil }
        return NativeState(isProjectless: value["selected-project"] is NSNull, prompt: prompt)
    }

    /// Extracts plain paragraph text without ignoring unknown nodes or attachment mentions.
    private static func documentText(_ document: [String: Any]) -> String? {
        guard document["type"] as? String == "doc", let blocks = document["content"] as? [[String: Any]] else { return nil }
        var paragraphs: [String] = []
        for block in blocks {
            guard block["type"] as? String == "paragraph" else { return nil }
            var paragraph = ""
            for node in (block["content"] as? [[String: Any]]) ?? [] {
                switch node["type"] as? String {
                case "text":
                    guard let text = node["text"] as? String else { return nil }
                    paragraph += text
                case "hard_break", "hardBreak": paragraph += "\n"
                default: return nil
                }
            }
            paragraphs.append(paragraph)
        }
        return paragraphs.joined(separator: "\n")
    }

    /// Uses the named application for documents and links without UI automation or keyboard input.
    private static func openNativeURL(applicationURL: URL, destination: URL, timeout: TimeInterval) async throws {
        let completion = CodexNativeOpenCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation)
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        completion.finish(.failure(AgentDesktopLauncherError.nativeNoFolderUnavailable(.codex)))
                    } catch {}
                }
                completion.setTimer(timer)
                Task { @MainActor in
                    guard !completion.isFinished else { return }
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = true
                    NSWorkspace.shared.open([destination], withApplicationAt: applicationURL, configuration: options) { app, error in
                        if error == nil, app != nil { completion.finish(.success(())) }
                        else { completion.finish(.failure(AgentDesktopLauncherError.launchFailed(.codex))) }
                    }
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }
}

/// Completes a native opening once, including cancellation before macOS calls back.
private final class CodexNativeOpenCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    /// Installs the waiter, preserving cancellation that arrived first.
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    /// Retains the timeout task only while its opening is pending.
    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.timer = timer }
        lock.unlock()
        if finished { timer.cancel() }
    }

    /// Resumes the first result and ignores late callbacks without repeating an open.
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
