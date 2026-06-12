import AppKit
import Darwin
import Foundation

struct CmuxSurfaceTarget: Equatable, Sendable {
    let workspaceID: String
    let surfaceID: String
    let tty: String?
    let windowID: String?

    /// Creates a cmux terminal surface target.
    ///
    /// Args:
    ///   workspaceID: cmux workspace identifier or reference.
    ///   surfaceID: cmux surface identifier or reference.
    ///   tty: Optional terminal tty used for fallback matching.
    ///   windowID: Optional cmux window identifier or reference.
    init(workspaceID: String, surfaceID: String, tty: String?, windowID: String? = nil) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.tty = tty
        self.windowID = windowID
    }
}

struct CmuxCommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

final class CmuxCommandClient: @unchecked Sendable {
    static let bundleID = "com.cmuxterm.app"
    static let defaultCommandTimeoutMilliseconds = 5_000
    static let windowReadyPollInterval: TimeInterval = 0.2
    static let windowReadyPollAttempts = 30

    private let executableURLProvider: @Sendable () -> URL?
    private let processRunner: @Sendable (URL, [String], [String: String]) -> CmuxCommandResult?
    private let rpcRunner: (String, [String: Any]) -> [String: Any]?
    private let appLauncher: @Sendable () -> Bool
    private let sleeper: @Sendable (TimeInterval) -> Void
    private let homeDirectory: URL
    private let userName: String

    /// Creates a cmux command client.
    ///
    /// Args:
    ///   homeDirectory: Home directory used to resolve cmux socket state.
    ///   userName: macOS account name used for the child process environment.
    ///   executableURLProvider: Resolver for the installed cmux executable.
    ///   processRunner: Injected command runner used by tests.
    ///   rpcRunner: Injected cmux RPC runner used by tests.
    ///   appLauncher: cmux app launcher injected by tests.
    ///   sleeper: Sleep hook injected by tests to avoid real waits.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userName: String = NSUserName(),
        executableURLProvider: @escaping @Sendable () -> URL? = {
            CmuxCommandClient.defaultExecutableURL()
        },
        processRunner: @escaping @Sendable (URL, [String], [String: String]) -> CmuxCommandResult? = {
            executableURL, arguments, environment in
            CmuxCommandClient.runProcess(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            )
        },
        rpcRunner: ((String, [String: Any]) -> [String: Any]?)? = nil,
        appLauncher: @escaping @Sendable () -> Bool = {
            CmuxCommandClient.openCmuxApplication()
        },
        sleeper: @escaping @Sendable (TimeInterval) -> Void = { duration in
            Thread.sleep(forTimeInterval: duration)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.executableURLProvider = executableURLProvider
        self.processRunner = processRunner
        self.appLauncher = appLauncher
        self.sleeper = sleeper
        if let rpcRunner {
            self.rpcRunner = rpcRunner
        } else {
            let socketPath = Self.defaultSocketPath(homeDirectory: homeDirectory)
            self.rpcRunner = { method, params in
                Self.runSocketRPC(socketPath: socketPath, method: method, params: params)
            }
        }
    }

    /// Sends text to a cmux terminal surface.
    ///
    /// Args:
    ///   text: Text to send before the terminal Enter escape.
    ///   target: cmux workspace and surface target.
    ///
    /// Returns:
    ///   `true` when cmux accepted the command.
    func send(text: String, to target: CmuxSurfaceTarget) -> Bool {
        let params = targetParams(for: target)
            .merging(["text": "\(text)\n"]) { _, new in new }
        return rpc(method: "surface.send_text", params: params) != nil
    }

    /// Focuses a cmux terminal surface.
    ///
    /// Args:
    ///   target: cmux workspace and surface target.
    ///
    /// Returns:
    ///   `true` when cmux accepted the focus commands.
    @discardableResult
    func focus(target: CmuxSurfaceTarget) -> Bool {
        guard let windowID = target.windowID ?? selectedWindowID() else {
            return false
        }
        guard rpc(
            method: "workspace.select",
            params: [
                "window_id": windowID,
                "workspace_id": target.workspaceID,
            ]
        ) != nil else {
            return false
        }
        return rpc(
            method: "surface.focus",
            params: [
                "window_id": windowID,
                "workspace_id": target.workspaceID,
                "surface_id": target.surfaceID,
            ]
        ) != nil
    }

