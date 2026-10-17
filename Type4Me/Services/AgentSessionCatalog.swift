import Darwin
import Foundation
import SQLite3

enum AgentSessionOpenCapability: String, Codable, Sendable {
    case codexDeepLink
    case claudeNativeDeepLink
    case unsupported
}

struct AgentSessionDescriptor: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let application: AgentDesktopApplication
    let title: String
    let workspacePath: String?
    let updatedAt: TimeInterval
    let matchTexts: [String]
    let openCapability: AgentSessionOpenCapability
    let engineSessionID: String?
    let transcriptPath: String?

    /// Creates a native conversation descriptor with an optional transcript identity.
    ///
    /// Args:
    ///   sessionID: Stable native Desktop conversation identifier.
    ///   application: Desktop application that owns the conversation.
    ///   title: Native user-facing title, kept verbatim; empty when no title is available.
    ///   workspacePath: Optional native workspace metadata, never a matching key.
    ///   updatedAt: Native activity timestamp in seconds.
    ///   matchTexts: Existing metadata labels used for explicit title matching.
    ///   openCapability: Verified navigation capability of the owning application.
    ///   engineSessionID: Optional CLI transcript UUID linked by native metadata.
    ///   transcriptPath: Optional exact transcript location recorded by the owning agent.
    init(
        sessionID: String, application: AgentDesktopApplication, title: String,
        workspacePath: String?, updatedAt: TimeInterval, matchTexts: [String],
        openCapability: AgentSessionOpenCapability, engineSessionID: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.application = application
        self.title = title
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
        self.matchTexts = matchTexts
        self.openCapability = openCapability
        self.engineSessionID = engineSessionID
        self.transcriptPath = transcriptPath
    }

    var id: String { application.rawValue + ":" + sessionID }

    /// Renders an unnamed conversation without persisting or matching a translated placeholder.
    ///
    /// Args:
    ///   title: Native or user-assigned title; an empty string means unnamed.
    ///   language: Current interface language, observed by the presenting view.
    ///
    /// Returns:
    ///   The original title or a localized display-only label.
    static func displayTitle(_ title: String, language: AppLanguage) -> String {
        title.isEmpty ? (language == .zh ? "未命名会话" : "Untitled conversation") : title
    }

    // Navigation is supported by the matching app; acceptance is not a GUI location receipt.
    var canOpenExistingConversation: Bool {
        switch (application, openCapability) {
        case (.codex, .codexDeepLink), (.claudeCode, .claudeNativeDeepLink): return true
        default: return false
        }
    }
}

struct AgentSessionCatalogSnapshot: Equatable, Sendable {
    let sessions: [AgentSessionDescriptor]
    let unavailableApplications: [AgentDesktopApplication]
}

enum AgentSessionCatalogError: Error, Equatable {
    case metadataUnavailable
    case incompatibleSchema
    case databaseReadFailed
    case metadataReadFailed
}

final class AgentSessionCatalog: @unchecked Sendable {
    typealias SessionLoader = @Sendable () throws -> [AgentSessionDescriptor]
    static let shared = AgentSessionCatalog()

    private let codexLoader: SessionLoader
    private let claudeLoader: SessionLoader

    /// Creates independent metadata providers without starting either desktop agent.
    ///
    /// Args:
    ///   codexLoader: Optional metadata reader for isolated fixtures.
    ///   claudeLoader: Optional native Desktop metadata reader for isolated fixtures.
    init(codexLoader: SessionLoader? = nil, claudeLoader: SessionLoader? = nil) {
        self.codexLoader = codexLoader ?? { try CodexMetadataSessionCatalog().loadSessions() }
        self.claudeLoader = claudeLoader ?? { try ClaudeCodeSessionCatalog().loadSessions() }
    }

