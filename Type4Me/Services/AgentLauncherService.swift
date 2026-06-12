import Foundation

struct AgentLauncherProject: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let normalizedName: String
    let lastSeen: TimeInterval
}

struct AgentLauncherResult: Equatable, Sendable {
    let launched: Bool
    let query: String
    let project: AgentLauncherProject?
    let message: String
}

enum AgentLauncherTerminal: String, CaseIterable, Sendable {
    case cmux
    case ghostty
    case warp
    case iterm2
    case kitty
    case alacritty
    case wezterm
    case terminal

    var displayName: String {
        switch self {
        case .cmux:
            return "cmux"
        case .ghostty:
            return "Ghostty"
        case .warp:
            return "Warp"
        case .iterm2:
            return "iTerm2"
        case .kitty:
            return "Kitty"
        case .alacritty:
            return "Alacritty"
        case .wezterm:
            return "WezTerm"
        case .terminal:
            return "Terminal.app"
        }
    }

    private var applicationPaths: [String] {
        switch self {
        case .cmux:
            return ["/Applications/cmux.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        case .iterm2:
            return ["/Applications/iTerm.app"]
        case .kitty:
            return ["/Applications/kitty.app", "/Applications/Kitty.app"]
        case .alacritty:
            return ["/Applications/Alacritty.app"]
        case .wezterm:
            return ["/Applications/WezTerm.app"]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        }
    }

    /// Returns whether this terminal is installed.
    ///
    /// Args:
    ///   fileManager: File manager used to check application paths.
    ///
    /// Returns:
    ///   `true` when the app exists, with Terminal.app always available as fallback.
    func isInstalled(fileManager: FileManager = .default) -> Bool {
        if self == .terminal {
            return true
        }
        return applicationPaths.contains { fileManager.fileExists(atPath: $0) }
    }

    /// Resolves the application path to launch.
    ///
    /// Args:
    ///   fileManager: File manager used to prefer an installed path.
    ///
    /// Returns:
    ///   The first installed app path, or the primary known path.
    func applicationPath(fileManager: FileManager = .default) -> String {
        applicationPaths.first(where: { fileManager.fileExists(atPath: $0) }) ?? applicationPaths[0]
    }

    /// Lists installed terminals in launcher priority order.
    ///
    /// Args:
    ///   fileManager: File manager used to check application paths.
    ///
    /// Returns:
    ///   Installed terminal identifiers, always including Terminal.app.
    static func available(fileManager: FileManager = .default) -> [AgentLauncherTerminal] {
        let found = allCases.filter { $0.isInstalled(fileManager: fileManager) }
        return found.contains(.terminal) ? found : found + [.terminal]
    }
}

final class AgentLauncherService: @unchecked Sendable {
    static let shared = AgentLauncherService()
    static let minimumMatchScore = AgentFuzzyMatcher.defaultThreshold
    private static let codexResumeCommand = "codex --dangerously-bypass-approvals-and-sandbox resume"

    private let homeDirectory: URL
    private let cacheURL: URL
    private let fileManager: FileManager
    private let spotlightSearcher: @Sendable (String) -> [URL]
    private let processRunner: @Sendable ([String]) throws -> Void
    private let preferredTerminalProvider: (@Sendable () -> AgentLauncherTerminal)?
    private let cmuxWorkspaceCreator: @Sendable (AgentLauncherProject, String) -> Bool
    private let matcher: AgentFuzzyMatcher
    private let projectCacheRefreshInterval: TimeInterval = 3600