    /// Creates a cmux workspace running a command in a directory.
    ///
    /// Args:
    ///   name: Workspace title.
    ///   cwd: Working directory path.
    ///   command: Shell command to run in the new workspace.
    ///
    /// Returns:
    ///   `true` when cmux accepted the workspace creation command.
    @discardableResult
    func newWorkspace(name: String, cwd: String, command: String) -> Bool {
        guard let windowID = ensureWindowReady() else {
            return false
        }
        guard let result = run(arguments: [
            "workspace", "create",
            "--name", name,
            "--cwd", cwd,
            "--command", command,
            "--window", windowID,
            "--focus", "true",
        ]) else {
            return false
        }
        if result.terminationStatus != 0 {
            DebugFileLogger.log(
                "CmuxCommandClient: new-workspace failed status=\(result.terminationStatus) stderr=\(result.stderr.prefix(240))"
            )
        }
        return result.terminationStatus == 0
    }

    /// Ensures cmux is running and has at least one window.
    ///
    /// Returns:
    ///   Selected cmux window ID after opening cmux if needed.
    func ensureWindowReady() -> String? {
        if let windowID = selectedWindowID() {
            return windowID
        }
        guard appLauncher() else {
            DebugFileLogger.log("CmuxCommandClient: failed to launch cmux application")
            return nil
        }
        for _ in 0..<Self.windowReadyPollAttempts {
            sleeper(Self.windowReadyPollInterval)
            if let windowID = selectedWindowID() {
                return windowID
            }
        }
        DebugFileLogger.log("CmuxCommandClient: cmux window did not become ready")
        return nil
    }

    /// Resolves the currently focused cmux terminal target.
    ///
    /// Returns:
    ///   Focused target from `cmux identify --json`, or `nil` when unavailable.
    func focusedSurfaceTarget() -> CmuxSurfaceTarget? {
        guard let payload = rpc(method: "system.identify", params: ["no_caller": true]) else {
            return nil
        }
        return Self.focusedSurfaceTarget(fromIdentifyPayload: payload)
    }

    /// Resolves the selected cmux window for GUI-launched commands.
    ///
    /// Returns:
    ///   Selected/key window identifier, or the first listed window when cmux
    ///   does not mark one as key.
    func selectedWindowID() -> String? {
        guard let payload = rpc(method: "window.list", params: [:]) else {
            return nil
        }
        return Self.selectedWindowID(fromWindowListPayload: payload)
    }

    /// Runs a cmux RPC method and returns its result dictionary.
    ///
    /// Args:
    ///   method: cmux RPC method name.
    ///   params: JSON-compatible method parameters.
    ///
    /// Returns:
    ///   Result dictionary when the RPC call succeeds.
    func rpc(method: String, params: [String: Any]) -> [String: Any]? {
        rpcRunner(method, params)
    }

    /// Runs a cmux command and parses stdout as a JSON dictionary.
    ///
    /// Args:
    ///   arguments: Arguments passed after the cmux executable.
    ///
    /// Returns:
    ///   Parsed JSON payload when command output contains a JSON object.
    func runJSON(arguments: [String]) -> [String: Any]? {
        guard let result = run(arguments: arguments),
              result.terminationStatus == 0 else {
            return nil
        }
        return Self.jsonDictionary(from: result.stdout)
    }

    /// Runs a cmux command with the configured executable and environment.
    ///
    /// Args:
    ///   arguments: Arguments passed after the cmux executable.
    ///
    /// Returns:
    ///   Captured command result, or `nil` when cmux is not installed or launch fails.
    func run(arguments: [String]) -> CmuxCommandResult? {
        guard let executableURL = executableURLProvider() else {
            DebugFileLogger.log("CmuxCommandClient: cmux executable not found")
            return nil
        }
        return processRunner(
            executableURL,
            arguments,
            Self.commandEnvironment(homeDirectory: homeDirectory, userName: userName)
        )
    }

