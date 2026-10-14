import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffUITests: XCTestCase {
    /// Verifies persistent window copy follows language changes without translating source text.
    ///
    /// Returns:
    ///   Nothing. Checks every label and the same snapshot in both interface languages.
    func testCopyFollowsLanguageChanges() {
        let history = history(source: session(number: 1))
        for language in [AppLanguage.zh, .en, .zh] {
            for label in AgentHandoffCopy.Label.allCases {
                XCTAssertFalse(AgentHandoffCopy.text(label, language: language).isEmpty)
            }
            XCTAssertTrue(AgentHandoffCopy.snapshot(history, language: language).contains("2"))
            XCTAssertEqual(AgentHandoffCopy.text(.send, language: language),
                           language == .zh ? "确认交接" : "Confirm handoff")
            XCTAssertEqual(history.source.title, "MyType 体验包")
            XCTAssertEqual(history.markdown, "用户：保留原始中文\n助手：下一步继续")
        }
    }

    /// Verifies provider failures are rendered from stored semantics after a language change.
    ///
    /// Returns:
    ///   Nothing. Checks that a single error changes its user-facing language.
    func testStoredDeliveryFailureIsLocalizedAtRenderTime() {
        let failure = AgentHandoffUIFailure(label: .deliveryFailed,
                                           underlying: AgentHandoffDeliveryError.claudeSessionUnavailable)
        XCTAssertEqual(failure.message(language: .zh),
                       "Claude 接收会话尚未运行。请打开该会话，再重新发送。")
        XCTAssertEqual(failure.message(language: .en),
                       "The receiving Claude chat is not running. Open that chat before sending again.")
    }

    /// Verifies equal titles retain distinct native identities and original ordering.
    ///
    /// Returns:
    ///   Nothing. Checks the display filter never deduplicates titles or providers.
    func testTitleFilteringPreservesDistinctSessions() {
        let first = session(number: 1)
        let second = session(number: 2, application: .claudeCode)
        let third = session(number: 3, title: "另一件事")
        XCTAssertEqual(AgentHandoffViewModel.filtered([first, second, third], query: " mytype ").map(\.id),
                       [first.id, second.id])
        XCTAssertEqual(AgentHandoffViewModel.filtered([first, second, third], query: "").map(\.id),
                       [first.id, second.id, third.id])
    }

    /// Verifies selection changes invalidate a late history response from the previous source.
    ///
    /// Returns:
    ///   Nothing. Checks that stale history cannot become the payload of a later send.
    @MainActor
    func testChangingSourceDiscardsLateHistoryResponse() async {
        let first = session(number: 1)
        let second = session(number: 2)
        let gate = HandoffHistoryGate()
        let secondSnapshot = history(source: second)
        let discards = HandoffDiscardRecords()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [first, second], unavailableApplications: []) },
            historyLoader: { source in source.id == first.id ? await gate.load() : secondSnapshot },
            discarder: { await discards.discard($0) }
        )
        await model.refreshSessions()
        model.selectSource(first.id)
        let load = Task { await model.loadHistory() }
        await gate.waitUntilRequested()
        model.selectSource(second.id)
        await gate.resolve(history(source: first))
        await load.value
        await model.loadHistory()
        XCTAssertEqual(model.sourceID, second.id)
        XCTAssertEqual(model.history?.source.id, second.id)
        XCTAssertEqual(model.operation, .idle)
        XCTAssertFalse(model.canSend)
        let discardedSources = await discards.sourceIDs
        XCTAssertEqual(discardedSources, [first.id])
    }

    /// Verifies sending needs a distinct receiver, loaded history, and a nonempty next task.
    ///
    /// Returns:
    ///   Nothing. Checks invalid selections never call the native transport.
    @MainActor
    func testSendGateRequiresExplicitCompleteSelections() async {
        let first = session(number: 1)
        let second = session(number: 2)
        let snapshot = history(source: first)
        let records = HandoffSendRecords()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [first, second], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { history, target, instruction in await records.send(history, target: target, instruction: instruction) },
            discarder: { _ in }
        )
        await model.refreshSessions()
        model.selectSource(first.id)
        model.selectTarget(second.id)
        model.instruction = "继续打包"
        XCTAssertFalse(model.canSend)
        await model.send()
        await model.loadHistory()
        model.selectTarget(first.id)
        XCTAssertFalse(model.canSend)
        await model.send()
        model.selectTarget(second.id)
        model.instruction = " \n "
        XCTAssertFalse(model.canSend)
        await model.send()
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    /// Verifies accepted delivery cannot be repeated by double-clicking or switching language.
    ///
    /// Returns:
    ///   Nothing. Checks a changed task can be sent while the identical task stays blocked.
    @MainActor
    func testAcceptedRequestCannotBeSentTwiceUnchanged() async {
        let first = session(number: 1)
        let second = session(number: 2)
        let snapshot = history(source: first)
        let records = HandoffSendRecords()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [first, second], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { history, target, instruction in await records.send(history, target: target, instruction: instruction) },
            discarder: { _ in }
        )
        await model.refreshSessions()
        model.selectSource(first.id)
        model.selectTarget(second.id)
        model.instruction = "继续打包"
        await model.loadHistory()
        XCTAssertTrue(model.canSend)
        await model.send()
        XCTAssertNotNil(model.receipt)
        XCTAssertFalse(model.canSend)
        await model.send()
        model.instruction = "继续打包 "
        XCTAssertFalse(model.canSend)
        model.instruction = "检查打包结果"
        XCTAssertNil(model.receipt)
        XCTAssertTrue(model.canSend)
        let count = await records.count
        XCTAssertEqual(count, 1)
    }

    /// Verifies selecting the same receiver again preserves its accepted delivery evidence.
    ///
    /// Returns:
    ///   Nothing. The receipt remains visible and unchanged delivery remains blocked.
    @MainActor
    func testReselectingReceiverKeepsAcceptedReceipt() async {
        let source = session(number: 1)
        let target = session(number: 2)
        let snapshot = history(source: source)
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { _, target, _ in
                AgentHandoffDeliveryReceipt(route: .codexQueue, messageID: "accepted-fixture", target: target,
                                            usesHistoryFile: true)
            },
            discarder: { _ in }
        )
        await model.refreshSessions()
        model.selectSource(source.id)
        model.selectTarget(target.id)
        model.instruction = "继续工作"
        await model.loadHistory()
        await model.send()
        model.selectTarget(target.id)
        XCTAssertEqual(model.receipt?.messageID, "accepted-fixture")
        XCTAssertFalse(model.canSend)
    }

    /// Verifies abandoned previews are reclaimed after changing the source or closing the window.
    ///
    /// Returns:
    ///   Nothing. Checks that cleanup receives only the two never-submitted fixture snapshots.
    @MainActor
    func testUnusedPreviewsAreReclaimedOnSelectionChangeAndWindowClose() async {
        let first = session(number: 1)
        let second = session(number: 2)
        let snapshots = [first.id: history(source: first), second.id: history(source: second)]
        let discards = HandoffDiscardRecords()
        let discarded = expectation(description: "Both unused previews reclaimed")
        discarded.expectedFulfillmentCount = 2
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [first, second], unavailableApplications: []) },
            historyLoader: { snapshots[$0.id]! },
            discarder: { await discards.discard($0); discarded.fulfill() }
        )
        await model.refreshSessions()
        model.selectSource(first.id)
        await model.loadHistory()
        model.selectSource(second.id)
        await model.loadHistory()
        model.clearUnsentPreview()
        XCTAssertNil(model.history)
        await fulfillment(of: [discarded], timeout: 1)
        let discardedSources = await discards.sourceIDs
        XCTAssertEqual(Set(discardedSources), Set([first.id, second.id]))
    }

    /// Verifies both accepted and uncertain delivery attempts retain their history files.
    ///
    /// Returns:
    ///   Nothing. Checks that source changes and window closing do not reclaim submitted data.
    @MainActor
    func testSubmittedSnapshotsSurviveAcceptedAndUncertainDelivery() async {
        let first = session(number: 1)
        let second = session(number: 2)
        let snapshot = history(source: first)
        let nextSnapshot = history(source: second)
        let snapshots = [first.id: snapshot, second.id: nextSnapshot]
        for accepted in [true, false] {
            let reclaimed = expectation(description: "Submitted snapshot must be preserved")
            reclaimed.isInverted = true
            let unusedReclaimed = expectation(description: "New unused preview is reclaimed")
            let model = AgentHandoffViewModel(
                catalogLoader: { AgentSessionCatalogSnapshot(sessions: [first, second], unavailableApplications: []) },
                historyLoader: { snapshots[$0.id]! },
                sender: { _, target, _ in
                    guard accepted else { throw AgentHandoffDeliveryError.deliveryUncertain }
                    return AgentHandoffDeliveryReceipt(route: .codexQueue, messageID: UUID().uuidString,
                                                       target: target, usesHistoryFile: true)
                },
                discarder: {
                    if $0.fileURL == snapshot.fileURL { reclaimed.fulfill() }
                    if $0.fileURL == nextSnapshot.fileURL { unusedReclaimed.fulfill() }
                }
            )
            await model.refreshSessions()
            model.selectSource(first.id)
            model.selectTarget(second.id)
            model.instruction = "继续打包"
            await model.loadHistory()
            await model.send()
            model.clearUnsentPreview()
            model.selectSource(second.id)
            await model.loadHistory()
            XCTAssertEqual(model.history?.source.id, second.id)
            model.clearUnsentPreview()
            XCTAssertNil(model.history)
            await fulfillment(of: [unusedReclaimed, reclaimed], timeout: 0.1)
        }
    }

    /// Creates a native metadata fixture with no dependency on installed agent apps.
    ///
    /// Args:
    ///   number: Distinct identifier suffix.
    ///   application: Provider whose identity should be preserved.
    ///   title: User-facing title, including intentionally identical names.
    ///
    /// Returns:
    ///   A synthetic native conversation descriptor.
    private func session(number: Int, application: AgentDesktopApplication = .codex,
                         title: String = "MyType 体验包") -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: String(format: "00000000-0000-4000-8000-%012d", number),
                               application: application, title: title, workspacePath: nil,
                               updatedAt: 100, matchTexts: [title],
                               openCapability: application == .codex ? .codexDeepLink : .claudeNativeDeepLink)
    }

    /// Creates an in-memory history fixture without writing or reading user conversations.
    ///
    /// Args:
    ///   source: Exact fixture conversation associated with the snapshot.
    ///
    /// Returns:
    ///   A complete synthetic visible dialogue snapshot.
    private func history(source: AgentSessionDescriptor) -> AgentHandoffHistory {
        AgentHandoffHistory(source: source, markdown: "用户：保留原始中文\n助手：下一步继续", messageCount: 2,
                            snapshotDate: Date(timeIntervalSince1970: 1_000),
                            fileURL: URL(fileURLWithPath: "/synthetic-fixture/\(source.sessionID)/history.md"))
    }
}