    /// Collects native conversations independently of whether they have a display title.
    ///
    /// Returns:
    ///   Metadata candidates and applications lacking a reliable existing-chat opening route.
    ///
    /// Raises:
    ///   CancellationError: The containing routing task was cancelled.
    func loadSessions() throws -> AgentSessionCatalogSnapshot {
        try Task.checkCancellation()
        var sessions: [AgentSessionDescriptor] = []
        var unavailable: [AgentDesktopApplication] = []
        do {
            sessions += try codexLoader().filter { $0.application == .codex }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            unavailable.append(.codex)
        }
        try Task.checkCancellation()
        do {
            let nativeSessions = try claudeLoader().filter { $0.application == .claudeCode }
            sessions += nativeSessions
            if nativeSessions.contains(where: { !$0.canOpenExistingConversation }) {
                unavailable.append(.claudeCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Native metadata is optional; a failed provider must not hide Codex candidates.
            unavailable.append(.claudeCode)
        }
        try Task.checkCancellation()
        var unique: [String: AgentSessionDescriptor] = [:]
        for session in sessions {
            if let previous = unique[session.id], previous.updatedAt >= session.updatedAt { continue }
            unique[session.id] = session
        }
        return AgentSessionCatalogSnapshot(
            sessions: unique.values.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
            },
            unavailableApplications: unavailable
        )
    }
}

struct AgentSessionMetadataValidation {
    static let maximumIdentifierCharacters = 256
    static let maximumClaudeNativeIdentifierSuffixCharacters = 64
    static let maximumWorkspaceCharacters = 4096

    /// Validates identifiers used as one public navigation path component.
    ///
    /// Args:
    ///   value: Identifier from a metadata source.
    ///
    /// Returns:
    ///   Whether the non-empty identifier contains only ASCII letters, digits, dashes or underscores.
    static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumIdentifierCharacters && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Validates an exact native Code identity accepted by Claude's continue entry point.
    ///
    /// Args:
    ///   value: Native metadata session identifier, never a CLI resume identifier.
    ///
    /// Returns:
    ///   Whether the identifier has the native prefix and a bounded ASCII suffix.
    static func isValidClaudeNativeIdentifier(_ value: String) -> Bool {
        let prefix = "local_"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.utf8.count <= maximumClaudeNativeIdentifierSuffixCharacters
            && suffix.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
    }

    /// Keeps genuine non-empty titles rather than manufacturing names from messages or paths.
    ///
    /// Args:
    ///   value: Optional user-facing title.
    ///   maximumCharacters: Maximum accepted title length.
    ///
    /// Returns:
    ///   Trimmed title, or nil for missing, oversized or invalid metadata.
    static func title(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value, value.count <= maximumCharacters, !value.contains("\0") else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Accepts absolute local workspace metadata without requiring the old folder to still exist.
    ///
    /// Args:
    ///   value: Optional absolute directory recorded by the agent.
    ///
    /// Returns:
    ///   Standardized local path, or nil for malformed metadata.
    static func workspace(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.count <= maximumWorkspaceCharacters,
              !value.contains("\0") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    }
}

final class CodexMetadataSessionCatalog: @unchecked Sendable {
    struct Configuration: Sendable {
        var maximumSessions = 2000
        var maximumDatabaseRows = 2000
        var maximumDirectoryEntries = 1000
        var maximumIndexBytes = 2 * 1024 * 1024
        var maximumIndexLineBytes = 16 * 1024
        var maximumIndexRecords = 10000
        var maximumTitleCharacters = 512
        var databaseBusyTimeoutMilliseconds: Int32 = 150
        var databaseQueryTimeout: TimeInterval = 1
        var maximumDatabaseSnapshotBytes = 64 * 1024 * 1024
        var millisecondsPerSecond: Double = 1000
    }

    private struct TitleRecord: Decodable {
        let id: String
        let thread_name: String?
        let updated_at: String
    }

    private struct IndexedTitle {
        let title: String?
        let updatedAt: TimeInterval
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let stage: String

        /// Captures a SQLite failure without retaining database or conversation contents.
        ///
        /// Args:
        ///   database: Connection reporting the error, if one was allocated.
        ///   stage: Static diagnostic label for the failed operation.
        init(_ database: OpaquePointer?, stage: String) {
            code = sqlite3_extended_errcode(database)
            self.stage = stage
        }
    }

    private enum SnapshotError: Error {
        case unavailable
    }

    private final class QueryDeadline {
        let expiresAt: TimeInterval