    /// Returns the cmux CLI text argument that appends Enter.
    ///
    /// Args:
    ///   text: Reply text to submit.
    ///
    /// Returns:
    ///   Text argument using cmux's literal `\n` escape.
    static func sendArgument(for text: String) -> String {
        "\(text)\\n"
    }

    /// Finds the focused terminal target in `identify` output.
    ///
    /// Args:
    ///   payload: Parsed `cmux identify --json` payload.
    ///
    /// Returns:
    ///   Focused terminal target, if available.
    static func focusedSurfaceTarget(fromIdentifyPayload payload: [String: Any]) -> CmuxSurfaceTarget? {
        guard let focused = payload["focused"] as? [String: Any] else {
            return nil
        }
        if let surfaceType = focused["surface_type"] as? String,
           surfaceType != "terminal" {
            return nil
        }
        guard let workspaceID = firstString(in: focused, keys: ["workspace_id", "workspace_ref"]),
              let surfaceID = firstString(in: focused, keys: ["surface_id", "surface_ref"]) else {
            return nil
        }
        return CmuxSurfaceTarget(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            tty: nil,
            windowID: firstString(in: focused, keys: ["window_id", "window_ref"])
        )
    }

    /// Finds a terminal target by matching a tty in `debug-terminals` output.
    ///
    /// Args:
    ///   payload: Parsed `cmux debug-terminals --json` payload.
    ///   matchingTTY: Bare tty name or full `/dev` path.
    ///
    /// Returns:
    ///   Matching terminal target, if available.
    static func surfaceTarget(
        fromDebugTerminalsPayload payload: [String: Any],
        matchingTTY: String
    ) -> CmuxSurfaceTarget? {
        guard let terminals = payload["terminals"] as? [[String: Any]] else {
            return nil
        }
        let targetTTY = normalizedTTYPath(matchingTTY)
        for terminal in terminals {
            guard let tty = terminal["tty"] as? String,
                  normalizedTTYPath(tty) == targetTTY,
                  let workspaceID = firstString(in: terminal, keys: ["workspace_ref", "workspace_id"]),
                  let surfaceID = firstString(in: terminal, keys: ["surface_ref", "surface_id"]) else {
                continue
            }
            return CmuxSurfaceTarget(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                tty: normalizedTTYPath(tty),
                windowID: firstString(in: terminal, keys: ["window_ref", "window_id"])
            )
        }
        return nil
    }

    /// Selects a cmux window from `cmux list-windows --json` output.
    ///
    /// Args:
    ///   output: Raw JSON array emitted by cmux.
    ///
    /// Returns:
    ///   Key/selected window ID, falling back to the first window ID.
    static func selectedWindowID(fromListWindowsOutput output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !windows.isEmpty else {
            return nil
        }

        let preferred = windows.first { window in
            (window["key"] as? Bool) == true || (window["selected"] as? Bool) == true
        } ?? windows[0]
        return firstString(in: preferred, keys: ["id", "ref", "window_id", "window_ref"])
    }

    /// Selects a cmux window from `window.list` RPC output.
    ///
    /// Args:
    ///   payload: RPC result containing a `windows` array.
    ///
    /// Returns:
    ///   Key/selected window ID, falling back to the first window ID.
    static func selectedWindowID(fromWindowListPayload payload: [String: Any]) -> String? {
        guard let windows = payload["windows"] as? [[String: Any]],
              !windows.isEmpty else {
            return nil
        }

        let preferred = windows.first { window in
            (window["key"] as? Bool) == true || (window["selected"] as? Bool) == true
        } ?? windows[0]
        return firstString(in: preferred, keys: ["id", "ref", "window_id", "window_ref"])
    }

