import AppKit
import Darwin
import Foundation

enum AgentDesktopApplication: String, CaseIterable, Codable, Sendable {
    case codex
    case claudeCode

    static let storageKey = "tf_agentLauncherApplication"
    static let defaultValue: AgentDesktopApplication = .codex

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .codex: return "com.openai.codex"
        case .claudeCode: return "com.anthropic.claudefordesktop"
        }
    }

    var applicationNames: [String] {
        switch self {
        case .codex: return ["ChatGPT.app", "Codex.app"]
        case .claudeCode: return ["Claude.app"]
        }
    }
}

struct AgentDesktopInstallation: Equatable, Sendable {
    let application: AgentDesktopApplication
    let applicationURL: URL?
    let commandURL: URL?

    var isInstalled: Bool { applicationURL != nil }
}

enum AgentDesktopLauncherError: LocalizedError, Equatable {
    case applicationNotInstalled(AgentDesktopApplication)
    case applicationRemoved(AgentDesktopApplication)
    case invalidProject(String)
    case invalidSessionIdentifier
    case unsupportedSession(AgentDesktopApplication)
    case invalidDestination
    case launchFailed(AgentDesktopApplication)
    case launchTimedOut(AgentDesktopApplication)

    var errorDescription: String? { message(language: AppLanguage.current) }

    /// Renders a launcher failure in the current or explicitly selected language.
    ///
    /// Args:
    ///   language: Language used to render the message.
    ///
    /// Returns:
    ///   A user-facing explanation with no terminal fallback instructions.
    func message(language: AppLanguage) -> String {
        let isChinese = language == .zh
        switch self {
        case .applicationNotInstalled(let application):
            return isChinese
                ? "未检测到 \(application.displayName) 桌面应用，请先安装后重试。"
                : "\(application.displayName) desktop app was not found. Install it and try again."
        case .applicationRemoved(let application):
            return isChinese
                ? "\(application.displayName) 桌面应用已移动或移除，请重新检测后重试。"
                : "\(application.displayName) desktop app was moved or removed. Refresh detection and try again."
        case .invalidProject(let path):
            return isChinese
                ? "项目目录不可用：\(path)"
                : "Project directory is unavailable: \(path)"
        case .invalidSessionIdentifier:
            return isChinese ? "会话标识无效，无法打开该会话。" : "The chat identifier is invalid."
        case .unsupportedSession(let application):
            return isChinese
                ? "暂不支持直接打开 \(application.displayName) 的指定会话。"
                : "Opening a specific \(application.displayName) chat is not supported yet."
        case .invalidDestination:
            return isChinese ? "无法创建桌面应用打开链接。" : "Could not create the desktop app link."
        case .launchFailed(let application):
            return isChinese
                ? "无法打开 \(application.displayName)，请检查应用后重试。"
                : "Could not open \(application.displayName). Check the app and try again."
        case .launchTimedOut(let application):
            return isChinese
                ? "打开 \(application.displayName) 超时，请检查应用后重试。"
                : "Opening \(application.displayName) timed out. Check the app and try again."
        }
    }
}

final class AgentDesktopLauncherService: @unchecked Sendable {
    struct Configuration: Sendable {
        var versionProbeTimeout: TimeInterval = 3
        var commandLaunchTimeout: TimeInterval = 15
        var terminationGracePeriod: TimeInterval = 0.3
        var maximumCommandOutputBytes = 8192
        var outputReadChunkBytes = 4096
        var outputReadBatchCount = 8
        var minimumClaudeDesktopVersion = "2.1.285"
        // Lowest app version verified locally for Claude's native continue route.
        var minimumClaudeNativeDesktopVersion = "2.26454.2"
    }

    struct CommandResult: Equatable, Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    typealias ApplicationLookup = @Sendable (String) -> URL?
    typealias ApplicationValidator = @Sendable (URL, String) -> Bool
    typealias ExecutableValidator = @Sendable (URL) -> Bool
    typealias ApplicationOpener = @Sendable (URL, URL?) async throws -> Void
    typealias CommandRunner = @Sendable (URL, [String], URL?, TimeInterval) async throws -> CommandResult

    static let shared = AgentDesktopLauncherService()