        /// Records a monotonic SQLite query deadline for its C progress callback.
        ///
        /// Args:
        ///   timeout: Maximum metadata query duration in seconds.
        init(timeout: TimeInterval) {
            expiresAt = ProcessInfo.processInfo.systemUptime + timeout
        }
    }

    private static let queryProgressInterval: Int32 = 1000

    private let metadataDirectory: URL
    private let configuration: Configuration
    private let fileManager: FileManager

    /// Creates a read-only adapter for Codex's local metadata files.
    ///
    /// Args:
    ///   metadataDirectory: Codex home containing state databases and its title index.
    ///   configuration: Query, memory and file enumeration bounds.
    ///   fileManager: Filesystem interface used for metadata discovery.
    init(
        metadataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        precondition(configuration.maximumSessions > 0 && configuration.maximumDatabaseRows > 0)
        precondition(configuration.maximumDirectoryEntries > 0 && configuration.maximumIndexBytes > 0)
        precondition(configuration.maximumIndexLineBytes > 0 && configuration.maximumIndexRecords > 0)
        precondition(configuration.maximumTitleCharacters > 0 && configuration.databaseQueryTimeout > 0)
        precondition(configuration.databaseBusyTimeoutMilliseconds >= 0 && configuration.millisecondsPerSecond > 0)
        precondition(configuration.maximumDatabaseSnapshotBytes > 0 && configuration.maximumDatabaseSnapshotBytes < Int.max)
        precondition(configuration.millisecondsPerSecond.isFinite && configuration.databaseQueryTimeout.isFinite)
        self.metadataDirectory = metadataDirectory
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Reads names and identifiers without inspecting rollout messages or creating an app server.
    ///
    /// Returns:
    ///   Recent Codex conversations eligible for a public navigation request, including unnamed ones.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: The metadata source is missing, unreadable or incompatible.
    ///   CancellationError: Routing was cancelled while reading metadata.
    func loadSessions() throws -> [AgentSessionDescriptor] {
        try Task.checkCancellation()
        let titlesURL = metadataDirectory.appendingPathComponent("session_index.jsonl")
        let hasTitleIndex = fileManager.fileExists(atPath: titlesURL.path)
        var titles: [String: IndexedTitle] = [:]
        var titleIndexFailed = false
        if hasTitleIndex {
            do {
                titles = try readTitleIndex(at: titlesURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                titleIndexFailed = true
            }
        }
        if let databaseURL = try newestDatabaseURL() {
            do {
                return try readAvailableDatabase(at: databaseURL, indexedTitles: titles)
            } catch let failure as SQLiteReadFailure {
                DebugFileLogger.log("agent catalog provider=codex sqlite_code=\(failure.code) stage=\(failure.stage)")
                throw AgentSessionCatalogError.databaseReadFailed
            }
        }
        guard hasTitleIndex else { throw AgentSessionCatalogError.metadataUnavailable }
        guard !titleIndexFailed else { throw AgentSessionCatalogError.metadataReadFailed }
        return Array(titles.map { id, record in
            AgentSessionDescriptor(
                sessionID: id, application: .codex, title: record.title ?? "", workspacePath: nil,
                updatedAt: record.updatedAt, matchTexts: record.title.map { [$0] } ?? [],
                openCapability: .codexDeepLink
            )
        }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.sessionID < $1.sessionID : $0.updatedAt > $1.updatedAt
        }.prefix(configuration.maximumSessions))
    }

    /// Finds the newest versioned database using bounded, shallow enumeration.
    ///
    /// Returns:
    ///   Latest existing state database, or nil when no database is present.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: Metadata directory cannot be enumerated.
    private func newestDatabaseURL() throws -> URL? {
        guard fileManager.fileExists(atPath: metadataDirectory.path) else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: metadataDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { throw AgentSessionCatalogError.metadataReadFailed }
        var latest: (version: Int, url: URL)?
        for (offset, item) in enumerator.enumerated() {
            try Task.checkCancellation()
            guard offset < configuration.maximumDirectoryEntries else { break }
            guard let url = item as? URL, url.pathExtension == "sqlite" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("state_"), let version = Int(name.dropFirst("state_".count)), version >= 0,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if latest == nil || version > latest!.version { latest = (version, url) }
        }
        return latest?.url
    }

    /// Reads a bounded tail of the title-only index, retaining the newest rename per identifier.
    ///
    /// Args:
    ///   url: Title index JSONL file; never a rollout transcript.
    ///
    /// Returns:
    ///   Valid title metadata, including newer empty names that invalidate an older title.
    ///
    /// Raises:
    ///   Error: The bounded index could not be read.
    private func readTitleIndex(at url: URL) throws -> [String: IndexedTitle] {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AgentSessionCatalogError.metadataReadFailed
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(configuration.maximumIndexBytes) ? size - UInt64(configuration.maximumIndexBytes) : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: configuration.maximumIndexBytes) ?? Data()
        if offset > 0 {
            guard let firstNewline = data.firstIndex(of: 10) else { return [:] }
            data = Data(data[data.index(after: firstNewline)...])
        }
        let preciseDate = ISO8601DateFormatter()
        preciseDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = ISO8601DateFormatter()
        var titles: [String: IndexedTitle] = [:]
        for line in data.split(separator: 10).suffix(configuration.maximumIndexRecords) {
            try Task.checkCancellation()
            guard line.count <= configuration.maximumIndexLineBytes,
                  let record = try? JSONDecoder().decode(TitleRecord.self, from: Data(line)),
                  AgentSessionMetadataValidation.isValidIdentifier(record.id),
                  let timestamp = (preciseDate.date(from: record.updated_at) ?? date.date(from: record.updated_at))?.timeIntervalSince1970,
                  timestamp.isFinite, timestamp > 0 else { continue }
            if let old = titles[record.id], old.updatedAt > timestamp { continue }
            titles[record.id] = IndexedTitle(
                title: AgentSessionMetadataValidation.title(record.thread_name, maximumCharacters: configuration.maximumTitleCharacters),
                updatedAt: timestamp
            )
        }
        return titles
    }