    /// Returns a clean environment for cmux CLI child processes.
    ///
    /// Args:
    ///   homeDirectory: Home directory used to locate the cmux socket.
    ///   userName: Current macOS user name.
    ///
    /// Returns:
    ///   Minimal environment without GUI `XPC_*` or stale caller `CMUX_*` state.
    static func commandEnvironment(homeDirectory: URL, userName: String) -> [String: String] {
        return [
            "HOME": homeDirectory.path,
            "USER": userName,
            "LOGNAME": userName,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "CMUX_SOCKET_PATH": defaultSocketPath(homeDirectory: homeDirectory),
        ]
    }

    /// Resolves cmux's default Unix socket path.
    ///
    /// Args:
    ///   homeDirectory: User home directory.
    ///
    /// Returns:
    ///   Default cmux socket path.
    static func defaultSocketPath(homeDirectory: URL) -> String {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
    }

    /// Opens the cmux macOS application.
    ///
    /// Args:
    ///   fileManager: File manager used to validate fallback app paths.
    ///   workspace: Workspace API used to locate and open cmux.
    ///
    /// Returns:
    ///   `true` when macOS accepted the app open request.
    static func openCmuxApplication(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) -> Bool {
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return workspace.open(appURL)
        }
        let fallbackURL = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)
        guard fileManager.fileExists(atPath: fallbackURL.path) else {
            return false
        }
        return workspace.open(fallbackURL)
    }

    /// Resolves the installed cmux executable.
    ///
    /// Returns:
    ///   Executable URL when cmux is installed.
    static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let candidate = cliExecutableURL(inAppAt: appURL)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            let bundleExecutable = executableURL(inAppAt: appURL)
            if fileManager.isExecutableFile(atPath: bundleExecutable.path) {
                return bundleExecutable
            }
        }

        let fallbackCLI = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
        if fileManager.isExecutableFile(atPath: fallbackCLI.path) {
            return fallbackCLI
        }
        let fallbackExecutable = URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux")
        return fileManager.isExecutableFile(atPath: fallbackExecutable.path) ? fallbackExecutable : nil
    }

    /// Builds the cmux CLI URL inside a cmux app bundle.
    ///
    /// Args:
    ///   appURL: cmux `.app` bundle URL.
    ///
    /// Returns:
    ///   Expected bundled cmux CLI URL.
    static func cliExecutableURL(inAppAt appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
    }

    /// Builds the executable URL inside a cmux app bundle.
    ///
    /// Args:
    ///   appURL: cmux `.app` bundle URL.
    ///
    /// Returns:
    ///   Expected cmux executable URL.
    static func executableURL(inAppAt appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
    }

    /// Parses a JSON dictionary from command stdout.
    ///
    /// Args:
    ///   output: Raw stdout that may include a leading notice before JSON.
    ///
    /// Returns:
    ///   JSON dictionary, if decoding succeeds.
    static func jsonDictionary(from output: String) -> [String: Any]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String]
        if let firstBrace = trimmed.firstIndex(of: "{") {
            candidates = [trimmed, String(trimmed[firstBrace...])]
        } else {
            candidates = [trimmed]
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return dictionary
        }
        DebugFileLogger.log("CmuxCommandClient: json parse failed output=\(trimmed.prefix(240))")
        return nil
    }

    /// Normalizes a tty name into a full device path.
    ///
    /// Args:
    ///   tty: Bare tty name or full `/dev` path.
    ///
    /// Returns:
    ///   Full `/dev/ttys*` path when possible.
    static func normalizedTTYPath(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String,
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    /// Builds standard cmux RPC target parameters for a surface.
    ///
    /// Args:
    ///   target: cmux workspace and surface target.
    ///
    /// Returns:
    ///   RPC parameters containing workspace, surface, and optional window IDs.
    private func targetParams(for target: CmuxSurfaceTarget) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": target.workspaceID,
            "surface_id": target.surfaceID,
        ]
        if let windowID = target.windowID {
            params["window_id"] = windowID
        }
        return params
    }

    /// Calls cmux's Unix-socket JSON RPC endpoint.
    ///
    /// Args:
    ///   socketPath: Absolute path to the cmux Unix socket.
    ///   method: cmux RPC method name.
    ///   params: JSON-compatible method parameters.
    ///
    /// Returns:
    ///   The RPC result dictionary when cmux returns `ok: true`.
    private static func runSocketRPC(
        socketPath: String,
        method: String,
        params: [String: Any]
    ) -> [String: Any]? {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            DebugFileLogger.log("CmuxCommandClient: socket create failed errno=\(errno)")
            return nil
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            DebugFileLogger.log("CmuxCommandClient: socket path too long path=\(socketPath)")
            return nil
        }
        _ = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, source, maxPathLength - 1)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            DebugFileLogger.log("CmuxCommandClient: socket connect failed errno=\(errno) path=\(socketPath)")
            return nil
        }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard var requestData = try? JSONSerialization.data(withJSONObject: request) else {
            DebugFileLogger.log("CmuxCommandClient: rpc request encode failed method=\(method)")
            return nil
        }
        requestData.append(0x0A)
        guard writeAll(requestData, to: descriptor) else {
            DebugFileLogger.log("CmuxCommandClient: rpc write failed method=\(method) errno=\(errno)")
            return nil
        }
        guard let responseData = readLine(from: descriptor) else {
            DebugFileLogger.log("CmuxCommandClient: rpc read failed method=\(method) errno=\(errno)")
            return nil
        }
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            let raw = String(data: responseData, encoding: .utf8) ?? ""
            DebugFileLogger.log("CmuxCommandClient: rpc response parse failed method=\(method) response=\(raw.prefix(240))")
            return nil
        }
        guard (response["ok"] as? Bool) == true else {
            DebugFileLogger.log("CmuxCommandClient: rpc failed method=\(method) error=\(String(describing: response["error"]))")
            return nil
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    /// Writes all bytes to a socket descriptor.
    ///
    /// Args:
    ///   data: Request bytes to write.
    ///   descriptor: Unix socket descriptor.
    ///
    /// Returns:
    ///   `true` when every byte was written.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
    }

    /// Reads one newline-delimited JSON response from a socket descriptor.
    ///
    /// Args:
    ///   descriptor: Unix socket descriptor.
    ///
    /// Returns:
    ///   Response bytes without the trailing newline, or `nil` on read failure.
    private static func readLine(from descriptor: Int32) -> Data? {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
                if let newlineIndex = response.firstIndex(of: 0x0A) {
                    return response[..<newlineIndex]
                }
                continue
            }
            if count == 0 {
                return response.isEmpty ? nil : response
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    }

    /// Runs one cmux child process and captures its output.
    ///
    /// Args:
    ///   executableURL: Installed cmux executable URL.
    ///   arguments: Arguments passed after the executable.
    ///   environment: Clean child process environment.
    ///
    /// Returns:
    ///   Captured command result, or `nil` when launch or timeout handling fails.
    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxCommandResult? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("mytype-cmux-\(UUID().uuidString).stdout")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("mytype-cmux-\(UUID().uuidString).stderr")

        do {
            try Data().write(to: outputURL)
            try Data().write(to: errorURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
                try? fileManager.removeItem(at: outputURL)
                try? fileManager.removeItem(at: errorURL)
            }

            process.standardOutput = outputHandle
            process.standardError = errorHandle

            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            try process.run()

            let timeout = DispatchTime.now() + .milliseconds(defaultCommandTimeoutMilliseconds)
            guard semaphore.wait(timeout: timeout) == .success else {
                process.terminate()
                _ = semaphore.wait(timeout: .now() + .milliseconds(200))
                DebugFileLogger.log(
                    "CmuxCommandClient: command timed out executable=\(executableURL.path) args=\(arguments.joined(separator: " "))"
                )
                return nil
            }

            let stdout = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            if process.terminationStatus != 0 {
                DebugFileLogger.log(
                    "CmuxCommandClient: command failed args=\(arguments.joined(separator: " ")) status=\(process.terminationStatus) stderr=\(stderr.prefix(240))"
                )
            }
            return CmuxCommandResult(
                stdout: stdout,
                stderr: stderr,
                terminationStatus: process.terminationStatus
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
            DebugFileLogger.log("CmuxCommandClient: launch failed error=\(error.localizedDescription)")
            return nil
        }
    }
}