    private let homeDirectory: URL
    private let applicationDirectories: [URL]
    private let configuration: Configuration
    private let applicationLookup: ApplicationLookup
    private let applicationValidator: ApplicationValidator
    private let executableValidator: ExecutableValidator
    private let applicationOpener: ApplicationOpener
    private let commandRunner: CommandRunner
    private let fileManager: FileManager

    /// Creates desktop discovery and opening services without shell initialization.
    ///
    /// Args:
    ///   homeDirectory: User home used for trusted app and command locations.
    ///   applicationDirectories: Optional app search directories for isolated tests.
    ///   configuration: Timeouts, output bounds, and minimum CLI and app versions.
    ///   fileManager: File manager used to validate project directories.
    ///   applicationLookup: Launch Services lookup, which may return a stale URL.
    ///   applicationValidator: Validator for existing apps and their bundle identity.
    ///   executableValidator: Validator for optional command executables.
    ///   applicationOpener: Opener that targets the detected app explicitly.
    ///   commandRunner: Optional bounded command runner injected by tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        applicationLookup: @escaping ApplicationLookup = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        },
        applicationValidator: @escaping ApplicationValidator = { url, identifier in
            AgentDesktopLauncherService.isValidApplication(at: url, bundleIdentifier: identifier)
        },
        executableValidator: @escaping ExecutableValidator = { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: url.path)
        },
        applicationOpener: @escaping ApplicationOpener = { applicationURL, destinationURL in
            try await AgentDesktopLauncherService.openWithWorkspace(
                applicationURL: applicationURL,
                destinationURL: destinationURL
            )
        },
        commandRunner: CommandRunner? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        self.configuration = configuration
        self.fileManager = fileManager
        self.applicationLookup = applicationLookup
        self.applicationValidator = applicationValidator
        self.executableValidator = executableValidator
        self.applicationOpener = applicationOpener
        self.commandRunner = commandRunner ?? { executable, arguments, projectURL, timeout in
            await AgentDesktopLauncherService.runCommand(
                executable: executable,
                arguments: arguments,
                projectURL: projectURL,
                homeDirectory: homeDirectory,
                timeout: timeout,
                configuration: configuration
            )
        }
    }

    /// Finds a real desktop app and, independently, an optional helper command.
    ///
    /// Args:
    ///   application: Desktop agent selected by the user.
    ///
    /// Returns:
    ///   Installation details; a command alone never counts as an installed app.
    func detectInstallation(for application: AgentDesktopApplication) -> AgentDesktopInstallation {
        var candidates: [URL] = []
        if let registeredURL = applicationLookup(application.bundleIdentifier) {
            candidates.append(registeredURL.standardizedFileURL)
        }
        candidates.append(contentsOf: applicationDirectories.flatMap { directory in
            application.applicationNames.map { directory.appendingPathComponent($0, isDirectory: true) }
        })
        let applicationURL = candidates.first { candidate in
            applicationValidator(candidate, application.bundleIdentifier)
        }
        let commandURL = commandCandidates(for: application, applicationURL: applicationURL)
            .first(where: executableValidator)
        return AgentDesktopInstallation(
            application: application,
            applicationURL: applicationURL,
            commandURL: commandURL
        )
    }

    /// Detects all supported apps without invoking a CLI or opening a window.
    ///
    /// Returns:
    ///   One installation result per supported desktop app.
    func detectInstallations() -> [AgentDesktopInstallation] {
        AgentDesktopApplication.allCases.map { detectInstallation(for: $0) }
    }

    /// Checks installed Claude support for native chat navigation without a command.
    ///
    /// Returns:
    ///   True only when the actual installed bundle has the required identity and version.
    func supportsClaudeNativeSessionNavigation() -> Bool {
        guard let applicationURL = detectInstallation(for: .claudeCode).applicationURL else { return false }
        return supportsClaudeNativeSessionNavigation(at: applicationURL)
    }

    /// Opens the chosen desktop agent, project, or supported existing chat.
    ///
    /// Args:
    ///   application: Explicit desktop app selected by the user.
    ///   projectURL: Optional existing local directory to open.
    ///   sessionID: Optional Codex chat ID or Claude native local chat ID.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: The app, directory, chat ID, or launch is unavailable.
    func open(
        application: AgentDesktopApplication,
        projectURL: URL? = nil,
        sessionID: String? = nil
    ) async throws {
        try Task.checkCancellation()
        let installation = detectInstallation(for: application)
        guard let applicationURL = installation.applicationURL else {
            throw AgentDesktopLauncherError.applicationNotInstalled(application)
        }
        if application == .claudeCode, let sessionID {
            let destinationURL = try Self.destinationURL(for: application, sessionID: sessionID)
            try await openApplication(
                applicationURL, destinationURL: destinationURL, application: application,
                requiresClaudeNativeSessionNavigation: true
            )
            return
        }
        if let projectURL {
            try validateProject(projectURL)
        }
        let destinationURL = try Self.destinationURL(
            for: application,
            projectURL: projectURL,
            sessionID: sessionID
        )

        if application == .claudeCode,
           let projectURL,
           let commandURL = installation.commandURL,
           await supportsClaudeDesktopCommand(commandURL) {
            try Task.checkCancellation()
            try validateApplication(applicationURL, application: application)
            try validateProject(projectURL)
            guard executableValidator(commandURL) else {
                try await openApplication(applicationURL, destinationURL: destinationURL, application: application)
                return
            }
            let result: CommandResult
            do {
                try Task.checkCancellation()
                result = try await commandRunner(
                    commandURL, ["--desktop"], projectURL.standardizedFileURL,
                    configuration.commandLaunchTimeout
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgentDesktopLauncherError.launchFailed(application)
            }
            if result.timedOut {
                throw AgentDesktopLauncherError.launchTimedOut(application)
            }
            guard result.status == 0 else {
                throw AgentDesktopLauncherError.launchFailed(application)
            }
            // The CLI routes into Code; app activation must not open a second Code chat.
            try await openApplication(applicationURL, destinationURL: nil, application: application)
            return
        }

        try Task.checkCancellation()
        if let projectURL { try validateProject(projectURL) }
        try await openApplication(applicationURL, destinationURL: destinationURL, application: application)
    }

    /// Builds app links while preserving query values as data.
    ///
    /// Args:
    ///   application: App whose registered URL scheme is used.
    ///   projectURL: Optional project directory, already validated by the caller.
    ///   sessionID: Optional Codex chat ID or Claude native local chat ID.
    ///
    /// Returns:
    ///   A deep link, or nil when Codex only needs app activation.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: The chat identifier or destination is unsupported.
    static func destinationURL(
        for application: AgentDesktopApplication,
        projectURL: URL? = nil,
        sessionID: String? = nil
    ) throws -> URL? {
        var components = URLComponents()
        switch application {
        case .codex:
            components.scheme = "codex"
            if let sessionID {
                guard !sessionID.isEmpty,
                      sessionID.unicodeScalars.allSatisfy({
                          CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
                              .contains($0)
                      }) else {
                    throw AgentDesktopLauncherError.invalidSessionIdentifier
                }
                components.host = "threads"
                components.path = "/\(sessionID)"
            } else if let projectURL {
                components.host = "new"
                components.queryItems = [URLQueryItem(name: "path", value: projectURL.standardizedFileURL.path)]
            } else {
                return nil
            }
        case .claudeCode:
            components.scheme = "claude"
            components.host = "code"
            if let sessionID {
                guard AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(sessionID) else {
                    throw AgentDesktopLauncherError.invalidSessionIdentifier
                }
                components.path = "/continue"
                components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
            } else {
                components.path = "/new"
                if let projectURL {
                    components.queryItems = [URLQueryItem(name: "folder", value: projectURL.standardizedFileURL.path)]
                }
            }
        }
        // URLSearchParams treats a raw plus as a space; paths must retain literal plus signs.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw AgentDesktopLauncherError.invalidDestination
        }
        return url
    }

    /// Checks the reported CLI version against the configured desktop-routing minimum.
    ///
    /// Args:
    ///   output: Output of an explicit `claude --version` probe.
    ///   minimumVersion: First release documented to support `--desktop`.
    ///
    /// Returns:
    ///   True only for a recognized, sufficiently recent release version.
    static func supportsClaudeDesktopVersion(_ output: String, minimumVersion: String = "2.1.285") -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " (Claude Code)", with: "")
            guard releaseVersion(text) != nil else { continue }
            return isReleaseVersion(text, atLeast: minimumVersion)
        }
        return false
    }

    /// Reads bundle identity from disk so Launch Services caches cannot hide removal.
    ///
    /// Args:
    ///   url: Candidate application bundle URL.
    ///   bundleIdentifier: Exact expected official app identifier.
    ///
    /// Returns:
    ///   True only for a matching app with a present, executable entry file.
    static func isValidApplication(at url: URL, bundleIdentifier: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let dictionary = applicationInfo(at: url),
              dictionary["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !executableName.isEmpty,
              !executableName.contains("\0"),
              executableName != ".", executableName != "..",
              !executableName.contains("/"), !executableName.contains("\\") else { return false }
        let executableURL = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        var executableIsDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &executableIsDirectory)
            && !executableIsDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Reads current bundle metadata without Foundation's cached Bundle instances.
    ///
    /// Args:
    ///   url: Candidate application bundle URL.
    ///
    /// Returns:
    ///   The actual Info.plist dictionary, or nil for unavailable metadata.
    private static func applicationInfo(at url: URL) -> [String: Any]? {
        guard url.isFileURL,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    /// Rechecks native chat support against the bundle that will receive the link.
    ///
    /// Args:
    ///   applicationURL: Previously detected official Claude desktop bundle.
    ///
    /// Returns:
    ///   True only for a still-valid bundle with a recognized, sufficiently new version.
    private func supportsClaudeNativeSessionNavigation(at applicationURL: URL) -> Bool {
        let identifier = AgentDesktopApplication.claudeCode.bundleIdentifier
        guard applicationValidator(applicationURL, identifier),
              let info = Self.applicationInfo(at: applicationURL),
              info["CFBundleIdentifier"] as? String == identifier,
              let version = info["CFBundleShortVersionString"] as? String else { return false }
        return Self.isReleaseVersion(version, atLeast: configuration.minimumClaudeNativeDesktopVersion)
    }

    /// Lists supplemental CLI locations without using the GUI process PATH.
    ///
    /// Args:
    ///   application: Agent whose helper command is being located.
    ///   applicationURL: Verified app used for optional embedded command locations.
    ///
    /// Returns:
    ///   Explicit command candidates in preference order.
    private func commandCandidates(for application: AgentDesktopApplication, applicationURL: URL?) -> [URL] {
        let commandName = application == .codex ? "codex" : "claude"
        var candidates = [".local/bin", ".npm-global/bin", ".bun/bin"].map {
            homeDirectory.appendingPathComponent($0, isDirectory: true).appendingPathComponent(commandName)
        }
        if application == .claudeCode {
            candidates.append(homeDirectory.appendingPathComponent(".claude/local/claude"))
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(commandName)
        })
        if let applicationURL {
            let embeddedPaths: [String]
            switch application {
            case .codex:
                embeddedPaths = [
                    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                    "Contents/Resources/CodexCLI.app/Contents/MacOS/codex",
                    "Contents/Resources/codex",
                ]
            case .claudeCode:
                embeddedPaths = [
                    "Contents/Resources/bin/claude",
                    "Contents/Resources/claude-code/claude",
                    "Contents/Resources/claude",
                ]
            }
            candidates.append(contentsOf: embeddedPaths.map { applicationURL.appendingPathComponent($0) })
        }
        return candidates
    }

    /// Validates the optional local project immediately before an open request.
    ///
    /// Args:
    ///   url: Project directory supplied by the caller.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: The URL is not an available local directory.
    private func validateProject(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path) else {
            throw AgentDesktopLauncherError.invalidProject(url.path)
        }
    }

    /// Revalidates app identity after any asynchronous probe.
    ///
    /// Args:
    ///   url: Previously detected application URL.
    ///   application: Expected official app.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: The detected app was removed or replaced.
    private func validateApplication(_ url: URL, application: AgentDesktopApplication) throws {
        guard applicationValidator(url, application.bundleIdentifier) else {
            throw AgentDesktopLauncherError.applicationRemoved(application)
        }
    }

    /// Checks the optional Claude CLI away from the main actor.
    ///
    /// Args:
    ///   commandURL: Previously detected optional helper command.
    ///
    /// Returns:
    ///   True only when the bounded probe establishes documented desktop support.
    private func supportsClaudeDesktopCommand(_ commandURL: URL) async -> Bool {
        guard executableValidator(commandURL) else { return false }
        do {
            let result = try await commandRunner(commandURL, ["--version"], nil, configuration.versionProbeTimeout)
            return !result.timedOut && result.status == 0
                && Self.supportsClaudeDesktopVersion(result.output, minimumVersion: configuration.minimumClaudeDesktopVersion)
        } catch {
            return false
        }
    }

    /// Waits for explicit app-targeted opening and translates startup errors.
    ///
    /// Args:
    ///   applicationURL: Verified target bundle URL.
    ///   destinationURL: Optional app-specific deep link.
    ///   application: App used in localized failure messages.
    ///   requiresClaudeNativeSessionNavigation: Rechecks native support before dispatch.
    ///
    /// Raises:
    ///   AgentDesktopLauncherError: The app disappeared or macOS rejected the request.
    private func openApplication(
        _ applicationURL: URL,
        destinationURL: URL?,
        application: AgentDesktopApplication,
        requiresClaudeNativeSessionNavigation: Bool = false
    ) async throws {
        try Task.checkCancellation()
        if requiresClaudeNativeSessionNavigation {
            guard supportsClaudeNativeSessionNavigation(at: applicationURL) else {
                throw AgentDesktopLauncherError.unsupportedSession(application)
            }
        } else {
            try validateApplication(applicationURL, application: application)
        }
        do {
            try await applicationOpener(applicationURL, destinationURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentDesktopLauncherError.launchFailed(application)
        }
    }

    /// Compares numeric components of two exact release versions.
    ///
    /// Args:
    ///   version: Actual bundle or command release version.
    ///   minimumVersion: Minimum release accepted by the relevant capability gate.
    ///
    /// Returns:
    ///   True when both versions are recognized and the actual release meets the minimum.
    private static func isReleaseVersion(_ version: String, atLeast minimumVersion: String) -> Bool {
        guard let actual = releaseVersion(version), let minimum = releaseVersion(minimumVersion) else { return false }
        for (actualPart, minimumPart) in zip(actual, minimum) {
            if actualPart != minimumPart { return actualPart > minimumPart }
        }
        return true
    }

    /// Parses an unambiguous three-component release version.
    ///
    /// Args:
    ///   text: Exact semantic release version with no prerelease suffix.
    ///
    /// Returns:
    ///   Three numeric components, or nil for unrecognized output.
    private static func releaseVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    /// Delivers a URL to the selected app instead of the system's default handler.
    ///
    /// Args:
    ///   applicationURL: Validated app bundle to open and activate.
    ///   destinationURL: Optional app-specific deep link.
    ///
    /// Raises:
    ///   Error: macOS could not open or activate the target application.
    @MainActor
    private static func openWithWorkspace(applicationURL: URL, destinationURL: URL?) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: AgentDesktopLauncherError.invalidDestination)
                } else {
                    continuation.resume()
                }
            }
            if let destinationURL {
                NSWorkspace.shared.open(
                    [destinationURL], withApplicationAt: applicationURL,
                    configuration: options, completionHandler: completion
                )
            } else {
                NSWorkspace.shared.openApplication(
                    at: applicationURL, configuration: options, completionHandler: completion
                )
            }
        }
    }

    /// Runs a helper with bounded waiting, output, and termination off the main actor.
    ///
    /// Args:
    ///   executable: Explicit validated helper URL.
    ///   arguments: Arguments passed directly without a shell.
    ///   projectURL: Optional current directory used for Claude desktop handoff.
    ///   homeDirectory: User home used to build an explicit helper PATH.
    ///   timeout: Maximum wait before terminating the helper.
    ///   configuration: Output and termination bounds.
    ///
    /// Returns:
    ///   Exit details; launch failures use a nonzero status and no private output.
    private static func runCommand(
        executable: URL,
        arguments: [String],
        projectURL: URL?,
        homeDirectory: URL,
        timeout: TimeInterval,
        configuration: Configuration
    ) async -> CommandResult {
        let cancellation = AgentDesktopCommandCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runCommandBlocking(
                        executable: executable,
                        arguments: arguments,
                        projectURL: projectURL,
                        homeDirectory: homeDirectory,
                        timeout: timeout,
                        configuration: configuration,
                        cancellation: cancellation
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Performs bounded process waiting on a dispatch worker, outside async executors.
    ///
    /// Args:
    ///   executable: Explicit validated helper URL.
    ///   arguments: Direct child-process arguments with no shell interpolation.
    ///   projectURL: Optional current directory for the desktop handoff.
    ///   homeDirectory: User home used for an explicit helper PATH.
    ///   timeout: Maximum process wait before termination.
    ///   configuration: Output and termination limits.
    ///   cancellation: Thread-safe cancellation state shared with the awaiting task.
    ///
    /// Returns:
    ///   Captured exit details or a bounded timeout/launch failure result.
    private static func runCommandBlocking(
        executable: URL,
        arguments: [String],
        projectURL: URL?,
        homeDirectory: URL,
        timeout: TimeInterval,
        configuration: Configuration,
        cancellation: AgentDesktopCommandCancellation
    ) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let output = AgentDesktopCommandOutput(configuration: configuration)
        let completed = DispatchSemaphore(value: 0)
        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return CommandResult(status: -1, output: "", timedOut: false)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = projectURL
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            executable.deletingLastPathComponent().path,
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        outputPipe.fileHandleForReading.readabilityHandler = { _ in
            output.readAvailable(from: descriptor)
        }
        process.terminationHandler = { _ in completed.signal() }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            output.stopReading()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        }
        cancellation.register(process: process, completion: completed)
        guard !cancellation.isCancelled else {
            return CommandResult(status: -1, output: "", timedOut: false)
        }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", timedOut: false)
        }
        if cancellation.isCancelled, process.isRunning { process.terminate() }
        let didTimeOut = completed.wait(timeout: .now() + max(timeout, 0)) == .timedOut
        if didTimeOut || cancellation.isCancelled {
            if process.isRunning {
                process.terminate()
                _ = completed.wait(timeout: .now() + max(configuration.terminationGracePeriod, 0))
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = completed.wait(timeout: .now() + max(configuration.terminationGracePeriod, 0))
                }
            }
            return CommandResult(status: -1, output: "", timedOut: didTimeOut && !cancellation.isCancelled)
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        output.readAvailable(from: descriptor)
        return CommandResult(status: process.terminationStatus, output: output.text, timedOut: false)
    }
}

