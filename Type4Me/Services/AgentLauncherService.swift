import Foundation

struct AgentLauncherProject: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let normalizedName: String
    let lastSeen: TimeInterval
}

enum AgentLauncherOutcome: Equatable, Sendable {
    case opened
    case emptyQuery
    case noProjectMatch
    case applicationUnavailable
    case openFailed
}

struct AgentLauncherResult: Equatable, Sendable {
    let outcome: AgentLauncherOutcome
    let application: AgentDesktopApplication
    let query: String
    let project: AgentLauncherProject?
    let message: String

    var launched: Bool { outcome == .opened }

    var historyStatus: String {
        switch outcome {
        case .opened: return "agent_launched"
        case .emptyQuery, .noProjectMatch: return "agent_no_match"
        case .applicationUnavailable: return "agent_app_missing"
        case .openFailed: return "agent_launch_failed"
        }
    }
}

final class AgentLauncherService: @unchecked Sendable {
    static let shared = AgentLauncherService()
    static let minimumMatchScore = AgentFuzzyMatcher.defaultThreshold
    private static let projectQuerySuffixes = ["项目", "工程", "目录", "folder", "project", "directory"]

    private let homeDirectory: URL
    private let cacheURL: URL
    private let fileManager: FileManager
    private let spotlightSearcher: @Sendable (String) -> [URL]
    private let preferredApplicationProvider: (@Sendable () -> AgentDesktopApplication)?
    private let installationChecker: @Sendable (AgentDesktopApplication) -> Bool
    private let desktopOpener: @Sendable (AgentDesktopApplication, URL?, String?) async throws -> Void
    private let matcher: AgentFuzzyMatcher
    private let projectCacheRefreshInterval: TimeInterval = 3600