private actor HandoffHistoryGate {
    private var pending: CheckedContinuation<AgentHandoffHistory, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    /// Holds a history result until the fixture changes the source selection.
    ///
    /// Returns:
    ///   The history explicitly supplied by the fixture.
    func load() async -> AgentHandoffHistory {
        await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    /// Waits deterministically until history loading has started.
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    /// Releases exactly one pending synthetic history request.
    ///
    /// Args:
    ///   history: Snapshot to return after the source changed.
    func resolve(_ history: AgentHandoffHistory) {
        pending?.resume(returning: history)
        pending = nil
    }
}

private actor HandoffSendRecords {
    private(set) var count = 0

    /// Records an accepted request without contacting either agent app.
    ///
    /// Args:
    ///   history: Reviewed fixture history.
    ///   target: Selected receiving fixture conversation.
    ///   instruction: Explicit next task.
    ///
    /// Returns:
    ///   A synthetic accepted queue receipt.
    func send(_ history: AgentHandoffHistory, target: AgentSessionDescriptor,
              instruction: String) -> AgentHandoffDeliveryReceipt {
        count += 1
        return AgentHandoffDeliveryReceipt(route: .codexQueue, messageID: UUID().uuidString,
                                           target: target, usesHistoryFile: true)
    }
}

private actor HandoffDiscardRecords {
    private(set) var sourceIDs: [String] = []

    /// Records unused snapshot cleanup without accessing the user's application storage.
    ///
    /// Args:
    ///   history: Synthetic snapshot passed to the cleanup callback.
    func discard(_ history: AgentHandoffHistory) {
        sourceIDs.append(history.source.id)
    }
}
