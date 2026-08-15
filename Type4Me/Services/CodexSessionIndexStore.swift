import Foundation

struct CodexSessionIndexConfiguration: Equatable, Sendable {
    static let `default` = CodexSessionIndexConfiguration()

    let activeWindowDays: Int
    let recentMessageLimit: Int
    let maxIndexedSessionFiles: Int
    let tailChunkBytes: Int
    let maxTailScanBytes: Int
    let maxSessionMetadataBytes: Int
    let maxJSONLineBytes: Int
    let maxIndexedMessageCharacters: Int

    /// Creates resource bounds for Codex session indexing.
    ///
    /// Args:
    ///   activeWindowDays: Sessions older than this modification-age window are ignored.
    ///   recentMessageLimit: Maximum meaningful user messages retained per session.
    ///   maxIndexedSessionFiles: Maximum active session files retained in the index.
    ///   tailChunkBytes: Bounded chunk size used while scanning backward from EOF.
    ///   maxTailScanBytes: Maximum tail bytes inspected for one session.
    ///   maxSessionMetadataBytes: Maximum bytes read while locating the first metadata line.
    ///   maxJSONLineBytes: Maximum JSONL record size decoded during tail scanning.
    ///   maxIndexedMessageCharacters: Maximum characters retained from one user message.
    init(
        activeWindowDays: Int = 60,
        recentMessageLimit: Int = 3,
        maxIndexedSessionFiles: Int = 500,
        tailChunkBytes: Int = 64 * 1_024,
        maxTailScanBytes: Int = 8 * 1_024 * 1_024,
        maxSessionMetadataBytes: Int = 2 * 1_024 * 1_024,
        maxJSONLineBytes: Int = 512 * 1_024,
        maxIndexedMessageCharacters: Int = 2_048
    ) {
        precondition(activeWindowDays > 0)
        precondition(recentMessageLimit > 0)
        precondition(maxIndexedSessionFiles > 0)
        precondition(tailChunkBytes > 0)
        precondition(maxTailScanBytes >= tailChunkBytes)
        precondition(maxSessionMetadataBytes > 0)
        precondition(maxJSONLineBytes > 0)
        precondition(maxIndexedMessageCharacters > 0)
        self.activeWindowDays = activeWindowDays
        self.recentMessageLimit = recentMessageLimit
        self.maxIndexedSessionFiles = maxIndexedSessionFiles
        self.tailChunkBytes = tailChunkBytes
        self.maxTailScanBytes = maxTailScanBytes
        self.maxSessionMetadataBytes = maxSessionMetadataBytes
        self.maxJSONLineBytes = maxJSONLineBytes
        self.maxIndexedMessageCharacters = maxIndexedMessageCharacters
    }

    var activeWindow: TimeInterval {
        TimeInterval(activeWindowDays) * 24 * 60 * 60
    }
}

struct CodexSessionIndexEntry: Codable, Equatable, Sendable {
    let id: String
    let cwd: String
    let matchTexts: [String]
    let updatedAt: TimeInterval
    let sourceFilePath: String?
    let sourceFileSize: UInt64?
    let sourceFileModifiedAt: TimeInterval?

    /// Creates one compact cached session entry.
    ///
    /// Args:
    ///   id: Codex session identifier used by `codex resume`.
    ///   cwd: Working directory associated with the session.
    ///   matchTexts: Recent meaningful user messages used for fuzzy matching.
    ///   updatedAt: Source file modification time used for result ordering.
    ///   sourceFilePath: Source JSONL path used for cache invalidation.
    ///   sourceFileSize: Source size used as a lightweight content fingerprint.
    ///   sourceFileModifiedAt: Source modification time used as a fingerprint.
    init(
        id: String,
        cwd: String,
        matchTexts: [String],
        updatedAt: TimeInterval,
        sourceFilePath: String?,
        sourceFileSize: UInt64? = nil,
        sourceFileModifiedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.matchTexts = matchTexts
        self.updatedAt = updatedAt
        self.sourceFilePath = sourceFilePath
        self.sourceFileSize = sourceFileSize
        self.sourceFileModifiedAt = sourceFileModifiedAt
    }

