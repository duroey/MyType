import Foundation
import XCTest
@testable import Type4Me

final class AgentActivityStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AgentActivityStore!

    /// Creates an isolated activity index without touching the real profile.
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = AgentActivityStore(fileURL: directory.appendingPathComponent("activities.json"))
    }

    /// Removes this test's disposable activity index.
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Verifies equal titles in different apps remain independent activities.
    func testSameTitleDoesNotMergeApplications() async throws {
        let snapshot = try await store.reconcile(sessions: [session("a", .codex), session("a", .claudeCode)])
        XCTAssertEqual(snapshot.activities.count, 2)
        XCTAssertEqual(Set(snapshot.activities.flatMap(\.sessionKeys)), ["codex:a", "claudeCode:a"])
    }

    /// Verifies renaming a native title cannot change persistent activity identity.
    func testIdentitySurvivesTitleChangeAndReload() async throws {
        let first = try await store.reconcile(sessions: [session("a", .codex)])
        let reloaded = AgentActivityStore(fileURL: directory.appendingPathComponent("activities.json"))
        let second = try await reloaded.reconcile(sessions: [session("a", .codex, title: "New title")])
        XCTAssertEqual(first.activities.first?.id, second.activities.first?.id)
    }

    /// Verifies a user's activity name is separate from the application's title.
    func testCustomNameAndPriorAliasArePreserved() async throws {
        let snapshot = try await store.reconcile(sessions: [session("a", .codex)])
        let id = try XCTUnwrap(snapshot.activities.first?.id)
        try await store.rename(activityID: id, title: "登录实现")
        try await store.rename(activityID: id, title: "登录修复")
        let renamed = try await store.readSnapshot()
        XCTAssertEqual(renamed.activities.first?.customTitle, "登录修复")
        XCTAssertEqual(renamed.activities.first?.aliases, ["登录实现"])
    }

    /// Verifies explicit association groups sessions without losing stable identity.
    func testExplicitLinkMovesSessionAndLastTargetTogether() async throws {
        let snapshot = try await store.reconcile(sessions: [session("a", .codex), session("b", .codex)])
        let a = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys == ["codex:a"] })
        let b = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys == ["codex:b"] })
        try await store.markOpened(activityID: b.id, sessionKey: "codex:b")
        try await store.link(sessionKey: "codex:b", to: a.id)
        let linked = try await store.readSnapshot()
        XCTAssertEqual(linked.lastActivityID, a.id)
        XCTAssertEqual(linked.lastSessionKey, "codex:b")
        XCTAssertEqual(linked.activities.first { $0.id == a.id }?.sessionKeys, ["codex:a", "codex:b"])
    }

    /// Verifies a confirmed spoken name and its continuation target survive one reload.
    ///
    /// Raises:
    ///   Error: Synthetic association persistence or reload failed.
    func testExplicitQueryAliasPersistsWithOpenedTarget() async throws {
        let nativeSession = session("a", .codex, title: "MyType Desktop Agent Routing")
        let snapshot = try await store.reconcile(sessions: [nativeSession])
        let activityID = try XCTUnwrap(snapshot.activities.first?.id)

        try await store.markOpened(
            activityID: activityID, sessionKey: nativeSession.id, queryAlias: "  MyType 体验包\n"
        )
        let remembered = try await store.readSnapshot()
        let activity = try XCTUnwrap(remembered.activities.first)
        let reloaded = AgentActivityStore(fileURL: directory.appendingPathComponent("activities.json"))
        let persisted = try await reloaded.readSnapshot()

        XCTAssertEqual(activity.aliases, ["MyType 体验包"])
        XCTAssertNil(activity.customTitle)
        XCTAssertEqual(activity.sessionKeys, [nativeSession.id])
        XCTAssertEqual(activity.preferredSessionKey, nativeSession.id)
        XCTAssertEqual(remembered.lastActivityID, activityID)
        XCTAssertEqual(remembered.lastSessionKey, nativeSession.id)
        XCTAssertEqual(persisted, remembered)
    }

    /// Verifies repeated choices deduplicate names while retaining the recent alias bound.
    ///
    /// Raises:
    ///   Error: Synthetic association updates failed.
    func testQueryAliasesAreDeduplicatedAndBounded() async throws {
        var configuration = AgentActivityStore.Configuration()
        configuration.maximumAliases = 3
        let boundedStore = AgentActivityStore(
            fileURL: directory.appendingPathComponent("bounded-activities.json"), configuration: configuration
        )
        let snapshot = try await boundedStore.reconcile(sessions: [session("a", .codex)])
        let activityID = try XCTUnwrap(snapshot.activities.first?.id)
        let names = (0...configuration.maximumAliases).map { "Alias \($0)" }
        for name in names {
            try await boundedStore.markOpened(activityID: activityID, sessionKey: "codex:a", queryAlias: name)
        }
        let bounded = try await boundedStore.readSnapshot()
        XCTAssertEqual(bounded.activities.first?.aliases, Array(names.suffix(configuration.maximumAliases)))

        let repeated = names[1]
        try await boundedStore.markOpened(activityID: activityID, sessionKey: "codex:a", queryAlias: repeated)
        let deduplicated = try await boundedStore.readSnapshot()
        let aliases = try XCTUnwrap(deduplicated.activities.first?.aliases)

        XCTAssertEqual(aliases, Array(names.suffix(configuration.maximumAliases)).filter { $0 != repeated } + [repeated])
        XCTAssertEqual(aliases.count, configuration.maximumAliases)
        XCTAssertEqual(Set(aliases).count, aliases.count)
    }

    /// Verifies invalid or redundant query names do not prevent recording a valid target.
    ///
    /// Raises:
    ///   Error: Synthetic association updates failed.
    func testInvalidAndCustomTitleEquivalentQueryAliasesAreNotStored() async throws {
        let configuration = AgentActivityStore.Configuration()
        let snapshot = try await store.reconcile(sessions: [session("a", .codex)])
        let activityID = try XCTUnwrap(snapshot.activities.first?.id)
        let customTitle = "MyType 体验"
        try await store.rename(activityID: activityID, title: customTitle)
        let ignoredNames: [String?] = [
            nil, "", " \n", String(repeating: "a", count: configuration.maximumTitleCharacters + 1), customTitle
        ]
        for name in ignoredNames {
            try await store.markOpened(activityID: activityID, sessionKey: "codex:a", queryAlias: name)
        }
        let remembered = try await store.readSnapshot()

        XCTAssertEqual(remembered.activities.first?.aliases, [])
        XCTAssertEqual(remembered.activities.first?.customTitle, customTitle)
        XCTAssertEqual(remembered.activities.first?.preferredSessionKey, "codex:a")
        XCTAssertEqual(remembered.lastActivityID, activityID)
        XCTAssertEqual(remembered.lastSessionKey, "codex:a")
    }

    /// Verifies the default index can hold both providers' full bounded catalogs.
    ///
    /// Raises:
    ///   Error: Reconciliation of synthetic catalog capacity failed.
    func testDefaultStoreAcceptsFullProviderCatalogCapacity() async throws {
        let codexCapacity = CodexMetadataSessionCatalog.Configuration().maximumSessions
        let claudeCapacity = ClaudeCodeSessionCatalog.Configuration().maximumSessions
        let sessions = (0..<codexCapacity).map { session("codex_\($0)", .codex) }
            + (0..<claudeCapacity).map { session("claude_\($0)", .claudeCode) }

        let snapshot = try await store.reconcile(sessions: sessions)

        XCTAssertEqual(snapshot.activities.count, sessions.count)
        XCTAssertEqual(Set(snapshot.activities.flatMap(\.sessionKeys)), Set(sessions.map(\.id)))
    }

    /// Verifies a malformed index is reported and preserved instead of overwritten.
    func testCorruptStoreIsNotReplacedByReconciliation() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("activities.json")
        let badData = Data("not-json".utf8)
        try badData.write(to: file)
        do {
            _ = try await store.reconcile(sessions: [session("a", .codex)])
            XCTFail("Expected corrupt index failure")
        } catch { XCTAssertEqual(error as? AgentActivityStoreError, .invalidStore) }
        XCTAssertEqual(try Data(contentsOf: file), badData)
    }

    /// Verifies stale ownership cannot silently update the current continuation target.
    func testOpenedTargetMustStillBelongToActivity() async throws {
        let snapshot = try await store.reconcile(sessions: [session("a", .codex), session("b", .codex)])
        let a = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys == ["codex:a"] })
        let b = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys == ["codex:b"] })
        try await store.link(sessionKey: "codex:b", to: a.id)
        let beforeRejectedChoice = try await store.readSnapshot()
        do {
            try await store.markOpened(activityID: b.id, sessionKey: "codex:b", queryAlias: "MyType 体验包")
            XCTFail("Expected changed association failure")
        } catch { XCTAssertEqual(error as? AgentActivityStoreError, .unknownSession) }
        let afterRejectedChoice = try await store.readSnapshot()
        XCTAssertEqual(afterRejectedChoice, beforeRejectedChoice)
    }

    /// Builds metadata-only fixtures with no private conversation content.
    private func session(_ id: String, _ application: AgentDesktopApplication, title: String = "Fix login") -> AgentSessionDescriptor {
        AgentSessionDescriptor(
            sessionID: id, application: application, title: title, workspacePath: "/unused/resource",
            updatedAt: 1, matchTexts: [title], openCapability: application == .codex ? .codexDeepLink : .unsupported
        )
    }
}