    /// Uses the live WAL when available, or a verified private snapshot of a closed database.
    ///
    /// Args:
    ///   url: Latest state database, which this adapter never opens for writing.
    ///   indexedTitles: Independent title-only metadata.
    ///
    /// Returns:
    ///   Conversations from a normal SQLite read or a stable offline snapshot.
    ///
    /// Raises:
    ///   Error: Neither bounded read is safe, the schema is incompatible, or routing was cancelled.
    private func readAvailableDatabase(at url: URL, indexedTitles: [String: IndexedTitle]) throws -> [AgentSessionDescriptor] {
        do {
            return try readDatabase(at: url, indexedTitles: indexedTitles)
        } catch let failure as SQLiteReadFailure where (failure.code & 0xff) == SQLITE_CANTOPEN {
            DebugFileLogger.log("agent catalog provider=codex sqlite_code=\(failure.code) stage=\(failure.stage) checking_closed_database=true")
            do {
                return try readClosedDatabase(at: url, indexedTitles: indexedTitles)
            } catch SnapshotError.unavailable {
                // The owning app may have reopened during the copy. Retry its normal WAL-aware
                // connection once; never declare a changing source immutable.
                try Task.checkCancellation()
                return try readDatabase(at: url, indexedTitles: indexedTitles)
            }
        }
    }

