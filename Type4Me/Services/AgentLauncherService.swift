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
    case ghostty
    case warp
    case iterm2
    case kitty
    case alacritty
    case wezterm
    case terminal
}

final class AgentLauncherService: @unchecked Sendable {
    static let shared = AgentLauncherService()

    private let homeDirectory: URL
    private let cacheURL: URL
    private let fileManager: FileManager
    private let processRunner: @Sendable ([String]) throws -> Void
    private let scoreCutoff = 55

    /// Creates a launcher service for routing spoken project names to terminal agents.
    ///
    /// - Parameters:
    ///   - homeDirectory: User home directory used for shell history, Claude state, and project discovery.
    ///   - cacheURL: Optional cache location for the discovered project index.
    ///   - fileManager: File manager used for filesystem access.
    ///   - processRunner: Process launcher injected by tests to avoid opening terminal windows.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default,
        processRunner: @escaping @Sendable ([String]) throws -> Void = { arguments in
            try AgentLauncherService.runProcess(arguments: arguments)
        }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.processRunner = processRunner
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let supportURL = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Type4Me", isDirectory: true)
            self.cacheURL = supportURL.appendingPathComponent("agent-projects.json")
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

    /// Builds the shell command used to enter a project and start Claude.
    ///
    /// - Parameter project: Matched project descriptor.
    /// - Returns: Shell-safe command string for the target terminal.
    func shellCommand(for project: AgentLauncherProject) -> String {
        "cd \(shellQuote(project.path)) && \(claudeCommand(for: project.path))"
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
            return bestMatch(normalizedQuery: normalizedQuery, in: refreshed)
        }
        return nil
    }

    private func bestMatch(normalizedQuery: String, in candidates: [AgentLauncherProject]) -> AgentLauncherProject? {
        let scored = candidates
            .map { project in (project, score(query: normalizedQuery, project: project)) }
            .filter { $0.1 >= scoreCutoff }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.lastSeen > $1.0.lastSeen
                }
                return $0.1 > $1.1
            }
        return scored.first?.0
    }

    /// Normalizes project and query text for fuzzy matching.
    ///
    /// - Parameter value: Raw project name or query.
    /// - Returns: Lowercase token string with camelCase and separators flattened.
    func normalize(_ value: String) -> String {
        var output = ""
        var previousWasLowercase = false
        for scalar in value.unicodeScalars {
            let character = Character(scalar)
            if CharacterSet.uppercaseLetters.contains(scalar), previousWasLowercase {
                output.append(" ")
            }

            let isCJK = scalar.value >= 0x4e00 && scalar.value <= 0x9fff
            if CharacterSet.alphanumerics.contains(scalar) || isCJK {
                output.append(String(character).lowercased())
                previousWasLowercase = CharacterSet.lowercaseLetters.contains(scalar)
            } else {
                output.append(" ")
                previousWasLowercase = false
            }
        }
        return output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func loadProjects() -> [AgentLauncherProject] {
        if let cached = readCachedProjects(), !cached.isEmpty {
            return cached
        }
        let projects = discoverProjects()
        writeCachedProjects(projects)
        return projects
    }

    private func readCachedProjects() -> [AgentLauncherProject]? {
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
        let expanded = (unquoted as NSString).expandingTildeInPath
        let absolutePath = expanded.hasPrefix("/") ? expanded : homeDirectory.appendingPathComponent(expanded).path
        let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard directoryExists(url) else { return nil }
        return makeProject(url: url, lastSeen: lastSeen)
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

    private func score(query: String, project: AgentLauncherProject) -> Int {
        let name = project.normalizedName
        guard !query.isEmpty, !name.isEmpty else { return 0 }
        if query == name { return 100 }
        if name.hasPrefix(query) || query.hasPrefix(name) { return 90 }
        if name.contains(query) || query.contains(name) { return 85 }

        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let nameTokens = Set(name.split(separator: " ").map(String.init))
        let overlap = queryTokens.intersection(nameTokens).count
        let denominator = max(queryTokens.count, nameTokens.count, 1)
        let tokenScore = Int(Double(overlap) / Double(denominator) * 80)
        let subsequenceScore = isSubsequence(query, of: name) ? 70 : 0
        return max(tokenScore, subsequenceScore)
    }

    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var cursor = haystack.startIndex
        for character in needle {
            guard let found = haystack[cursor...].firstIndex(of: character) else {
                return false
            }
            cursor = haystack.index(after: found)
        }
        return true
    }

    private func launchTerminal(for project: AgentLauncherProject) throws {
        let terminal = preferredTerminal()
        let command = shellCommand(for: project)
        switch terminal {
        case .ghostty:
            try processRunner([
                "/usr/bin/open", "-na", "/Applications/Ghostty.app",
                "--args", "-e", "/bin/zsh", "-ilc", "\(command); exec $SHELL"
            ])
        case .iterm2:
            try runAppleScript("""
            tell application "iTerm"
                create window with default profile command \(appleScriptString(command))
                activate
            end tell
            """)
        case .warp:
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
            try processRunner([
                "/usr/bin/open", "-na", terminalAppPath(for: terminal),
                "--args", "-e", "/bin/zsh", "-ilc", "\(command); exec $SHELL"
            ])
        case .terminal:
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
        let stored = UserDefaults.standard.string(forKey: "tf_agentLauncherTerminal") ?? "auto"
        if stored != "auto",
           let terminal = AgentLauncherTerminal(rawValue: stored),
           terminalExists(terminal) {
            return terminal
        }
        return AgentLauncherTerminal.allCases.first(where: terminalExists) ?? .terminal
    }

    private func terminalExists(_ terminal: AgentLauncherTerminal) -> Bool {
        switch terminal {
        case .terminal:
            return true
        default:
            return fileManager.fileExists(atPath: terminalAppPath(for: terminal))
        }
    }

    private func terminalAppPath(for terminal: AgentLauncherTerminal) -> String {
        switch terminal {
        case .ghostty:
            return "/Applications/Ghostty.app"
        case .warp:
            return "/Applications/Warp.app"
        case .iterm2:
            return "/Applications/iTerm.app"
        case .kitty:
            return "/Applications/kitty.app"
        case .alacritty:
            return "/Applications/Alacritty.app"
        case .wezterm:
            return "/Applications/WezTerm.app"
        case .terminal:
            return "/System/Applications/Utilities/Terminal.app"
        }
    }

    private func runAppleScript(_ source: String) throws {
        try processRunner(["/usr/bin/osascript", "-e", source])
    }

    private func claudeCommand(for projectPath: String) -> String {
        let encodedPath = projectPath.replacingOccurrences(of: "/", with: "-")
        let claudeProjectURL = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedPath, isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(atPath: claudeProjectURL.path),
           entries.contains(where: { $0.hasSuffix(".jsonl") }) {
            return "claude --continue"
        }
        return "claude"
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
}