private final class AgentDesktopCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var completion: DispatchSemaphore?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Registers the child and wakeup signal before dispatching the executable.
    ///
    /// Args:
    ///   process: Child process that can be terminated on cancellation.
    ///   completion: Signal that lets the bounded runner begin cleanup immediately.
    func register(process: Process, completion: DispatchSemaphore) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        self.completion = completion
    }

    /// Wakes the runner and requests termination without waiting on the caller actor.
    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        let completion = completion
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        completion?.signal()
    }
}

private final class AgentDesktopCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: AgentDesktopLauncherService.Configuration
    private var data = Data()
    private var stopped = false

    /// Creates bounded output storage for a nonblocking subprocess pipe.
    ///
    /// Args:
    ///   configuration: Maximum captured bytes and bounded read batch sizes.
    init(configuration: AgentDesktopLauncherService.Configuration) {
        self.configuration = configuration
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Drains a bounded batch without waiting for child processes that retain stdout.
    ///
    /// Args:
    ///   descriptor: Nonblocking read descriptor owned by the command runner.
    func readAvailable(from descriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: max(configuration.outputReadChunkBytes, 1))
        for _ in 0..<max(configuration.outputReadBatchCount, 1) {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            let remaining = max(configuration.maximumCommandOutputBytes - data.count, 0)
            if remaining > 0 {
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
        }
    }

    /// Blocks pending readability callbacks before the pipe descriptor can be reused.
    func stopReading() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }
}