    /// Copies a bounded, unchanged database only when no transaction sidecars exist.
    ///
    /// Args:
    ///   url: Original database whose bytes and sidecars remain untouched.
    ///   indexedTitles: Independent title-only metadata.
    ///
    /// Returns:
    ///   Conversations read from an owned immutable copy, removed before returning.
    ///
    /// Raises:
    ///   SnapshotError: The source is changing, too large, inaccessible, or has sidecars.
    ///   Error: The snapshot query failed or routing was cancelled.
    private func readClosedDatabase(at url: URL, indexedTitles: [String: IndexedTitle]) throws -> [AgentSessionDescriptor] {
        try Task.checkCancellation()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SnapshotError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= configuration.maximumDatabaseSnapshotBytes,
              sourceMatches(url, fingerprint: before), transactionSidecarsAreAbsent(at: url) else {
            throw SnapshotError.unavailable
        }
        let data: Data
        do {
            data = try handle.read(upToCount: configuration.maximumDatabaseSnapshotBytes + 1) ?? Data()
        } catch {
            throw SnapshotError.unavailable
        }
        try Task.checkCancellation()
        var after = stat()
        guard data.count == before.st_size, fstat(descriptor, &after) == 0,
              sameFile(before, after), sourceMatches(url, fingerprint: before),
              transactionSidecarsAreAbsent(at: url) else { throw SnapshotError.unavailable }

        let directory = fileManager.temporaryDirectory.appendingPathComponent("mytype-codex-metadata-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SnapshotError.unavailable
        }
        defer {
            do { try fileManager.removeItem(at: directory) }
            catch { DebugFileLogger.log("agent catalog provider=codex snapshot_cleanup_failed=true") }
        }
        let snapshotURL = directory.appendingPathComponent("metadata.sqlite")
        do {
            try data.write(to: snapshotURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        } catch {
            throw SnapshotError.unavailable
        }
        // immutable is safe only for this private copy. Using it on the live source would
        // silently omit transactions committed to WAL by a running Codex app.
        let sessions = try readDatabase(at: snapshotURL, indexedTitles: indexedTitles, immutableSnapshot: true)
        DebugFileLogger.log("agent catalog provider=codex closed_database_snapshot=true sessions=\(sessions.count)")
        return sessions
    }

    /// Checks sidecar absence without treating inaccessible files or dangling links as absent.
    ///
    /// Args:
    ///   url: Source database.
    ///
    /// Returns:
    ///   True only when both WAL and rollback journal paths report ENOENT.
    private func transactionSidecarsAreAbsent(at url: URL) -> Bool {
        ["-wal", "-journal"].allSatisfy { suffix in
            var metadata = stat()
            return lstat(url.path + suffix, &metadata) == -1 && errno == ENOENT
        }
    }

    /// Verifies the path still names the same regular file inspected through its open descriptor.
    ///
    /// Args:
    ///   url: Original source path.
    ///   fingerprint: Descriptor metadata captured before copying.
    ///
    /// Returns:
    ///   True when identity, size and nanosecond timestamps are unchanged.
    private func sourceMatches(_ url: URL, fingerprint: stat) -> Bool {
        var current = stat()
        return lstat(url.path, &current) == 0 && (current.st_mode & S_IFMT) == S_IFREG && sameFile(fingerprint, current)
    }

    /// Compares file identity and metadata that change on replacement, writes or truncation.
    ///
    /// Args:
    ///   lhs: Metadata before reading.
    ///   rhs: Metadata after reading.
    ///
    /// Returns:
    ///   True if the snapshots describe an unchanged file.
    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Projects identity, mode-specific display titles, workspace and time from a read-only connection.
    ///
    /// Args:
    ///   url: Latest known state database.
    ///   indexedTitles: Independent UI names used according to the persisted history contract.
    ///   immutableSnapshot: True only for this adapter's private, verified offline copy.
    ///
    /// Returns:
    ///   Non-archived conversations. Missing titles do not invalidate native session identities.
    ///   Message previews and first-user-message fields are never queried.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: SQLite cannot safely read the expected metadata schema.
    ///   CancellationError: The routing task was cancelled.
    private func readDatabase(
        at url: URL, indexedTitles: [String: IndexedTitle], immutableSnapshot: Bool = false
    ) throws -> [AgentSessionDescriptor] {
        var database: OpaquePointer?
        let location = immutableSnapshot ? url.absoluteString + "?mode=ro&immutable=1" : url.path
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (immutableSnapshot ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(location, &database, flags, nil) == SQLITE_OK,
              let database else {
            let failure = SQLiteReadFailure(database, stage: "open")
            if let database { sqlite3_close(database) }
            throw failure
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, configuration.databaseBusyTimeoutMilliseconds)
        let deadline = QueryDeadline(timeout: configuration.databaseQueryTimeout)
        sqlite3_progress_handler(database, Self.queryProgressInterval, { pointer in
            guard let pointer else { return 1 }
            let deadline = Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
            return ProcessInfo.processInfo.systemUptime >= deadline.expiresAt ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            withExtendedLifetime(deadline) {}
        }
        let columns = try databaseColumns(database)
        guard Set(["id", "cwd", "updated_at", "archived"]).isSubset(of: columns) else {
            throw AgentSessionCatalogError.incompatibleSchema
        }
        let timestampExpression = columns.contains("updated_at_ms")
            ? "COALESCE(updated_at_ms, updated_at * \(configuration.millisecondsPerSecond))" : "updated_at"
        let nameExpression = columns.contains("name") ? "substr(name, 1, \(configuration.maximumTitleCharacters + 1))" : "NULL"
        // The official history-mode migration defaults older rows to legacy. Only legacy titles
        // are display metadata; paginated titles remain derived search metadata.
        let legacyCondition = columns.contains("history_mode") ? "history_mode = 'legacy'" : "1"
        let legacyTitleExpression = columns.contains("title")
            ? "CASE WHEN \(legacyCondition) THEN substr(title, 1, \(configuration.maximumTitleCharacters + 1)) ELSE NULL END"
            : "NULL"
        let transcriptExpression = columns.contains("rollout_path")
            ? "substr(rollout_path, 1, \(AgentSessionMetadataValidation.maximumWorkspaceCharacters + 1))" : "NULL"
        let sql = """
            SELECT substr(id, 1, \(AgentSessionMetadataValidation.maximumIdentifierCharacters + 1)),
                   \(nameExpression), substr(cwd, 1, \(AgentSessionMetadataValidation.maximumWorkspaceCharacters + 1)),
                   \(timestampExpression), \(legacyTitleExpression),
                   CASE WHEN \(legacyCondition) THEN 1 ELSE 0 END, \(transcriptExpression)
            FROM threads WHERE archived = 0 ORDER BY \(timestampExpression) DESC, id DESC LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteReadFailure(database, stage: "query_prepare")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: configuration.maximumDatabaseRows))
        var sessions: [AgentSessionDescriptor] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteReadFailure(database, stage: "query_step") }
            guard let id = textColumn(statement, index: 0), AgentSessionMetadataValidation.isValidIdentifier(id) else { continue }
            let databaseName = AgentSessionMetadataValidation.title(textColumn(statement, index: 1), maximumCharacters: configuration.maximumTitleCharacters)
            let indexedTitle = indexedTitles[id]?.title
            let preferredTitle: String?
            if sqlite3_column_int(statement, 5) == 1 {
                let legacyTitle = AgentSessionMetadataValidation.title(textColumn(statement, index: 4), maximumCharacters: configuration.maximumTitleCharacters)
                preferredTitle = legacyTitle ?? indexedTitle ?? databaseName
            } else {
                preferredTitle = databaseName ?? indexedTitle
            }
            let rawTime = sqlite3_column_double(statement, 3)
            let timestamp = columns.contains("updated_at_ms") ? rawTime / configuration.millisecondsPerSecond : rawTime
            guard timestamp.isFinite, timestamp > 0 else { continue }
            sessions.append(AgentSessionDescriptor(
                sessionID: id, application: .codex, title: preferredTitle ?? "",
                workspacePath: AgentSessionMetadataValidation.workspace(textColumn(statement, index: 2)),
                updatedAt: timestamp, matchTexts: preferredTitle.map { [$0] } ?? [], openCapability: .codexDeepLink,
                transcriptPath: AgentSessionMetadataValidation.workspace(textColumn(statement, index: 6))
            ))
            if sessions.count >= configuration.maximumSessions { break }
        }
        return sessions
    }

    /// Introspects column names so an upstream metadata migration cannot silently change meaning.
    ///
    /// Args:
    ///   database: Read-only SQLite connection.
    ///
    /// Returns:
    ///   Available columns of the threads table.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: SQLite schema introspection failed.
    private func databaseColumns(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads);", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteReadFailure(database, stage: "schema_prepare")
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteReadFailure(database, stage: "schema_step") }
            if let column = textColumn(statement, index: 1) { columns.insert(column) }
        }
        return columns
    }

    /// Decodes one optional text column without accessing any other database fields.
    ///
    /// Args:
    ///   statement: Current SQLite row.
    ///   index: Projected text column index.
    ///
    /// Returns:
    ///   UTF-8 text, or nil for SQL NULL.
    private func textColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
