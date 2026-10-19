import Foundation
import SQLite3
import XCTest
@testable import Type4Me

final class AgentSessionCatalogTests: XCTestCase {
    private var rootURL: URL!

    /// Reads a closed WAL database without recreating sidecars or changing its contents.
    ///
    /// Raises:
    ///   Error: The isolated database could not be written or read.
    func testClosedWALDatabaseRemainsReadableWithoutSourceChanges() throws {
        try writeClosedWALDatabase()
        let url = rootURL.appendingPathComponent("state_5.sqlite")
        let original = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let sessions = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(sessions.map(\.sessionID), ["closed_thread"])
        XCTAssertEqual(sessions.first?.title, "Closed conversation")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rootURL.path), ["state_5.sqlite"])
    }

    /// Includes committed WAL-only rows while the owning app keeps its connection open.
    ///
    /// Raises:
    ///   Error: The live synthetic connection could not be created or read.
    func testLiveWALDatabaseIncludesUncheckpointedConversations() throws {
        try writeClosedWALDatabase()
        let url = rootURL.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO threads VALUES('new_thread', 'New conversation', '/workspace', 200, 0);
            """, nil, nil, nil), SQLITE_OK)
        let mainBefore = try Data(contentsOf: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        let walBefore = try Data(contentsOf: walURL)

        let sessions = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(sessions.map(\.sessionID), ["new_thread", "closed_thread"])
        XCTAssertEqual(try Data(contentsOf: url), mainBefore)
        XCTAssertEqual(try Data(contentsOf: walURL), walBefore)
    }

    /// Refuses an offline copy outside the configured memory and disk bound.
    ///
    /// Raises:
    ///   Error: The isolated database could not be prepared.
    func testClosedWALSnapshotHonorsSizeLimit() throws {
        try writeClosedWALDatabase()
        var configuration = CodexMetadataSessionCatalog.Configuration()
        configuration.maximumDatabaseSnapshotBytes = 1

        XCTAssertThrowsError(try CodexMetadataSessionCatalog(metadataDirectory: rootURL, configuration: configuration).loadSessions()) { error in
            XCTAssertEqual(error as? AgentSessionCatalogError, .databaseReadFailed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rootURL.path), ["state_5.sqlite"])
    }

    /// Does not misinterpret a dangling transaction-sidecar link as an absent sidecar.
    ///
    /// Raises:
    ///   Error: The isolated database and link could not be prepared.
    func testClosedWALSnapshotRejectsDanglingJournalLink() throws {
        try writeClosedWALDatabase()
        let journal = rootURL.appendingPathComponent("state_5.sqlite-journal")
        try FileManager.default.createSymbolicLink(atPath: journal.path, withDestinationPath: rootURL.appendingPathComponent("missing-journal").path)

        XCTAssertThrowsError(try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()) { error in
            XCTAssertEqual(error as? AgentSessionCatalogError, .databaseReadFailed)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: journal.path), rootURL.appendingPathComponent("missing-journal").path)
    }

    /// Creates a checkpointed WAL fixture with the sidecars removed, as after app shutdown.
    ///
    /// Raises:
    ///   Error: Only this test's synthetic database could not be prepared.
    private func writeClosedWALDatabase() throws {
        try writeDatabase("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('closed_thread', 'Closed conversation', '/workspace', 100, 0);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        for suffix in ["-wal", "-shm"] {
            let sidecar = rootURL.appendingPathComponent("state_5.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    /// Keeps an unnamed paginated conversation available for a content-search match.
    ///
    /// Raises:
    ///   Error: The isolated Codex metadata fixture could not be created or read.
    func testUnnamedPaginatedSessionRetainsNativeIdentity() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, history_mode TEXT,
                                 cwd TEXT, updated_at INTEGER, archived INTEGER, rollout_path TEXT);
            INSERT INTO threads VALUES('unnamed_target', NULL, 'Derived attachment metadata', 'paginated',
                                       '/workspace', 100, 0, '/agent/session.jsonl');
            """)

        let session = try XCTUnwrap(CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions().first)
        XCTAssertEqual(session.sessionID, "unnamed_target")
        XCTAssertEqual(session.title, "")
        XCTAssertEqual(session.matchTexts, [])
        XCTAssertEqual(session.transcriptPath, "/agent/session.jsonl")
        XCTAssertTrue(session.canOpenExistingConversation)
        let hit = AgentsViewSearchHit(sessionID: "codex:unnamed_target", agent: "codex", snippet: "继续试试别的方法")
        XCTAssertEqual(AgentsViewSearchService.nativeSession(for: hit, in: [session]), session)
    }

    /// Preserves the owning agent's exact transcript path without inferring it from a title.
    ///
    /// Raises:
    ///   Error: The isolated metadata fixture could not be created or read.
    func testDatabaseProjectsExactTranscriptPathForHandoff() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER,
                                 archived INTEGER, rollout_path TEXT);
            INSERT INTO threads VALUES('thread_1', 'Same title', '/workspace', 100, 0,
                                       '/agent/sessions/exact-transcript.jsonl');
            """)

        let session = try XCTUnwrap(CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions().first)
        XCTAssertEqual(session.transcriptPath, "/agent/sessions/exact-transcript.jsonl")
        XCTAssertEqual(session.sessionID, "thread_1")
    }

    /// Keeps older persisted descriptors readable after optional transcript metadata is added.
    ///
    /// Raises:
    ///   Error: The descriptor fixture could not be encoded or decoded.
    func testLegacyDescriptorHasNoInferredTranscriptPath() throws {
        let json = """
            {"sessionID":"thread_1","application":"codex","title":"Title","updatedAt":100,
             "matchTexts":["Title"],"openCapability":"codexDeepLink"}
            """
        let descriptor = try JSONDecoder().decode(AgentSessionDescriptor.self, from: Data(json.utf8))
        XCTAssertNil(descriptor.transcriptPath)
    }

    /// Creates a metadata root isolated from the user's actual agent history.
    ///
    /// Raises:
    ///   Error: The fixture directory could not be created.
    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Removes only this test's metadata fixtures.
    ///
    /// Raises:
    ///   Error: Fixture cleanup failed.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    /// Verifies paginated UI names win over derived title and message fields.
    ///
    /// Raises:
    ///   Error: The SQLite fixture could not be written or read.
    func testDatabaseUsesUINameAndIgnoresMessageFields() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, first_user_message TEXT, preview TEXT, history_mode TEXT,
                                 cwd TEXT, updated_at INTEGER, updated_at_ms INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('thread_1', 'UI 标题', 'Private text', 'Private text', 'Private text',
                                       'paginated', '/project', 100, 100123, 0);
            INSERT INTO threads VALUES('thread_2', NULL, 'Do not infer a title', 'Private text', 'Private text',
                                       'paginated', '/project', 200, 200000, 0);
            INSERT INTO threads VALUES('thread_archived', 'Archived', '', '', '', 'paginated', '/project', 300, 300000, 1);
            """)
        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.map(\.sessionID), ["thread_2", "thread_1"])
        XCTAssertEqual(result.first?.title, "")
        XCTAssertEqual(result.first?.matchTexts, [])
        XCTAssertEqual(result.last?.title, "UI 标题")
        XCTAssertEqual(result.last?.matchTexts, ["UI 标题"])
        XCTAssertEqual(result.last?.updatedAt, 100.123)
        XCTAssertTrue(try XCTUnwrap(result.first).canOpenExistingConversation)
    }

    /// Verifies the title-only index supplies a legacy name when its title and name column are absent.
    ///
    /// Raises:
    ///   Error: Fixture metadata could not be written or read.
    func testTitleIndexJoinsDatabaseBySessionID() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('thread_1', NULL, '/workspace', 100, 0);
            """)
        try writeIndex([
            ["id": "thread_1", "thread_name": "Before rename", "updated_at": "2026-10-01T00:00:00Z"],
            ["id": "thread_1", "thread_name": "Current title", "updated_at": "2026-10-02T00:00:00.100Z"],
        ])

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.first?.title, "Current title")
        XCTAssertEqual(result.first?.workspacePath, "/workspace")
    }

    /// Verifies a pre-history-mode schema preserves the legacy visible title before other names.
    ///
    /// Raises:
    ///   Error: The synthetic SQLite and index fixtures could not be written or read.
    func testOldSchemaUsesLegacyTitleBeforeIndexAndName() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('thread_1', 'Database name', 'Legacy visible title', '/workspace', 100, 0);
            """)
        try writeIndex([["id": "thread_1", "thread_name": "Indexed name", "updated_at": "2026-10-01T00:00:00Z"]])

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.first?.title, "Legacy visible title")
        XCTAssertEqual(result.first?.matchTexts, ["Legacy visible title"])
    }

    /// Verifies missing or invalid legacy titles fall back to the index before a database name.
    ///
    /// Raises:
    ///   Error: The synthetic SQLite and index fixtures could not be written or read.
    func testLegacyMissingTitleFallsBackToIndexThenName() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, history_mode TEXT,
                                 cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('indexed', 'Database name', NULL, 'legacy', '/workspace', 300, 0);
            INSERT INTO threads VALUES('named', 'Database fallback', '  ', 'legacy', '/workspace', 200, 0);
            INSERT INTO threads VALUES('oversized', 'Bounded fallback', 'Oversized legacy title', 'legacy', '/workspace', 100, 0);
            """)
        try writeIndex([["id": "indexed", "thread_name": "Indexed name", "updated_at": "2026-10-01T00:00:00Z"]])
        var configuration = CodexMetadataSessionCatalog.Configuration()
        configuration.maximumTitleCharacters = 20

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL, configuration: configuration).loadSessions()

        XCTAssertEqual(result.map(\.title), ["Indexed name", "Database fallback", "Bounded fallback"])
    }

    /// Verifies a paginated conversation with no explicit name uses its index rather than derived title.
    ///
    /// Raises:
    ///   Error: The synthetic SQLite and index fixtures could not be written or read.
    func testPaginatedMissingNameUsesIndexInsteadOfDerivedTitle() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, history_mode TEXT,
                                 cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('thread_1', NULL, 'Derived search metadata', 'paginated', '/workspace', 100, 0);
            """)
        try writeIndex([["id": "thread_1", "thread_name": "Indexed UI name", "updated_at": "2026-10-01T00:00:00Z"]])

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.first?.title, "Indexed UI name")
        XCTAssertEqual(result.first?.matchTexts, ["Indexed UI name"])
    }

    /// Verifies unknown and null persisted history modes cannot promote a derived title into a UI name.
    ///
    /// Raises:
    ///   Error: The synthetic SQLite and index fixtures could not be written or read.
    func testUnknownHistoryModeUsesOnlyNameOrIndex() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, title TEXT, history_mode TEXT,
                                 cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('named', 'Explicit UI name', 'Derived metadata', 'future_mode', '/workspace', 400, 0);
            INSERT INTO threads VALUES('indexed', NULL, 'Derived metadata', 'future_mode', '/workspace', 300, 0);
            INSERT INTO threads VALUES('untitled', NULL, 'Derived metadata', 'future_mode', '/workspace', 200, 0);
            INSERT INTO threads VALUES('null_mode', NULL, 'Derived metadata', NULL, '/workspace', 100, 0);
            """)
        try writeIndex([["id": "indexed", "thread_name": "Indexed UI name", "updated_at": "2026-10-01T00:00:00Z"]])

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.map(\.sessionID), ["named", "indexed", "untitled", "null_mode"])
        XCTAssertEqual(result.map(\.title), ["Explicit UI name", "Indexed UI name", "", ""])
    }

    /// Verifies default catalog bounds retain conversations beyond the previous 500-result window.
    ///
    /// Raises:
    ///   Error: The bounded synthetic SQLite fixture could not be written or read.
    func testDefaultCandidateLimitRetainsOlderConversations() throws {
        let conversationCount = 501
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            WITH RECURSIVE fixture(sequence) AS (
                SELECT 1 UNION ALL SELECT sequence + 1 FROM fixture WHERE sequence < \(conversationCount)
            )
            INSERT INTO threads SELECT 'thread_' || sequence, 'Synthetic ' || sequence, '/workspace', sequence, 0 FROM fixture;
            """)

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.count, conversationCount)
        XCTAssertEqual(result.first?.sessionID, "thread_501")
        XCTAssertEqual(result.last?.sessionID, "thread_1")
    }

    /// Verifies a newer empty rename cannot revive an old title from the index.
    ///
    /// Raises:
    ///   Error: The title fixture could not be written or read.
    func testNewEmptyTitleInvalidatesOldIndexTitle() throws {
        try writeIndex([
            ["id": "thread_1", "thread_name": "Old title", "updated_at": "2026-10-01T00:00:00Z"],
            ["id": "thread_1", "thread_name": "  ", "updated_at": "2026-10-02T00:00:00Z"],
        ])

        let session = try XCTUnwrap(CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions().first)
        XCTAssertEqual(session.sessionID, "thread_1")
        XCTAssertEqual(session.title, "")
        XCTAssertEqual(session.matchTexts, [])
    }

    /// Verifies index-only metadata retains technical identity without inventing a directory.
    ///
    /// Raises:
    ///   Error: The title fixture could not be written or read.
    func testIndexOnlyListingDoesNotManufactureWorkspace() throws {
        try writeIndex([["id": "thread_1", "thread_name": "Research", "updated_at": "2026-10-01T00:00:00Z"]])

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()

        XCTAssertEqual(result.first?.sessionID, "thread_1")
        XCTAssertNil(result.first?.workspacePath)
    }

    /// Verifies a record-count bound keeps recent renames instead of the oldest tail records.
    ///
    /// Raises:
    ///   Error: The title fixture could not be written or read.
    func testIndexRecordBoundKeepsLatestMetadata() throws {
        try writeIndex([
            ["id": "thread_1", "thread_name": "Old", "updated_at": "2026-10-01T00:00:00Z"],
            ["id": "thread_1", "thread_name": "New", "updated_at": "2026-10-02T00:00:00Z"],
        ])
        var configuration = CodexMetadataSessionCatalog.Configuration()
        configuration.maximumIndexRecords = 1

        XCTAssertEqual(try CodexMetadataSessionCatalog(metadataDirectory: rootURL, configuration: configuration).loadSessions().first?.title, "New")
    }

    /// Verifies malformed identifiers cannot become deep-link paths.
    ///
    /// Raises:
    ///   Error: The title fixture could not be written or read.
    func testMetadataRejectsUnsafeIdentifiers() throws {
        try writeIndex([["id": "../settings", "thread_name": "Research", "updated_at": "2026-10-01T00:00:00Z"]])

        XCTAssertTrue(try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions().isEmpty)
    }

    /// Verifies a newer state schema is not silently replaced with older stale database data.
    ///
    /// Raises:
    ///   Error: The database fixtures could not be written.
    func testIncompatibleNewestDatabaseFailsClosed() throws {
        try writeDatabase("CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);")
        try writeDatabase("CREATE TABLE threads(id TEXT, renamed_field TEXT);", name: "state_6.sqlite")

        XCTAssertThrowsError(try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions()) {
            XCTAssertEqual($0 as? AgentSessionCatalogError, .incompatibleSchema)
        }
    }

    /// Verifies a corrupt title index does not hide a valid independent database name.
    ///
    /// Raises:
    ///   Error: The SQLite fixture could not be written or read.
    func testUnreadableIndexDoesNotHideDatabaseNames() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('thread_1', 'Known title', '/workspace', 100, 0);
            """)
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("session_index.jsonl"), withIntermediateDirectories: true)

        XCTAssertEqual(try CodexMetadataSessionCatalog(metadataDirectory: rootURL).loadSessions().first?.title, "Known title")
    }

    /// Verifies result limits retain the newest valid native conversations.
    ///
    /// Raises:
    ///   Error: The SQLite fixture could not be written or read.
    func testDatabaseResultIsBoundedAndNewestFirst() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('a', 'One', '/workspace', 100, 0);
            INSERT INTO threads VALUES('b', 'Two', '/workspace', 200, 0);
            INSERT INTO threads VALUES('c', 'Three', '/workspace', 300, 0);
            """)
        var configuration = CodexMetadataSessionCatalog.Configuration()
        configuration.maximumSessions = 2

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL, configuration: configuration).loadSessions()

        XCTAssertEqual(result.map(\.sessionID), ["c", "b"])
    }

    /// Verifies migrated seconds-only timestamps participate in ordering before the result bound.
    ///
    /// Raises:
    ///   Error: The synthetic SQLite fixture could not be written or read.
    func testNullableMillisecondTimestampSortsByFallbackSeconds() throws {
        try writeDatabase("""
            CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, updated_at INTEGER,
                                 updated_at_ms INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('older_ms', 'Older milliseconds', '/workspace', 100, 100000, 0);
            INSERT INTO threads VALUES('newer_seconds', 'Newer seconds', '/workspace', 200, NULL, 0);
            """)
        var configuration = CodexMetadataSessionCatalog.Configuration()
        configuration.maximumSessions = 1

        let result = try CodexMetadataSessionCatalog(metadataDirectory: rootURL, configuration: configuration).loadSessions()

        XCTAssertEqual(result.map(\.sessionID), ["newer_seconds"])
        XCTAssertEqual(result.first?.updatedAt, 200)
    }

    /// Verifies one failed provider leaves other providers' real metadata candidates visible.
    ///
    /// Raises:
    ///   Error: The injected catalog unexpectedly failed.
    func testIndependentProvidersPreserveUnavailableCapabilities() throws {
        let candidate = descriptor(application: .claudeCode, capability: .unsupported)
        let catalog = AgentSessionCatalog(
            codexLoader: { throw AgentSessionCatalogError.metadataUnavailable },
            claudeLoader: { [candidate] }
        )

        let snapshot = try catalog.loadSessions()

        XCTAssertEqual(snapshot.sessions, [candidate])
        XCTAssertEqual(snapshot.unavailableApplications, [.codex, .claudeCode])
        XCTAssertEqual(snapshot.absentApplications, [.codex])
        XCTAssertFalse(candidate.canOpenExistingConversation)
    }

    /// Verifies a failed native Claude provider cannot hide a usable Codex conversation.
    ///
    /// Raises:
    ///   Error: The injected catalog unexpectedly failed.
    func testClaudeProviderFailurePreservesCodexCandidate() throws {
        let codex = descriptor(application: .codex, capability: .codexDeepLink)
        let catalog = AgentSessionCatalog(
            codexLoader: { [codex] },
            claudeLoader: { throw AgentSessionCatalogError.metadataReadFailed }
        )

        let snapshot = try catalog.loadSessions()

        XCTAssertEqual(snapshot.sessions, [codex])
        XCTAssertEqual(snapshot.unavailableApplications, [.claudeCode])
        XCTAssertTrue(snapshot.absentApplications.isEmpty)
        XCTAssertTrue(codex.canOpenExistingConversation)
    }

    /// Verifies supported native Claude sessions no longer mark the provider unavailable.
    ///
    /// Raises:
    ///   Error: Descriptor serialization or injected catalog loading failed.
    func testSupportedNativeClaudeProviderRemainsAvailable() throws {
        let codex = descriptor(application: .codex, capability: .codexDeepLink)
        let claude = descriptor(application: .claudeCode, capability: .claudeNativeDeepLink)
        let catalog = AgentSessionCatalog(codexLoader: { [codex] }, claudeLoader: { [claude] })

        let snapshot = try catalog.loadSessions()

        XCTAssertEqual(Set(snapshot.sessions.map(\.id)), Set([codex.id, claude.id]))
        XCTAssertTrue(snapshot.unavailableApplications.isEmpty)
        XCTAssertTrue(claude.canOpenExistingConversation)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentSessionDescriptor.self, from: JSONEncoder().encode(claude)),
            claude
        )
    }

    /// Verifies a provider cannot reuse another provider's existing-session opening capability.
    ///
    /// Returns:
    ///   Nothing. Asserts native Claude and Codex routes remain provider specific.
    func testExistingSessionOpeningRequiresProviderSpecificCapability() {
        XCTAssertFalse(descriptor(application: .claudeCode, capability: .codexDeepLink).canOpenExistingConversation)
        XCTAssertFalse(descriptor(application: .codex, capability: .claudeNativeDeepLink).canOpenExistingConversation)
        XCTAssertFalse(descriptor(application: .codex, capability: .unsupported).canOpenExistingConversation)
        XCTAssertFalse(descriptor(application: .claudeCode, capability: .unsupported).canOpenExistingConversation)
        XCTAssertTrue(descriptor(application: .codex, capability: .codexDeepLink).canOpenExistingConversation)
        XCTAssertTrue(descriptor(application: .claudeCode, capability: .claudeNativeDeepLink).canOpenExistingConversation)
    }

    /// Verifies shared session IDs from different applications remain distinct and serializable.
    ///
    /// Raises:
    ///   Error: Descriptor encoding or catalog loading failed.
    func testDescriptorIdentityAndCodablePreserveApplication() throws {
        let codex = descriptor(application: .codex, capability: .codexDeepLink)
        let claude = descriptor(application: .claudeCode, capability: .unsupported)
        let catalog = AgentSessionCatalog(codexLoader: { [codex] }, claudeLoader: { [claude] })

        XCTAssertNotEqual(codex.id, claude.id)
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionDescriptor.self, from: JSONEncoder().encode(codex)), codex)
        XCTAssertEqual(try catalog.loadSessions().sessions.count, 2)
    }

    /// Creates an inert conversation descriptor for provider-boundary tests.
    ///
    /// Args:
    ///   application: Source application identity.
    ///   capability: Whether a public exact-session navigation request exists.
    ///
    /// Returns:
    ///   Descriptor containing only synthetic metadata.
    private func descriptor(application: AgentDesktopApplication, capability: AgentSessionOpenCapability) -> AgentSessionDescriptor {
        AgentSessionDescriptor(
            sessionID: "session_1", application: application, title: "Synthetic", workspacePath: nil,
            updatedAt: 100, matchTexts: ["Synthetic"], openCapability: capability
        )
    }

    /// Writes a synthetic SQLite state database inside the isolated fixture root.
    ///
    /// Args:
    ///   sql: Fixture schema and synthetic metadata.
    ///   name: Versioned database filename.
    ///
    /// Raises:
    ///   NSError: SQLite fixture creation failed.
    private func writeDatabase(_ sql: String, name: String = "state_5.sqlite") throws {
        var database: OpaquePointer?
        guard sqlite3_open(rootURL.appendingPathComponent(name).path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "AgentCatalogFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "AgentCatalogFixture", code: 2)
        }
    }

    /// Writes title-only JSONL records without touching any real session index.
    ///
    /// Args:
    ///   records: Synthetic identity, title and timestamp dictionaries.
    ///
    /// Raises:
    ///   Error: JSON serialization or fixture writing failed.
    private func writeIndex(_ records: [[String: String]]) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        try data.write(to: rootURL.appendingPathComponent("session_index.jsonl"))
    }
}