    var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

final class CodexSessionIndexStore: @unchecked Sendable {
    static let shared = CodexSessionIndexStore()

    static let defaultSessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    private struct SessionFileDescriptor {
        let url: URL
        let modifiedAt: TimeInterval
        let size: UInt64

        var standardizedPath: String {
            url.standardizedFileURL.path
        }
    }

    private struct SessionMetadataRecord: Decodable {
        struct Payload: Decodable {
            let id: String?
            let cwd: String?
        }

        let type: String
        let payload: Payload
    }

    private struct SessionEventRecord: Decodable {
        struct Payload: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let payload: Payload
    }

    private struct BuildResult {
        let sessions: [CodexSessionIndexEntry]
        let reusedCount: Int
        let rebuiltCount: Int
    }

    private struct CachedSessionSnapshot {
        let sessions: [CodexSessionIndexEntry]
        let requiresRewrite: Bool
    }

    private static let userMessageMarker = Data("user_message".utf8)

    private let sessionsRoot: URL
    private let cacheURL: URL
    private let fileManager: FileManager
    private let matcher: AgentFuzzyMatcher
    private let configuration: CodexSessionIndexConfiguration
    private let reconcileLock = NSLock()

    /// Creates a Codex session index reader.
    ///
    /// Args:
    ///   sessionsRoot: Root directory containing Codex session JSONL files.
    ///   cacheURL: Persistent cache file used by routing.
    ///   fileManager: File manager used for recursive session discovery.
    ///   matcher: Fuzzy matcher used to select sessions by recent user messages.
    ///   configuration: Resource and retention bounds applied while indexing.
    init(
        sessionsRoot: URL = CodexSessionIndexStore.defaultSessionsRoot,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default,
        matcher: AgentFuzzyMatcher = AgentFuzzyMatcher(),
        configuration: CodexSessionIndexConfiguration = .default
    ) {
        self.sessionsRoot = sessionsRoot
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(for: sessionsRoot)
        self.fileManager = fileManager
        self.matcher = matcher
        self.configuration = configuration
    }

    /// Loads indexed Codex sessions from the compact disk cache.
    ///
    /// Returns:
    ///   Cached sessions, or a freshly reconciled index when no cache exists.
    func loadSessions() -> [CodexSessionIndexEntry] {
        if let cached = readCachedSessions(), !cached.isEmpty {
            return cached
        }
        return reconcileSessionIndex()
    }

    /// Incrementally reconciles the persistent session index against active JSONL files.
    ///
    /// Returns:
    ///   Active cached entries after reusing unchanged fingerprints and rebuilding only changes.
    @discardableResult
    func reconcileSessionIndex() -> [CodexSessionIndexEntry] {
        reconcileLock.lock()
        defer { reconcileLock.unlock() }

        let cachedSnapshot = readCachedSessionSnapshot()
        let cached = cachedSnapshot?.sessions ?? []
        let result = buildSessionsFromDisk(cachedSessions: cached)
        let sortedCached = cached.sorted { $0.updatedAt > $1.updatedAt }
        if result.sessions != sortedCached || cachedSnapshot?.requiresRewrite != false {
            writeCachedSessions(result.sessions)
        }
        DebugFileLogger.log(
            "Codex session index reconciled active=\(result.sessions.count) reused=\(result.reusedCount) rebuilt=\(result.rebuiltCount)"
        )
        return result.sessions
    }

    /// Finds the best cached session match for a spoken query.
    ///
    /// Args:
    ///   query: Spoken agent routing query.
    ///
    /// Returns:
    ///   Accepted session, or `nil` when the match is weak or ambiguous.
    func bestMatch(for query: String) -> CodexSessionIndexEntry? {
        bestMatch(for: query, in: readCachedSessions() ?? [])
    }

