import Foundation

struct CodexSessionIndexEntry: Codable, Equatable, Sendable {
    let id: String
    let cwd: String
    let matchTexts: [String]
    let updatedAt: TimeInterval
    let sourceFilePath: String?

    var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

final class CodexSessionIndexStore: @unchecked Sendable {
    static let recentMessageLimit = 3
    static let maxIndexedSessionFiles = 500

    private static let defaultSessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    private let sessionsRoot: URL
    private let cacheURL: URL
    private let fileManager: FileManager
    private let matcher: AgentFuzzyMatcher
    private let dateFormatter = ISO8601DateFormatter()

    /// Creates a Codex session index reader.
    ///
    /// Args:
    ///   sessionsRoot: Root directory containing Codex session jsonl files.
    ///   cacheURL: Persistent cache file used by routing.
    ///   fileManager: File manager used for recursive session discovery.
    ///   matcher: Fuzzy matcher used to select sessions by recent user messages.
    init(
        sessionsRoot: URL = CodexSessionIndexStore.defaultSessionsRoot,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default,
        matcher: AgentFuzzyMatcher = AgentFuzzyMatcher()
    ) {
        self.sessionsRoot = sessionsRoot
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(for: sessionsRoot)
        self.fileManager = fileManager
        self.matcher = matcher
    }

    /// Loads indexed Codex sessions from jsonl files.
    ///
    /// Returns:
    ///   Sessions with a valid id, cwd, and at least one meaningful user message.
    func loadSessions() -> [CodexSessionIndexEntry] {
        if let cached = readCachedSessions(), !cached.isEmpty {
            return cached
        }
        return reconcileSessionIndex()
    }

    /// Reconciles the persistent session index against current Codex jsonl files.
    ///
    /// Returns:
    ///   Fresh session index entries written to the cache file.
    @discardableResult
    func reconcileSessionIndex() -> [CodexSessionIndexEntry] {
        let sessions = buildSessionsFromDisk()
        writeCachedSessions(sessions)
        return sessions
    }

    /// Finds the best session match for a spoken query.
    ///
    /// Args:
    ///   query: Spoken agent routing query.
    ///
    /// Returns:
    ///   Accepted session, or `nil` when the match is weak or ambiguous.
    func bestMatch(for query: String) -> CodexSessionIndexEntry? {
        bestMatch(for: query, in: readCachedSessions() ?? [])
    }

    private func bestMatch(
        for query: String,
        in sessions: [CodexSessionIndexEntry]
    ) -> CodexSessionIndexEntry? {
        let scored = sessions.enumerated()
            .map { index, entry in
                (
                    index: index,
                    entry: entry,
                    score: entry.matchTexts.map { matcher.score(query: query, candidate: $0) }.max() ?? 0
                )
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.index < $1.index
                }
                return $0.score > $1.score
            }

        guard let best = scored.first, best.score >= matcher.threshold else {
            return nil
        }
        if scored.count > 1, best.score - scored[1].score < matcher.ambiguityMargin {
            return nil
        }
        return best.entry
    }

    private func buildSessionsFromDisk() -> [CodexSessionIndexEntry] {
        sessionFiles()
            .compactMap(parseSessionFile)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func sessionFiles() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: TimeInterval)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            files.append((fileURL, modifiedAt))
        }
        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(Self.maxIndexedSessionFiles)
            .map(\.url)
    }

    private func parseSessionFile(_ fileURL: URL) -> CodexSessionIndexEntry? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var id: String?
        var cwd: String?
        var updatedAt: TimeInterval = fileModifiedAt(fileURL)
        var messages: [String] = []

        for line in content.split(separator: "\n") {
            guard let object = jsonObject(from: String(line)),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if let timestamp = object["timestamp"] as? String,
               let date = dateFormatter.date(from: timestamp) {
                updatedAt = max(updatedAt, date.timeIntervalSince1970)
            }
            switch type {
            case "session_meta":
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
            case "event_msg":
                guard (payload["type"] as? String) == "user_message",
                      let message = payload["message"] as? String,
                      isMeaningfulUserMessage(message) else {
                    continue
                }
                messages.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                continue
            }
        }

        let recentMessages = Array(messages.suffix(Self.recentMessageLimit).reversed())
        guard let id, let cwd, !recentMessages.isEmpty else {
            return nil
        }
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        guard fileManager.fileExists(atPath: cwdURL.path) else {
            return nil
        }
        return CodexSessionIndexEntry(
            id: id,
            cwd: cwdURL.path,
            matchTexts: recentMessages,
            updatedAt: updatedAt,
            sourceFilePath: fileURL.standardizedFileURL.path
        )
    }

    private func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isMeaningfulUserMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            return false
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("# agents.md") ||
            lower.contains("<environment_context>") ||
            lower.contains("<instructions>") {
            return false
        }
        let normalized = matcher.normalize(trimmed).lowercased()
        let controlMessages: Set<String> = ["go", "ok", "确认", "继续", "不对", "启动", "重启"]
        return !controlMessages.contains(normalized)
    }

    private func fileModifiedAt(_ fileURL: URL) -> TimeInterval {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)?
            .timeIntervalSince1970 ?? 0
    }

    private func readCachedSessions() -> [CodexSessionIndexEntry]? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([CodexSessionIndexEntry].self, from: data) else {
            return nil
        }
        return entries.filter { entry in
            let cwdExists = fileManager.fileExists(atPath: entry.cwd)
            let sourceExists = entry.sourceFilePath.map { fileManager.fileExists(atPath: $0) } ?? true
            return cwdExists && sourceExists
        }
    }

    private func writeCachedSessions(_ sessions: [CodexSessionIndexEntry]) {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            DebugFileLogger.log("CodexSessionIndexStore cache write failed: \(error.localizedDescription)")
        }
    }

    private static func defaultCacheURL(for sessionsRoot: URL) -> URL {
        let standardizedRoot = sessionsRoot.standardizedFileURL
        if standardizedRoot == defaultSessionsRoot.standardizedFileURL {
            return AppIdentity.appSupportDirectory().appendingPathComponent("codex-sessions-index.json")
        }
        return standardizedRoot.deletingLastPathComponent().appendingPathComponent("codex-sessions-index.json")
    }
}
