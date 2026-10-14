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

    /// Idle baselines and workers returning to idle do not leave roster entries behind.
    func testIdleWithoutRequestsNeverRemainsInInbox() {
        let store = immediateStore()
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .running, pendingRequests: []))
        XCTAssertEqual(store.items.count, 1)
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .running, pendingRequests: []))
        XCTAssertEqual(store.items.count, 1)
    }

    /// Runtime idle cannot erase or relabel an unread, independently verified completion.
    func testIdlePreservesCompletedNotificationUntilItIsRead() {
        let store = immediateStore()
        store.apply(.init(session: session(), status: .completed, completionID: "turn"))
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertEqual(store.items.first?.status, .completed)
        XCTAssertEqual(store.items.first?.isUnread, true)
        store.markRead(session().id)
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertTrue(store.items.isEmpty)
    }

    /// Pending requests take priority over idle, and clear only after authoritative resolution.
    func testIdleDoesNotRemoveUnansweredRequests() {
        let store = immediateStore()
        let request = AgentInboxRequest(id: "approval", kind: .approval, text: "Approve?")
        store.apply(.init(session: session(), status: .idle, pendingRequests: [request]))
        XCTAssertEqual(store.items.first?.status, .waiting)
        XCTAssertEqual(store.items.first?.pendingRequests, [request])
        store.apply(.init(session: session(), status: .idle))
        XCTAssertEqual(store.items.first?.pendingRequests, [request])
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        XCTAssertTrue(store.items.isEmpty)
    }

    /// A completed turn containing a question is not a completion notification to preserve.
    func testResolvedQuestionDoesNotSurviveAnIdleOrUnknownUpdate() {
        for status in [AgentInboxStatus.idle, .unknown] {
            let store = immediateStore()
            let request = AgentInboxRequest(id: "question", kind: .input, text: "Choose one")
            store.apply(.init(session: session(), status: .completed, pendingRequests: [request],
                              completionID: "question-turn"))
            store.apply(.init(session: session(), status: status, pendingRequests: []))
            XCTAssertFalse(store.items.contains { !$0.pendingRequests.isEmpty })
            if status == .idle { XCTAssertTrue(store.items.isEmpty) }
        }
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

    /// Keeps newer attention ahead of active work, regardless of the worker's recent state.
    func testAttentionSortsAheadOfWorkersAndReadHistory() {
        let store = immediateStore()
        let question = AgentInboxRequest(id: "question", kind: .input, text: "Which option?")
        let approval = AgentInboxRequest(id: "approval", kind: .approval, text: "Approve?")
        store.apply(.init(session: session(id: "question"), status: .waiting, pendingRequests: [question],
                          observedAt: Date(timeIntervalSince1970: 100)))
        store.markRead(session(id: "question").id)
        store.apply(.init(session: session(id: "approval"), status: .running, pendingRequests: [approval],
                          nativeHasUnreadTurn: false, observedAt: Date(timeIntervalSince1970: 110)))
        for (id, status, time): (String, AgentInboxStatus, TimeInterval) in [
            ("failed", .failed, 120), ("interrupted", .interrupted, 130)
        ] {
            store.apply(.init(session: session(id: id), status: .running,
                              observedAt: Date(timeIntervalSince1970: time - 1)))
            store.apply(.init(session: session(id: id), status: status,
                              observedAt: Date(timeIntervalSince1970: time)))
        }
        for (id, time): (String, TimeInterval) in [("idle", 140), ("unknown", 150), ("completed", 160), ("read", 170)] {
            store.apply(.init(session: session(id: id), status: .completed, completionID: "turn",
                              observedAt: Date(timeIntervalSince1970: time)))
        }
        store.apply(.init(session: session(id: "idle"), status: .idle,
                          observedAt: Date(timeIntervalSince1970: 180)))
        store.apply(.init(session: session(id: "unknown"), status: .unknown,
                          observedAt: Date(timeIntervalSince1970: 190)))
        store.markRead(session(id: "read").id)
        store.apply(.init(session: session(id: "worker"), status: .running,
                          observedAt: Date(timeIntervalSince1970: 300)))
        store.apply(.init(session: session(id: "waiting"), status: .waiting,
                          observedAt: Date(timeIntervalSince1970: 400)))

        XCTAssertEqual(store.items.map(\.session.sessionID), [
            "completed", "unknown", "idle", "interrupted", "failed", "approval", "question", "waiting", "worker", "read"
        ])
        XCTAssertTrue(store.items.prefix(7).allSatisfy(\.needsAttention))
        XCTAssertTrue(store.items.suffix(3).allSatisfy { !$0.needsAttention })
    }

    /// Preserves a completion's attention time across idle, disconnect, and reconnect baselines.
    func testUnreadCompletionDoesNotJumpAboveNewWorkAfterReconnect() {
        let store = immediateStore()
        let older = session(id: "older")
        let newer = session(id: "newer")
        let start = Date(timeIntervalSince1970: 100)
        store.apply(.init(session: older, status: .completed, completionID: "old-turn", observedAt: start))
        store.apply(.init(session: newer, status: .completed, completionID: "newer-turn",
                          observedAt: start.addingTimeInterval(1)))
        for (index, status) in [AgentInboxStatus.unknown, .idle, .completed, .idle, .unknown, .completed].enumerated() {
            store.apply(.init(session: older, status: status, preview: "Retained answer",
                              completionID: status == .completed ? "old-turn" : nil,
                              observedAt: start.addingTimeInterval(Double(index + 2))))
            XCTAssertEqual(store.items.map(\.id), [newer.id, older.id])
            XCTAssertEqual(store.items.last?.updatedAt, start)
        }
        store.apply(.init(session: older, status: .completed, completionID: "genuinely-new-turn",
                          observedAt: start.addingTimeInterval(10)))
        XCTAssertEqual(store.items.first?.id, older.id)
        XCTAssertEqual(store.items.first?.updatedAt, start.addingTimeInterval(10))

        store.apply(.init(session: newer, status: .failed, observedAt: start.addingTimeInterval(11)))
        XCTAssertEqual(store.items.first?.id, newer.id)
        XCTAssertEqual(store.items.first?.updatedAt, start.addingTimeInterval(11))
        store.apply(.init(session: older, status: .interrupted, observedAt: start.addingTimeInterval(12)))
        XCTAssertEqual(store.items.first?.id, older.id)
        XCTAssertEqual(store.items.first?.updatedAt, start.addingTimeInterval(12))
    }

    /// Leaves an old unanswered request in place when its owner streams or reconnects.
    func testPendingRequestRetainsAttentionTimeUntilANewRequestArrives() {
        let store = immediateStore()
        let first = session(id: "old-question")
        let second = session(id: "new-question")
        let oldQuestion = AgentInboxRequest(id: "question", kind: .input, text: "Which option?")
        let approval = AgentInboxRequest(id: "approval", kind: .approval, text: "Approve?")
        let start = Date(timeIntervalSince1970: 100)
        store.apply(.init(session: first, status: .waiting, pendingRequests: [oldQuestion, approval], observedAt: start))
        store.apply(.init(session: second, status: .waiting, pendingRequests: [oldQuestion],
                          observedAt: start.addingTimeInterval(1)))
        let changedQuestion = AgentInboxRequest(id: "question", kind: .input, text: "Expanded details")
        store.apply(.init(session: first, status: .running, pendingRequests: [approval, changedQuestion],
                          preview: "Partial response", observedAt: start.addingTimeInterval(2)))
        store.apply(.init(session: first, status: .unknown, pendingRequests: [changedQuestion],
                          preview: "More text", observedAt: start.addingTimeInterval(3)))
        store.markRead(first.id)
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.items.last?.updatedAt, start)
        XCTAssertTrue(store.items.last?.needsAttention == true)

        let newQuestion = AgentInboxRequest(id: "next-question", kind: .input, text: "And then?")
        store.apply(.init(session: first, status: .waiting, pendingRequests: [changedQuestion, newQuestion],
                          observedAt: start.addingTimeInterval(4)))
        XCTAssertEqual(store.items.first?.id, first.id)
        XCTAssertEqual(store.items.first?.updatedAt, start.addingTimeInterval(4))

        store.apply(.init(session: first, status: .running, pendingRequests: [],
                          observedAt: start.addingTimeInterval(5)))
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.items.last?.updatedAt, start.addingTimeInterval(5))
        XCTAssertFalse(store.items.last?.needsAttention ?? true)
    }

    /// Updates visible streamed text without making it newer than another worker's state.
    func testStreamingPreviewDoesNotRefreshOrderingTime() {
        let store = immediateStore()
        let first = session(id: "first")
        let second = session(id: "second")
        let start = Date(timeIntervalSince1970: 100)
        store.apply(.init(session: first, status: .running, preview: "Beginning", observedAt: start))
        store.apply(.init(session: second, status: .running, observedAt: start.addingTimeInterval(1)))
        store.apply(.init(session: first, status: .running, preview: "Expanded output",
                          observedAt: start.addingTimeInterval(2)))
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.items.last?.preview, "Expanded output")
        XCTAssertEqual(store.items.last?.updatedAt, start)
        store.apply(.init(session: first, status: .waiting, observedAt: start.addingTimeInterval(3)))
        XCTAssertEqual(store.items.first?.id, first.id)
        XCTAssertEqual(store.items.first?.updatedAt, start.addingTimeInterval(3))
    }

    /// Resolves ties by native identity and immediately reorders a completed row when read.
    func testStableIdentityTieBreakAndReadReordering() {
        let store = immediateStore()
        let start = Date(timeIntervalSince1970: 100)
        for id in ["zeta", "alpha"] {
            store.apply(.init(session: session(id: id), status: .completed, completionID: "turn", observedAt: start))
        }
        store.apply(.init(session: session(id: "worker"), status: .running, observedAt: start.addingTimeInterval(1)))
        XCTAssertEqual(store.items.map(\.session.sessionID), ["alpha", "zeta", "worker"])
        store.markRead(session(id: "alpha").id)
        XCTAssertEqual(store.items.map(\.session.sessionID), ["zeta", "worker", "alpha"])
    }

    /// Applies the retention bound after grouping so active work cannot evict an old request.
    func testRetentionKeepsOutstandingAttentionBeforeNewerWorkers() {
        var configuration = AgentNotificationConfiguration()
        configuration.maximumInboxItems = 2
        let store = AgentInboxStore(configuration: configuration)
        let question = AgentInboxRequest(id: "question", kind: .input, text: "Which option?")
        store.apply(.init(session: session(id: "question"), status: .waiting, pendingRequests: [question],
                          observedAt: Date(timeIntervalSince1970: 100)))
        store.apply(.init(session: session(id: "worker-1"), status: .running,
                          observedAt: Date(timeIntervalSince1970: 200)))
        store.apply(.init(session: session(id: "worker-2"), status: .running,
                          observedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(store.items.map(\.session.sessionID), ["question", "worker-2"])
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

    /// A new app lifetime has no old messages, but immediately accepts live work and requests.
    func testNewInboxStartsEmptyAndAcceptsCurrentActivity() {
        let previous = immediateStore()
        previous.apply(.init(session: session(), status: .completed, completionID: "old-turn"))
        previous.dismiss(session().id)
        let store = immediateStore()
        XCTAssertTrue(store.items.isEmpty)
        var popups = 0
        store.onCompletion = { _ in popups += 1 }
        store.apply(.init(session: session(), status: .completed, preview: "Historical answer"))
        store.apply(.init(session: session(id: "idle"), status: .idle))
        XCTAssertTrue(store.items.isEmpty)
        store.apply(.init(session: session(), status: .running))
        let request = AgentInboxRequest(id: "current-question", kind: .input, text: "Choose one")
        store.apply(.init(session: session(.claudeCode), status: .waiting, pendingRequests: [request]))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(popups, 0)
        store.apply(.init(session: session(), status: .completed, completionID: "new-turn"))
        XCTAssertEqual(popups, 1)
    }

    /// Opening a result consumes only that row and quiet refreshes cannot bring it back.
    func testOpeningCompletionRemovesItUntilNewWorkArrives() throws {
        let store = immediateStore()
        let other = session(.claudeCode)
        store.apply(.init(session: other, status: .running))
        store.apply(.init(session: session(), status: .completed, completionID: "turn"))
        let selected = try XCTUnwrap(store.items.first(where: { $0.id == session().id }))
        store.acknowledgeOpened(selected)
        XCTAssertEqual(store.items.map(\.id), [other.id])
        store.apply(.init(session: session(), status: .idle, pendingRequests: []))
        store.apply(.init(session: session(), status: .completed, preview: "Refreshed old answer"))
        store.apply(.init(session: session(), status: .completed, completionID: "turn"))
        XCTAssertEqual(store.items.map(\.id), [other.id])
        store.apply(.init(session: session(), status: .running))
        XCTAssertEqual(store.items.count, 2)
    }

    /// Opening current work does not resolve a question or an approval on the user's behalf.
    func testOpeningKeepsActiveWorkAndOutstandingRequests() throws {
        for status in [AgentInboxStatus.running, .waiting, .completed, .idle] {
            let store = immediateStore()
            let requests: [AgentInboxRequest] = status == .running ? [] : [
                .init(id: "approval", kind: .approval, text: "Approve?")
            ]
            store.apply(.init(session: session(), status: status, pendingRequests: requests))
            let selected = try XCTUnwrap(store.items.first)
            store.acknowledgeOpened(selected)
            XCTAssertEqual(store.items.count, 1)
            XCTAssertEqual(store.items.first?.pendingRequests, requests)
            XCTAssertEqual(store.items.first?.isUnread, false)
        }
    }

    /// A later update during native navigation cannot be consumed by the earlier click.
    func testOpeningOldSnapshotPreservesNewerWork() throws {
        let store = immediateStore()
        store.apply(.init(session: session(), status: .completed, completionID: "first"))
        let selected = try XCTUnwrap(store.items.first)
        store.apply(.init(session: session(), status: .completed, completionID: "second"))
        let newer = store.items.first
        store.acknowledgeOpened(selected)
        XCTAssertEqual(store.items.first, newer)
        XCTAssertEqual(store.items.first?.isUnread, true)
    }

    /// In-memory rows retain only the metadata needed to navigate and display a bounded preview.
    func testInMemoryRowsDoNotKeepSearchContextOrTranscriptPaths() throws {
        let store = immediateStore()
        store.apply(.init(session: session(), status: .running))
        let item = try XCTUnwrap(store.items.first)
        XCTAssertNil(item.session.workspacePath)
        XCTAssertNil(item.session.transcriptPath)
        XCTAssertTrue(item.session.matchTexts.isEmpty)
    }

    /// Verifies default safety bounds are valid and invalid loops are rejected.
    func testConfigurationBounds() throws {
        var configuration = AgentNotificationConfiguration()
        try configuration.validate()
        configuration.claudeReconcileIntervalSeconds = 0
        XCTAssertThrowsError(try configuration.validate())
    }
}