    /// Scores a supplied set of cached sessions and rejects weak or ambiguous matches.
    ///
    /// Args:
    ///   query: Spoken agent routing query.
    ///   sessions: Cached session entries eligible for matching.
    ///
    /// Returns:
    ///   Highest-confidence session, or `nil` when acceptance checks fail.
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

    /// Builds the active index while reusing cache entries with unchanged fingerprints.
    ///
    /// Args:
    ///   cachedSessions: Valid entries loaded from the prior disk cache.
    ///
    /// Returns:
    ///   Sorted sessions plus counts describing reuse and rebuild work.
    private func buildSessionsFromDisk(cachedSessions: [CodexSessionIndexEntry]) -> BuildResult {
        var cachedByPath: [String: CodexSessionIndexEntry] = [:]
        for entry in cachedSessions {
            guard let sourceFilePath = entry.sourceFilePath else { continue }
            cachedByPath[URL(fileURLWithPath: sourceFilePath).standardizedFileURL.path] = entry
        }

        var sessions: [CodexSessionIndexEntry] = []
        var reusedCount = 0
        var rebuiltCount = 0
        for descriptor in sessionFiles() {
            if let cached = cachedByPath[descriptor.standardizedPath],
               cacheEntry(cached, matches: descriptor) {
                sessions.append(cached)
                reusedCount += 1
                continue
            }

            let parsed = autoreleasepool {
                parseSessionFile(descriptor)
            }
            if let parsed {
                sessions.append(parsed)
                rebuiltCount += 1
            }
        }
        return BuildResult(
            sessions: sessions.sorted { $0.updatedAt > $1.updatedAt },
            reusedCount: reusedCount,
            rebuiltCount: rebuiltCount
        )
    }

    /// Enumerates recently active JSONL files using filesystem metadata only.
    ///
    /// Returns:
    ///   Newest bounded set of active session file descriptors.
    private func sessionFiles() -> [SessionFileDescriptor] {
        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let cutoff = Date().timeIntervalSince1970 - configuration.activeWindow
        var files: [SessionFileDescriptor] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile != false,
                  let modifiedAt = values.contentModificationDate?.timeIntervalSince1970,
                  modifiedAt >= cutoff,
                  let fileSize = values.fileSize,
                  fileSize > 0 else {
                continue
            }
            files.append(
                SessionFileDescriptor(
                    url: fileURL,
                    modifiedAt: modifiedAt,
                    size: UInt64(fileSize)
                )
            )
        }
        return Array(
            files
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(configuration.maxIndexedSessionFiles)
        )
    }

    /// Checks whether a cached source fingerprint still matches its session file.
    ///
    /// Args:
    ///   entry: Cached session entry to validate.
    ///   descriptor: Current filesystem metadata for the source file.
    ///
    /// Returns:
    ///   `true` when source size and modification time are unchanged.
    private func cacheEntry(
        _ entry: CodexSessionIndexEntry,
        matches descriptor: SessionFileDescriptor
    ) -> Bool {
        guard entry.sourceFileSize == descriptor.size,
              let cachedModifiedAt = entry.sourceFileModifiedAt else {
            return false
        }
        return abs(cachedModifiedAt - descriptor.modifiedAt) <= 0.001
    }

