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
            return try readDatabase(at: databaseURL, indexedTitles: titles)
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

    /// Projects identity, mode-specific display titles, workspace and time from a read-only connection.
    ///
    /// Args:
    ///   url: Latest known state database.
    ///   indexedTitles: Independent UI names used according to the persisted history contract.
    ///
    /// Returns:
    ///   Non-archived conversations. Missing titles do not invalidate native session identities.
    ///   Message previews and first-user-message fields are never queried.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: SQLite cannot safely read the expected metadata schema.
    ///   CancellationError: The routing task was cancelled.
    private func readDatabase(at url: URL, indexedTitles: [String: IndexedTitle]) throws -> [AgentSessionDescriptor] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw AgentSessionCatalogError.databaseReadFailed
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
            throw AgentSessionCatalogError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: configuration.maximumDatabaseRows))
        var sessions: [AgentSessionDescriptor] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw AgentSessionCatalogError.databaseReadFailed }
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
            throw AgentSessionCatalogError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw AgentSessionCatalogError.databaseReadFailed }
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