    /// Creates a launcher service for routing spoken project names to terminal agents.
    ///
    /// - Parameters:
    ///   - homeDirectory: User home directory used for shell history, Claude state, and project discovery.
    ///   - cacheURL: Optional cache location for the discovered project index.
    ///   - fileManager: File manager used for filesystem access.
    ///   - spotlightSearcher: Folder searcher used when the cached project index misses.
    ///   - processRunner: Process launcher injected by tests to avoid opening terminal windows.
    ///   - preferredTerminalProvider: Optional terminal selector injected by tests.
    ///   - cmuxWorkspaceCreator: cmux workspace creator injected by tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default,
        spotlightSearcher: @escaping @Sendable (String) -> [URL] = { query in
            AgentLauncherService.searchSpotlightFolders(matching: query)
        },
        processRunner: @escaping @Sendable ([String]) throws -> Void = { arguments in
            try AgentLauncherService.runProcess(arguments: arguments)
        },
        preferredTerminalProvider: (@Sendable () -> AgentLauncherTerminal)? = nil,
        cmuxWorkspaceCreator: (@Sendable (AgentLauncherProject, String) -> Bool)? = nil,
        matcher: AgentFuzzyMatcher = AgentFuzzyMatcher()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.spotlightSearcher = spotlightSearcher
        self.processRunner = processRunner
        self.preferredTerminalProvider = preferredTerminalProvider
        self.matcher = matcher
        self.cmuxWorkspaceCreator = cmuxWorkspaceCreator ?? { project, command in
            CmuxCommandClient().newWorkspace(name: project.name, cwd: project.path, command: command)
        }
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            self.cacheURL = AppIdentity.appSupportDirectory().appendingPathComponent("agent-projects.json")
        }
    }

    /// Handles a final ASR transcript as an agent-launch command.
    ///
    /// - Parameters:
    ///   - text: Final transcript from ASR.
    ///   - launch: Whether to actually launch a terminal process. Tests pass `false`.
    /// - Returns: Routing result with the matched project and user-facing status.
    func handle(_ text: String, launch: Bool = true) -> AgentLauncherResult {
        let query = parseQuery(from: text)
        guard !query.isEmpty else {
            return AgentLauncherResult(
                launched: false,
                query: "",
                project: nil,
                message: "没有听到可启动的项目名"
            )
        }

        guard let project = bestMatch(for: query) else {
            return AgentLauncherResult(
                launched: false,
                query: query,
                project: nil,
                message: "未找到匹配项目：\(query)"
            )
        }

        do {
            if launch {
                try launchTerminal(for: project)
            }
            return AgentLauncherResult(
                launched: true,
                query: query,
                project: project,
                message: "已启动 Agent：\(project.name)"
            )
        } catch {
            DebugFileLogger.log("AgentLauncherService launch failed: \(error.localizedDescription)")
            return AgentLauncherResult(
                launched: false,
                query: query,
                project: project,
                message: "启动失败：\(project.name)"
            )
        }
    }

    /// Extracts a project query from spoken launcher text.
    ///
    /// - Parameter text: Final ASR transcript.
    /// - Returns: Cleaned project query, or an empty string when the text is too vague.
    func parseQuery(from text: String) -> String {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = query.trimmingCharacters(in: CharacterSet(charactersIn: "，。！？,.!?；;：: "))

        let lower = query.lowercased()
        let englishPrefixes = ["go to ", "open ", "launch "]
        for prefix in englishPrefixes where lower.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
            break
        }

        let chinesePrefixes = ["打开", "进入", "去", "到"]
        for prefix in chinesePrefixes where query.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
            break
        }

        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = ["项目", "工程", "目录", "folder", "project", "directory"]
        let loweredQuery = query.lowercased()
        for suffix in suffixes where loweredQuery.hasSuffix(suffix) {
            query = String(query.dropLast(suffix.count))
            break
        }

        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningless = Set(["项目", "工程", "目录", "folder", "project", "directory"])
        if query.count < 2 || meaningless.contains(query.lowercased()) {
            return ""
        }
        return query
    }

    /// Builds the shell command used to enter a project and start Codex.
    ///
    /// Args:
    ///   project: Matched project descriptor.
    ///
    /// Returns:
    ///   Shell-safe command string for the target terminal.
    func shellCommand(for project: AgentLauncherProject) -> String {
        "cd \(shellQuote(project.path)) && \(Self.codexResumeCommand)"
    }

    /// Builds the command passed to cmux when `--cwd` already sets the directory.
    ///
    /// Args:
    ///   project: Matched project descriptor. The value is accepted to keep the
    ///     call site aligned with terminal-specific command builders.
    ///
    /// Returns:
    ///   Command string for cmux `workspace create --command`.
    func cmuxCommand(for _: AgentLauncherProject) -> String {
        Self.codexResumeCommand
    }

    /// Builds the command passed to cmux for resuming a specific Codex session.
    ///
    /// Args:
    ///   sessionID: Codex session identifier accepted by `codex resume`.
    ///
    /// Returns:
    ///   Shell-safe command string for cmux `workspace create --command`.
    func cmuxSessionCommand(for sessionID: String) -> String {
        "\(Self.codexResumeCommand) \(shellQuote(sessionID))"
    }

    /// Returns the best project match for a spoken query.
    ///
    /// - Parameter query: Cleaned project query.
    /// - Returns: Project with the highest fuzzy score above the cutoff.
    func bestMatch(for query: String) -> AgentLauncherProject? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let candidates = loadProjects()
        if let match = bestMatch(normalizedQuery: normalizedQuery, in: candidates) {
            return match
        }

        let refreshed = discoverProjects()
        if refreshed != candidates {
            writeCachedProjects(refreshed)
            if let match = bestMatch(normalizedQuery: normalizedQuery, in: refreshed) {
                return match
            }
        }

        return bestMatch(normalizedQuery: normalizedQuery, in: projectsFromSpotlight(query: query))
    }

    private func bestMatch(normalizedQuery: String, in candidates: [AgentLauncherProject]) -> AgentLauncherProject? {
        matcher.acceptedBestMatch(
            for: normalizedQuery,
            in: candidates,
            candidateText: { $0.normalizedName }
        )
    }

    /// Normalizes project and query text for fuzzy matching.
    ///
    /// - Parameter value: Raw project name or query.
    /// - Returns: Lowercase token string with camelCase and separators flattened.
    func normalize(_ value: String) -> String {
        matcher.normalize(value)
    }

    /// Scores normalized text using the launcher fuzzy matching rules.
    ///
    /// Args:
    ///   normalizedQuery: Query already normalized by `normalize`.
    ///   normalizedCandidate: Candidate text already normalized by `normalize`.
    ///
    /// Returns:
    ///   Fuzzy match score in the 0...1 range.
    func matchScore(normalizedQuery: String, normalizedCandidate: String) -> Double {
        matcher.score(query: normalizedQuery, candidate: normalizedCandidate)
    }

    /// Reconciles the on-disk project index with currently discoverable directories.
    ///
    /// Returns:
    ///   The merged project index after removing missing cached paths and adding newly discovered paths.
    @discardableResult
    func reconcileProjectIndex() -> [AgentLauncherProject] {
        var byPath: [String: AgentLauncherProject] = [:]
        for project in readCachedProjectsIgnoringAge() ?? [] {
            let url = URL(fileURLWithPath: project.path).standardizedFileURL
            guard directoryExists(url) else { continue }
            byPath[url.path] = AgentLauncherProject(
                path: url.path,
                name: project.name,
                normalizedName: project.normalizedName,
                lastSeen: project.lastSeen
            )
        }
        for project in discoverProjects() {
            if let existing = byPath[project.path], existing.lastSeen >= project.lastSeen {
                continue
            }
            byPath[project.path] = project
        }
        let projects = Array(byPath.values).sorted { $0.lastSeen > $1.lastSeen }
        writeCachedProjects(projects)
        return projects
    }

    private func loadProjects() -> [AgentLauncherProject] {
        if let cached = readCachedProjects(), !cached.isEmpty {
            return cached
        }
        let projects = discoverProjects()
        writeCachedProjects(projects)
        return projects
    }

    /// Reads the cached project index when it is still fresh.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Cached projects, or `nil` when the cache is missing, stale, or invalid.
    private func readCachedProjects() -> [AgentLauncherProject]? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: cacheURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) < projectCacheRefreshInterval,
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode([AgentLauncherProject].self, from: data)
    }

    private func readCachedProjectsIgnoringAge() -> [AgentLauncherProject]? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode([AgentLauncherProject].self, from: data)
    }

    private func writeCachedProjects(_ projects: [AgentLauncherProject]) {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(projects)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            DebugFileLogger.log("AgentLauncherService cache write failed: \(error.localizedDescription)")
        }
    }

    private func discoverProjects() -> [AgentLauncherProject] {
        var byPath: [String: AgentLauncherProject] = [:]
        for project in projectsFromShellHistory() + projectsFromGitDirectories() + projectsFromVSCodeWorkspaces() {
            if let existing = byPath[project.path], existing.lastSeen >= project.lastSeen {
                continue
            }
            byPath[project.path] = project
        }
        return Array(byPath.values).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Builds project candidates from Spotlight folder matches for the current query.
    ///
    /// Args:
    ///   query: Cleaned spoken project query.
    ///
    /// Returns:
    ///   Existing directories returned by the injected Spotlight searcher.
    private func projectsFromSpotlight(query: String) -> [AgentLauncherProject] {
        var byPath: [String: AgentLauncherProject] = [:]
        for url in spotlightSearcher(query) {
            let standardized = url.standardizedFileURL
            guard directoryExists(standardized) else { continue }
            byPath[standardized.path] = makeProject(
                url: standardized,
                lastSeen: Date().timeIntervalSince1970
            )
        }
        return Array(byPath.values)
    }

    private func projectsFromShellHistory() -> [AgentLauncherProject] {
        let historyURL = homeDirectory.appendingPathComponent(".zsh_history")
        guard let data = try? Data(contentsOf: historyURL) else {
            return []
        }
        let content = String(decoding: data, as: UTF8.self)

        return content
            .split(separator: "\n")
            .compactMap { line -> AgentLauncherProject? in
                var timestamp: TimeInterval = 0
                var command = String(line)
                if command.hasPrefix(": "), let semicolon = command.firstIndex(of: ";") {
                    let header = command[..<semicolon]
                    let parts = header.split(separator: ":")
                    if parts.count >= 2 {
                        timestamp = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                    command = String(command[command.index(after: semicolon)...])
                }
                return projectFromCDCommand(command, lastSeen: timestamp)
            }
    }

    private func projectFromCDCommand(_ command: String, lastSeen: TimeInterval) -> AgentLauncherProject? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cd ") else { return nil }
        let rawPath = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty,
              rawPath.count < 255,
              rawPath.rangeOfCharacter(from: CharacterSet(charactersIn: "&|;`$")) == nil else {
            return nil
        }

        let unquoted = rawPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\ ", with: " ")
        let expanded = expandShellPath(unquoted)
        let absolutePath = expanded.hasPrefix("/") ? expanded : homeDirectory.appendingPathComponent(expanded).path
        let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard directoryExists(url) else { return nil }
        return makeProject(url: url, lastSeen: lastSeen)
    }

    /// Expands a shell path using this service's injected home directory.
    ///
    /// Args:
    ///   path: Raw shell path from history or workspace metadata.
    ///
    /// Returns:
    ///   Path with `~` resolved against `homeDirectory`.
    private func expandShellPath(_ path: String) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return (path as NSString).expandingTildeInPath
    }

    private func projectsFromGitDirectories() -> [AgentLauncherProject] {
        var projects: [AgentLauncherProject] = []
        scanGitDirectories(at: homeDirectory, depth: 0, projects: &projects)
        return projects
    }

    private func scanGitDirectories(at url: URL, depth: Int, projects: inout [AgentLauncherProject]) {
        guard depth <= 3 else { return }
        let gitURL = url.appendingPathComponent(".git")
        if directoryExists(gitURL) {
            projects.append(makeProject(url: url, lastSeen: 0))
            return
        }

        let skipNames = Set([
            "bin", "lib", "sbin", "tmp", "cache", "logs", "node_modules", "__pycache__",
            "venv", ".venv", "env", ".env", "dist", "build", "Library", "Movies", "Music",
            "Pictures", "Applications"
        ])
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children where !skipNames.contains(child.lastPathComponent) {
            guard isDirectory(child) else { continue }
            scanGitDirectories(at: child, depth: depth + 1, projects: &projects)
        }
    }

    private func projectsFromVSCodeWorkspaces() -> [AgentLauncherProject] {
        let workspaceStorageURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Code", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: workspaceStorageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry -> AgentLauncherProject? in
            let workspaceFile = entry.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: workspaceFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = object["folder"] as? String else {
                return nil
            }
            let path = folder.replacingOccurrences(of: "file://", with: "")
            let decodedPath = path.removingPercentEncoding ?? path
            let url = URL(fileURLWithPath: decodedPath).standardizedFileURL
            guard directoryExists(url) else { return nil }
            return makeProject(url: url, lastSeen: 0)
        }
    }

    private func makeProject(url: URL, lastSeen: TimeInterval) -> AgentLauncherProject {
        let name = url.lastPathComponent
        return AgentLauncherProject(
            path: url.path,
            name: name,
            normalizedName: normalize(name),
            lastSeen: lastSeen
        )
    }

    private func launchTerminal(for project: AgentLauncherProject) throws {
        let terminal = preferredTerminal()
        switch terminal {
        case .cmux:
            let command = cmuxCommand(for: project)
            guard cmuxWorkspaceCreator(project, command) else {
                throw AgentLauncherError.launchFailed
            }
        case .ghostty:
            let command = shellCommand(for: project)
            try processRunner([
                "/usr/bin/open", "-na", terminal.applicationPath(fileManager: fileManager),
                "--args", "-e", "/bin/zsh", "-ilc", "\(command); exec $SHELL"
            ])
        case .iterm2:
            let command = shellCommand(for: project)
            try runAppleScript("""
            tell application "iTerm"
                create window with default profile command \(appleScriptString(command))
                activate
            end tell
            """)
        case .warp:
            let command = shellCommand(for: project)
            try runAppleScript("""
            tell application "Warp"
                activate
            end tell
            tell application "System Events"
                keystroke \(appleScriptString(command))
                key code 36
            end tell
            """)
        case .kitty, .alacritty, .wezterm:
            let command = shellCommand(for: project)
            try processRunner([
                "/usr/bin/open", "-na", terminal.applicationPath(fileManager: fileManager),
                "--args", "-e", "/bin/zsh", "-ilc", "\(command); exec $SHELL"
            ])
        case .terminal:
            let command = shellCommand(for: project)
            try runAppleScript("""
            tell application "Terminal"
                do script \(appleScriptString(command))
                activate
            end tell
            """)
        }
        DebugFileLogger.log("AgentLauncherService launched \(project.name) in \(terminal.rawValue)")
    }

    private func preferredTerminal() -> AgentLauncherTerminal {
        if let preferredTerminalProvider {
            return preferredTerminalProvider()
        }
        let stored = UserDefaults.standard.string(forKey: "tf_agentLauncherTerminal") ?? "auto"
        if stored != "auto",
           let terminal = AgentLauncherTerminal(rawValue: stored),
           terminalExists(terminal) {
            return terminal
        }
        return AgentLauncherTerminal.allCases.first(where: terminalExists) ?? .terminal
    }

    private func terminalExists(_ terminal: AgentLauncherTerminal) -> Bool {
        terminal.isInstalled(fileManager: fileManager)
    }

    private func runAppleScript(_ source: String) throws {
        try processRunner(["/usr/bin/osascript", "-e", source])
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }

    private static func runProcess(arguments: [String]) throws {
        guard let executable = arguments.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        try process.run()
    }

    /// Searches Spotlight for folders matching a spoken project query.
    ///
    /// Args:
    ///   query: Cleaned spoken project query.
    ///
    /// Returns:
    ///   Folder URLs from Spotlight, filtered away from system locations.
    private static func searchSpotlightFolders(matching query: String) -> [URL] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", trimmed]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
        } catch {
            DebugFileLogger.log("AgentLauncherService Spotlight search failed: \(error.localizedDescription)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output
            .split(separator: "\n")
            .prefix(80)
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL }
            .filter(isUsefulSpotlightDirectory)
    }

    /// Filters Spotlight paths to directories that can plausibly be project roots.
    ///
    /// Args:
    ///   url: Candidate URL returned by Spotlight.
    ///
    /// Returns:
    ///   `true` when the path is a user-facing directory and not an app or system folder.
    private static func isUsefulSpotlightDirectory(_ url: URL) -> Bool {
        let path = url.path
        let excludedPrefixes = [
            "/Applications/",
            "/Library/",
            "/System/",
            "/bin/",
            "/private/",
            "/sbin/",
            "/usr/",
        ]
        guard excludedPrefixes.allSatisfy({ !path.hasPrefix($0) }),
              url.pathExtension != "app",
              !url.lastPathComponent.hasPrefix(".") else {
            return false
        }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private enum AgentLauncherError: Error {
    case launchFailed
}