    /// Parses bounded metadata and recent messages from one changed session file.
    ///
    /// Args:
    ///   descriptor: Source file metadata and URL.
    ///
    /// Returns:
    ///   Compact index entry, or `nil` when required session data is unavailable.
    private func parseSessionFile(_ descriptor: SessionFileDescriptor) -> CodexSessionIndexEntry? {
        guard let handle = try? FileHandle(forReadingFrom: descriptor.url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let metadataData = readFirstLine(from: handle),
              let metadata = try? JSONDecoder().decode(SessionMetadataRecord.self, from: metadataData),
              metadata.type == "session_meta",
              let id = metadata.payload.id,
              let cwd = metadata.payload.cwd else {
            return nil
        }

        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        guard fileManager.fileExists(atPath: cwdURL.path) else {
            return nil
        }
        let recentMessages = readRecentMessages(from: handle, fileSize: descriptor.size)
        guard !recentMessages.isEmpty else {
            return nil
        }
        return CodexSessionIndexEntry(
            id: id,
            cwd: cwdURL.path,
            matchTexts: recentMessages,
            updatedAt: descriptor.modifiedAt,
            sourceFilePath: descriptor.standardizedPath,
            sourceFileSize: descriptor.size,
            sourceFileModifiedAt: descriptor.modifiedAt
        )
    }

    /// Reads only the bounded first JSONL record containing session metadata.
    ///
    /// Args:
    ///   handle: Open session file handle.
    ///
    /// Returns:
    ///   First line bytes without its newline, or `nil` when absent or oversized.
    private func readFirstLine(from handle: FileHandle) -> Data? {
        do {
            try handle.seek(toOffset: 0)
            var line = Data()
            while line.count < configuration.maxSessionMetadataBytes {
                let remaining = configuration.maxSessionMetadataBytes - line.count
                let readCount = min(configuration.tailChunkBytes, remaining)
                guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                    return line.isEmpty ? nil : line
                }
                if let newline = chunk.firstIndex(of: 0x0A) {
                    line.append(contentsOf: chunk[..<newline])
                    return line
                }
                line.append(chunk)
            }
        } catch {
            DebugFileLogger.log("Codex session metadata read failed: \(error.localizedDescription)")
        }
        return nil
    }

    /// Scans backward in bounded chunks and extracts recent meaningful user messages.
    ///
    /// Args:
    ///   handle: Open session file handle.
    ///   fileSize: Current source file size in bytes.
    ///
    /// Returns:
    ///   Newest meaningful messages, ordered newest first.
    private func readRecentMessages(
        from handle: FileHandle,
        fileSize: UInt64
    ) -> [String] {
        var messages: [String] = []
        var scanEnd = fileSize
        var lineEnd = fileSize
        var scannedBytes: UInt64 = 0
        let scanLimit = min(fileSize, UInt64(configuration.maxTailScanBytes))

        while scanEnd > 0,
              scannedBytes < scanLimit,
              messages.count < configuration.recentMessageLimit {
            let remainingBudget = scanLimit - scannedBytes
            let readCount = min(
                UInt64(configuration.tailChunkBytes),
                min(scanEnd, remainingBudget)
            )
            let chunkStart = scanEnd - readCount
            guard let chunk = readData(
                from: handle,
                offset: chunkStart,
                count: Int(readCount)
            ), !chunk.isEmpty else {
                break
            }

            for index in chunk.indices.reversed() where chunk[index] == 0x0A {
                let localOffset = chunk.distance(from: chunk.startIndex, to: index)
                let newlineOffset = chunkStart + UInt64(localOffset)
                if newlineOffset + 1 < lineEnd,
                   let message = readIndexedMessage(
                       from: handle,
                       start: newlineOffset + 1,
                       end: lineEnd
                   ) {
                    messages.append(message)
                    if messages.count == configuration.recentMessageLimit {
                        break
                    }
                }
                lineEnd = newlineOffset
            }
            scanEnd = chunkStart
            scannedBytes += UInt64(chunk.count)
        }

        if messages.count < configuration.recentMessageLimit,
           scanEnd == 0,
           lineEnd > 0,
           let message = readIndexedMessage(from: handle, start: 0, end: lineEnd) {
            messages.append(message)
        }
        return messages
    }

