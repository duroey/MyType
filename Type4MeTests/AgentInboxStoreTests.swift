import Foundation
import XCTest
@testable import Type4Me

@MainActor
final class AgentInboxStoreTests: XCTestCase {
    /// Keeps preexisting synchronous merge tests independent of delayed presentation.
    ///
    /// Returns:
    ///   Memory-only store with the popup grace period explicitly disabled.
    private func immediateStore() -> AgentInboxStore {
        var configuration = AgentNotificationConfiguration()
        configuration.completionAlertDelaySeconds = 0
        return AgentInboxStore(configuration: configuration)
    }

    /// Builds synthetic metadata without reading the real desktop profile.
    ///
    /// Args:
    ///   application: Original app owning the fixture.
    ///   id: Native conversation identity.
    ///
    /// Returns:
    ///   A descriptor with deliberately private search text to test minimization.
    private func session(_ application: AgentDesktopApplication = .codex, id: String = "fixture") -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: id, application: application, title: "MyType 体验包",
            workspacePath: "/private/work", updatedAt: 1, matchTexts: ["private search context"],
            openCapability: application == .codex ? .codexDeepLink : .claudeNativeDeepLink,
            transcriptPath: "/private/history.jsonl")
    }

    /// Verifies history snapshots and failed/interrupted turns never produce completion popups.
    func testOnlyFreshSuccessfulCompletionPopsOnce() {
        let store = immediateStore()
        var popups = 0
        store.onCompletion = { _ in popups += 1 }
        store.apply(.init(session: session(), status: .completed, preview: "old answer"))
        XCTAssertTrue(store.items.isEmpty)
        for state: AgentInboxStatus in [.running, .waiting, .unknown, .failed, .interrupted] {
            store.apply(.init(session: session(), status: state, completionID: "not-success"))
        }
        XCTAssertEqual(popups, 0)
        store.apply(.init(session: session(), status: .completed, preview: "answer", completionID: "turn-1"))
        store.apply(.init(session: session(), status: .completed, preview: "answer", completionID: "turn-1"))
        XCTAssertEqual(popups, 1)
        XCTAssertTrue(store.items[0].isUnread)
    }

    /// Consumes a native-read completion without suppressing the next turn's notification.
    func testNativeReadConsumesOnlyTheObservedCompletion() {
        let store = immediateStore()
        var popups = 0
        store.onCompletion = { _ in popups += 1 }
        store.apply(.init(session: session(), status: .running))
        store.apply(.init(session: session(), status: .completed, completionID: "seen-turn", nativeHasUnreadTurn: false))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(popups, 0)
        store.apply(.init(session: session(), status: .completed, completionID: "seen-turn"))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .running))
        store.apply(.init(session: session(), status: .completed, completionID: "new-turn"))
        XCTAssertTrue(store.items[0].isUnread)
        XCTAssertEqual(popups, 1)
        store.apply(.init(session: session(), status: .completed, nativeHasUnreadTurn: false))
        XCTAssertTrue(store.items.isEmpty)
    }

    /// Keeps unanswered requests and other providers even after a native read receipt.
    func testNativeReadDoesNotResolveRequestsOrOtherSessions() {
        let store = immediateStore()
        let request = AgentInboxRequest(id: "approval", kind: .approval, text: "Approve?")
        store.apply(.init(session: session(.claudeCode), status: .completed, completionID: "claude-turn"))
        store.apply(.init(session: session(), status: .completed, pendingRequests: [request],
                          completionID: "codex-turn", nativeHasUnreadTurn: false))
        XCTAssertEqual(store.items.count, 2)
        let codex = store.items.first { $0.session.application == .codex }
        XCTAssertEqual(codex?.pendingRequests, [request])
        XCTAssertEqual(codex?.isUnread, false)
        XCTAssertEqual(store.items.first { $0.session.application == .claudeCode }?.isUnread, true)
    }

    /// Verifies waiting requests survive completion, disconnection, and marking the row read.
    func testQuestionsAreIndependentOfRuntimeAndUnreadState() {
        let store = immediateStore()
        var popups = 0
        store.onCompletion = { _ in popups += 1 }
        let question = AgentInboxRequest(id: "question-1", kind: .input, text: "选中文还是英文？")
        store.apply(.init(session: session(), status: .running, pendingRequests: [question]))
        store.apply(.init(session: session(), status: .completed, completionID: "turn-1"))
        store.markRead(session().id)
        store.apply(.init(session: session(), status: .unknown))
        XCTAssertEqual(store.items[0].pendingRequests, [question])
        XCTAssertFalse(store.items[0].isUnread)
        XCTAssertEqual(popups, 0, "Ending a turn with an unanswered question is not completed work")
        store.apply(.init(session: session(), status: .running, pendingRequests: []))
        XCTAssertTrue(store.items[0].pendingRequests.isEmpty)
    }

    /// New questions and approvals alert once; rereads, text updates and removals stay quiet.
    func testNewRequestsAlertWithoutTreatingThemAsCompletion() {
        let store = immediateStore()
        var requests: [AgentInboxItem] = []
        var completions = 0
        store.onRequest = { requests.append($0) }
        store.onCompletion = { _ in completions += 1 }
        let question = AgentInboxRequest(id: "question", kind: .input, text: "Which option?")
        let approval = AgentInboxRequest(id: "approval", kind: .approval, text: "Approve?")
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [question]))
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [question]))
        store.markRead(session().id)
        store.apply(.init(session: session(), status: .completed, pendingRequests: [question], completionID: "turn"))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(store.items.first?.pendingRequests, [question])
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [approval, question]))
        XCTAssertEqual(requests.count, 2)
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [question, approval]))
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [approval]))
        XCTAssertEqual(requests.count, 2)
        let changedText = AgentInboxRequest(id: "approval", kind: .approval, text: "Updated reason")
        store.apply(.init(session: session(), status: .waiting, pendingRequests: [changedText]))
        XCTAssertEqual(requests.count, 2)
    }

    /// Verifies identical provider titles/IDs cannot overwrite another provider's inbox row.
    func testApplicationQualifiedIdentityAndLateUpdateRejection() {
        let store = immediateStore()
        let date = Date()
        store.apply(.init(session: session(), status: .running, observedAt: date))
        store.apply(.init(session: session(.claudeCode), status: .waiting, observedAt: date))
        store.apply(.init(session: session(), status: .failed, observedAt: date.addingTimeInterval(-1)))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first { $0.session.application == .codex }?.status, .running)
    }

    /// Verifies polling heartbeats do not reorder messages or restore a dismissed row.
    func testHeartbeatIsQuietAndDismissalLastsUntilContentChanges() {
        let store = immediateStore()
        let date = Date()
        store.apply(.init(session: session(), status: .running, observedAt: date))
        store.apply(.init(session: session(), status: .running, observedAt: date.addingTimeInterval(2)))
        XCTAssertEqual(store.items[0].updatedAt, date)
        store.dismiss(session().id)
        store.apply(.init(session: session(), status: .running, observedAt: date.addingTimeInterval(3)))
        store.apply(.init(session: session(), status: .unknown, observedAt: date.addingTimeInterval(3.5)))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .waiting, observedAt: date.addingTimeInterval(4)))
        XCTAssertEqual(store.items.count, 1)
    }

    /// Verifies a new turn with identical output receives its own completion time and popup.
    func testIdenticalAnswersFromDifferentTurnsAreNewWork() {
        let store = immediateStore()
        let date = Date()
        var popups = 0
        store.onCompletion = { _ in popups += 1 }
        store.apply(.init(session: session(), status: .completed, preview: "Done", completionID: "one", observedAt: date))
        store.apply(.init(session: session(), status: .completed, preview: "Done", completionID: "two", observedAt: date.addingTimeInterval(5)))
        XCTAssertEqual(popups, 2)
        XCTAssertEqual(store.items.first?.updatedAt, date.addingTimeInterval(5))
    }

    /// Verifies restart deduplication and private storage retain only bounded visible excerpts.
    ///
    /// Raises:
    ///   Error: The isolated temporary snapshot could not be read or removed.
    func testPersistenceIsPrivateAndCompletionDoesNotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inbox.json")
        let store = AgentInboxStore(fileURL: file)
        store.apply(.init(session: session(), status: .completed, preview: "visible answer", completionID: "turn-1"))
        await store.flush()
        XCTAssertFalse(store.storageError)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let encoded = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(encoded.contains("private search context"))
        XCTAssertFalse(encoded.contains("/private/history"))
        let restored = AgentInboxStore(fileURL: file)
        await restored.load()
        XCTAssertEqual(restored.items.first?.status, .unknown)
        var popups = 0
        restored.onCompletion = { _ in popups += 1 }
        restored.apply(.init(session: session(), status: .completed, completionID: "turn-1"))
        XCTAssertEqual(popups, 0)
        await restored.flush()
    }

    /// Verifies future formats are preserved on disk while the inbox remains usable in memory.
    ///
    /// Raises:
    ///   Error: The isolated unsupported file could not be created or checked.
    func testUnsupportedStoreIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inbox.json")
        let original = Data("{\"version\":99,\"items\":[],\"dismissed\":[],\"receipts\":[]}".utf8)
        try original.write(to: file)
        let store = AgentInboxStore(fileURL: file)
        await store.load()
        store.apply(.init(session: session(), status: .running))
        await store.flush()
        XCTAssertTrue(store.storageError)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// Verifies default safety bounds are valid and invalid loops are rejected.
    func testConfigurationBounds() throws {
        var configuration = AgentNotificationConfiguration()
        try configuration.validate()
        configuration.claudeReconcileIntervalSeconds = 0
        XCTAssertThrowsError(try configuration.validate())
    }
}