    /// Creates a launcher that opens installed desktop agents for spoken projects.
    ///
    /// Args:
    ///   homeDirectory: Home directory used to discover project folders.
    ///   cacheURL: Optional location for the existing project index.
    ///   fileManager: File manager used for project discovery.
    ///   spotlightSearcher: Folder searcher used when the project index misses.
    ///   preferredApplicationProvider: Optional desktop preference injected by tests.
    ///   installationChecker: Installed-app check injected by tests.
    ///   desktopOpener: Desktop open request injected by tests.
    ///   matcher: Existing project-name fuzzy matcher.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default,
        spotlightSearcher: @escaping @Sendable (String) -> [URL] = { query in
            AgentLauncherService.searchSpotlightFolders(matching: query)
        },
        preferredApplicationProvider: (@Sendable () -> AgentDesktopApplication)? = nil,
        installationChecker: @escaping @Sendable (AgentDesktopApplication) -> Bool = { application in
            AgentDesktopLauncherService.shared.detectInstallation(for: application).isInstalled
        },
        desktopOpener: @escaping @Sendable (AgentDesktopApplication, URL?, String?) async throws -> Void = {
            application, projectURL, sessionID in
            try await AgentDesktopLauncherService.shared.open(
                application: application, projectURL: projectURL, sessionID: sessionID
            )
        },
        matcher: AgentFuzzyMatcher = AgentFuzzyMatcher()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.spotlightSearcher = spotlightSearcher
        self.preferredApplicationProvider = preferredApplicationProvider
        self.installationChecker = installationChecker
        self.desktopOpener = desktopOpener
        self.matcher = matcher
        self.cacheURL = cacheURL ?? AppIdentity.appSupportDirectory()
            .appendingPathComponent("agent-projects.json")
    }

    /// Handles a transcript using one fixed desktop agent for the whole request.
    ///
    /// Args:
    ///   text: Final ASR transcript containing an app or project name.
    ///   launch: Whether to send a desktop open request; tests may disable it.
    ///
    /// Returns:
    ///   Typed routing outcome, selected app, matched project, and localized feedback.
    func handle(_ text: String, launch: Bool = true) async -> AgentLauncherResult {
        let query = parseQuery(from: text)
        let namedApplication = applicationNamed(by: query, originalText: text)
        let application = namedApplication ?? preferredApplication()
        guard !query.isEmpty else {
            return AgentLauncherResult(
                outcome: .emptyQuery, application: application, query: "", project: nil,
                message: L("没有听到应用或项目名", "No app or project name was heard")
            )
        }
        guard installationChecker(application) else {
            return unavailableResult(application: application, query: query)
        }
        if namedApplication != nil {
            return await openRequest(application: application, query: query, launch: launch)
        }
        guard let project = bestMatch(for: query) else {
            return AgentLauncherResult(
                outcome: .noProjectMatch, application: application, query: query, project: nil,
                message: L("未找到匹配项目：\(query)", "No matching project: \(query)")
            )
        }
        return await openRequest(
            application: application, query: query, project: project, launch: launch
        )
    }

    /// Opens an indexed Codex chat without converting it into a new terminal session.
    ///
    /// Args:
    ///   session: Indexed Codex chat with its original technical thread ID.
    ///   launch: Whether to send the desktop open request.
    ///
    /// Returns:
    ///   Open-request outcome and localized feedback; this is not a GUI receipt.
    func resumeSession(_ session: CodexSessionIndexEntry, launch: Bool = true) async -> AgentLauncherResult {
        guard installationChecker(.codex) else {
            return unavailableResult(application: .codex, query: session.workspaceName)
        }
        return await openRequest(
            application: .codex, query: session.workspaceName, sessionID: session.id, launch: launch
        )
    }

    /// Resolves the explicit preference, or chooses an installed app on first use.
    ///
    /// Returns:
    ///   Stored desktop agent, or the first installed app with Codex preferred.
    func preferredApplication() -> AgentDesktopApplication {
        if let preferredApplicationProvider { return preferredApplicationProvider() }
        if let stored = UserDefaults.standard.string(forKey: AgentDesktopApplication.storageKey),
           let application = AgentDesktopApplication(rawValue: stored) {
            return application
        }
        return AgentDesktopApplication.allCases.first(where: installationChecker)
            ?? AgentDesktopApplication.defaultValue
    }

    /// Recognizes app-only requests independently of project folder matching.
    ///
    /// Args:
    ///   query: Cleaned spoken name.
    ///   originalText: Original utterance, used to preserve explicit project requests.
    ///
    /// Returns:
    ///   Recognized desktop agent, or nil when the query names a project.
    private func applicationNamed(by query: String, originalText: String) -> AgentDesktopApplication? {
        let trimmedText = originalText.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。！？,.!?；;：: "))
        ).lowercased()
        guard !Self.projectQuerySuffixes.contains(where: trimmedText.hasSuffix) else { return nil }
        switch normalize(query) {
        case "codex", "code x", "chatgpt", "chat gpt": return .codex
        case "claude code", "claudecode", "cloud code", "claude": return .claudeCode
        default: return nil
        }
    }

    /// Produces feedback for an explicitly chosen app that is no longer installed.
    ///
    /// Args:
    ///   application: Desktop agent requested by this invocation.
    ///   query: Original project or application query.
    ///
    /// Returns:
    ///   An unavailable outcome that must not fall through to session matching.
    private func unavailableResult(application: AgentDesktopApplication, query: String) -> AgentLauncherResult {
        AgentLauncherResult(
            outcome: .applicationUnavailable, application: application, query: query, project: nil,
            message: L(
                "未检测到 \(application.displayName)，请安装后重试或在设置中选择其他 Agent",
                "\(application.displayName) was not found. Install it or choose another agent in Settings."
            )
        )
    }

    /// Sends one desktop request and preserves failures without trying another app.
    ///
    /// Args:
    ///   application: Desktop agent fixed for this request.
    ///   query: Cleaned spoken target.
    ///   project: Optional matched project.
    ///   sessionID: Optional existing Codex chat ID.
    ///   launch: Whether to execute the request.
    ///
    /// Returns:
    ///   Desktop dispatch result, including the original error on failure.
    private func openRequest(
        application: AgentDesktopApplication,
        query: String,
        project: AgentLauncherProject? = nil,
        sessionID: String? = nil,
        launch: Bool
    ) async -> AgentLauncherResult {
        do {
            if launch {
                try await desktopOpener(application, project.map { URL(fileURLWithPath: $0.path) }, sessionID)
            }
            let message: String
            if sessionID != nil {
                message = L("已请求打开 Codex 会话：\(query)", "Requested Codex chat: \(query)")
            } else if let project {
                message = L(
                    "已请求用 \(application.displayName) 打开项目：\(project.name)",
                    "Requested \(application.displayName) project: \(project.name)"
                )
            } else {
                message = L("已打开 \(application.displayName)", "Opened \(application.displayName)")
            }
            return AgentLauncherResult(
                outcome: .opened, application: application, query: query, project: project, message: message
            )
        } catch {
            DebugFileLogger.log("AgentLauncherService desktop open failed: \(error.localizedDescription)")
            return AgentLauncherResult(
                outcome: .openFailed, application: application, query: query, project: project,
                message: L(
                    "打开 \(application.displayName) 失败：\(error.localizedDescription)",
                    "Could not open \(application.displayName): \(error.localizedDescription)"
                )
            )
        }
    }

    /// Extracts a project query from spoken launcher text.
    ///
    /// Args:
    ///   text: Final ASR transcript.
    ///
    /// Returns:
    ///   Cleaned project query, or an empty string when the text is too vague.
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
        let suffixes = Self.projectQuerySuffixes
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