    /// Decodes one bounded JSONL range when it is a user-message event.
    ///
    /// Args:
    ///   handle: Open session file handle.
    ///   start: Inclusive byte offset for the JSONL record.
    ///   end: Exclusive byte offset for the JSONL record.
    ///
    /// Returns:
    ///   Bounded meaningful message, or `nil` for irrelevant or oversized records.
    private func readIndexedMessage(
        from handle: FileHandle,
        start: UInt64,
        end: UInt64
    ) -> String? {
        guard end > start else { return nil }
        let length = end - start
        guard length <= UInt64(configuration.maxJSONLineBytes),
              let lineData = readData(from: handle, offset: start, count: Int(length)),
              lineData.range(of: Self.userMessageMarker) != nil,
              let event = try? JSONDecoder().decode(SessionEventRecord.self, from: lineData),
              event.type == "event_msg",
              event.payload.type == "user_message",
              let message = event.payload.message else {
            return nil
        }
        return boundedMeaningfulMessage(message)
    }

    /// Reads an exact byte range without materializing the complete session file.
    ///
    /// Args:
    ///   handle: Open session file handle.
    ///   offset: Inclusive source byte offset.
    ///   count: Exact byte count requested.
    ///
    /// Returns:
    ///   Requested bytes, or `nil` after a seek, read, or short-read failure.
    private func readData(
        from handle: FileHandle,
        offset: UInt64,
        count: Int
    ) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// Filters control or injected context messages and enforces the index text limit.
    ///
    /// Args:
    ///   message: Raw Codex user-message payload.
    ///
    /// Returns:
    ///   Trimmed bounded message, or `nil` when it should not be indexed.
    private func boundedMeaningfulMessage(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            return nil
        }
        let bounded = String(trimmed.prefix(configuration.maxIndexedMessageCharacters))
        let lower = bounded.lowercased()
        if lower.hasPrefix("# agents.md") ||
            lower.contains("<environment_context>") ||
            lower.contains("<instructions>") {
            return nil
        }
        let normalized = matcher.normalize(bounded).lowercased()
        let controlMessages: Set<String> = ["go", "ok", "确认", "继续", "不对", "启动", "重启"]
        return controlMessages.contains(normalized) ? nil : bounded
    }

    /// Loads valid sessions from the compact disk cache.
    ///
    /// Returns:
    ///   Valid cached sessions, or `nil` when the cache is absent or unreadable.
    private func readCachedSessions() -> [CodexSessionIndexEntry]? {
        readCachedSessionSnapshot()?.sessions
    }

    /// Loads the cache and records whether missing files require cache cleanup.
    ///
    /// Returns:
    ///   Filtered cache snapshot, or `nil` when decoding is unavailable.
    private func readCachedSessionSnapshot() -> CachedSessionSnapshot? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([CodexSessionIndexEntry].self, from: data) else {
            return nil
        }
        let cutoff = Date().timeIntervalSince1970 - configuration.activeWindow
        let validEntries = entries.filter { entry in
            let cwdExists = fileManager.fileExists(atPath: entry.cwd)
            let sourceExists = entry.sourceFilePath.map { fileManager.fileExists(atPath: $0) } ?? true
            return entry.updatedAt >= cutoff && cwdExists && sourceExists
        }
        return CachedSessionSnapshot(
            sessions: validEntries,
            requiresRewrite: validEntries.count != entries.count
        )
    }

    /// Atomically persists compact session entries.
    ///
    /// Args:
    ///   sessions: Fully reconciled session entries to encode.
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

    /// Resolves the default cache path for production and isolated session roots.
    ///
    /// Args:
    ///   sessionsRoot: Session root associated with the cache.
    ///
    /// Returns:
    ///   Application-support cache URL for production, or a sibling URL for tests.
    private static func defaultCacheURL(for sessionsRoot: URL) -> URL {
        let standardizedRoot = sessionsRoot.standardizedFileURL
        if standardizedRoot == defaultSessionsRoot.standardizedFileURL {
            return AppIdentity.appSupportDirectory().appendingPathComponent("codex-sessions-index.json")
        }
        return standardizedRoot.deletingLastPathComponent().appendingPathComponent("codex-sessions-index.json")
    }
}
