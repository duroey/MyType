import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffSuggestionDraftTests: XCTestCase {
    /// Verifies suggested conversations and preview form a draft until one explicit confirmation.
    ///
    /// Returns:
    ///   Nothing. No native transport is called before confirmation or twice for the same request.
    @MainActor
    func testSuggestionsPreparePreviewButOnlyConfirmationSendsCurrentInstruction() async {
        let source = session(1)
        let target = session(2)
        let snapshot = history(source)
        let records = SuggestionSendRecords()
        let suggested = suggestion(source: source, target: target)
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { history, target, instruction in await records.send(history, target: target, instruction: instruction) },
            discarder: { _ in },
            suggester: { _, _ in suggested }
        )
        XCTAssertTrue(model.beginVoiceDraft("把这项工作交给另一个会话"))
        await model.refreshSessions()
        XCTAssertEqual(model.sourceID, source.id)
        XCTAssertEqual(model.targetID, target.id)
        XCTAssertEqual(model.history?.source.id, source.id)
        XCTAssertTrue(model.sourceWasSuggested)
        XCTAssertTrue(model.targetWasSuggested)
        XCTAssertTrue(model.canSend)
        let before = await records.instructions
        XCTAssertTrue(before.isEmpty)
        model.instruction = "先检查上一轮结论，再继续"
        await model.send()
        await model.send()
        let after = await records.instructions
        XCTAssertEqual(after, ["先检查上一轮结论，再继续"])
    }

    /// Verifies late suggestions preserve a manually changed source while filling the other side.
    ///
    /// Returns:
    ///   Nothing. The automatically prepared preview belongs to the manually selected source.
    @MainActor
    func testManualSourceDoesNotPreventReceiverSuggestion() async {
        let source = session(1)
        let target = session(2)
        let manualSource = session(3)
        let catalog = [source, target, manualSource]
        let snapshots = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, history($0)) })
        let gate = SuggestionResultGate()
        let result = suggestion(source: source, target: target)
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: catalog, unavailableApplications: []) },
            historyLoader: { snapshots[$0.id]! },
            discarder: { _ in },
            suggester: { _, _ in await gate.load() }
        )
        model.beginVoiceDraft("把来源的工作交给接收会话")
        let prepare = Task { await model.refreshSessions() }
        await gate.waitUntilRequested()
        model.selectSource(manualSource.id)
        await gate.resolve(result)
        await prepare.value
        await model.loadHistory()
        XCTAssertEqual(model.sourceID, manualSource.id)
        XCTAssertEqual(model.targetID, target.id)
        XCTAssertEqual(model.history?.source.id, manualSource.id)
        XCTAssertFalse(model.sourceWasSuggested)
        XCTAssertTrue(model.targetWasSuggested)
        XCTAssertTrue(model.canSend)
    }

    /// Verifies each manual selection remains authoritative even when both are changed mid-request.
    ///
    /// Returns:
    ///   Nothing. Suggestions remain available as alternatives without replacing user choices.
    @MainActor
    func testBothManualSelectionsSurviveLateSuggestion() async {
        let catalog = (1...4).map { session($0) }
        let snapshots = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, history($0)) })
        let result = suggestion(source: catalog[0], target: catalog[1])
        let gate = SuggestionResultGate()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: catalog, unavailableApplications: []) },
            historyLoader: { snapshots[$0.id]! },
            discarder: { _ in },
            suggester: { _, _ in await gate.load() }
        )
        model.beginVoiceDraft("交接这项工作")
        let prepare = Task { await model.refreshSessions() }
        await gate.waitUntilRequested()
        model.selectSource(catalog[2].id)
        model.selectTarget(catalog[3].id)
        await gate.resolve(result)
        await prepare.value
        await model.loadHistory()
        XCTAssertEqual(model.sourceID, catalog[2].id)
        XCTAssertEqual(model.targetID, catalog[3].id)
        XCTAssertFalse(model.sourceWasSuggested)
        XCTAssertFalse(model.targetWasSuggested)
        XCTAssertEqual(model.sourceCandidates.first?.session.id, catalog[0].id)
        XCTAssertEqual(Set(model.choices(isSource: true, query: "").map(\.id)), Set(catalog.map(\.id)))
    }

    /// Verifies a manual receiver cannot be overwritten or become its own suggested source.
    ///
    /// Returns:
    ///   Nothing. The unresolved source remains empty and confirmation stays unavailable.
    @MainActor
    func testManualReceiverWinsOverOverlappingSuggestedSource() async {
        let source = session(1)
        let target = session(2)
        let result = suggestion(source: source, target: target)
        let gate = SuggestionResultGate()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in XCTFail("No source means no preview"); throw SuggestionFixtureError.failed },
            discarder: { _ in },
            suggester: { _, _ in await gate.load() }
        )
        model.beginVoiceDraft("交接这项工作")
        let prepare = Task { await model.refreshSessions() }
        await gate.waitUntilRequested()
        model.selectTarget(source.id)
        await gate.resolve(result)
        await prepare.value
        XCTAssertNil(model.sourceID)
        XCTAssertEqual(model.targetID, source.id)
        XCTAssertFalse(model.canSend)
    }

    /// Verifies a closed window and a newer voice draft reject an older pending result.
    ///
    /// Returns:
    ///   Nothing. No stale result can restore either selection or start preview loading.
    @MainActor
    func testCloseAndNewDraftInvalidatePendingSuggestions() async {
        let source = session(1)
        let target = session(2)
        let result = suggestion(source: source, target: target)
        for startsNewDraft in [false, true] {
            let gate = SuggestionResultGate()
            let model = AgentHandoffViewModel(
                catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
                historyLoader: { _ in XCTFail("Stale suggestion must not load history"); throw SuggestionFixtureError.failed },
                discarder: { _ in },
                suggester: { _, _ in await gate.load() }
            )
            model.beginVoiceDraft("旧语音")
            let prepare = Task { await model.refreshSessions() }
            await gate.waitUntilRequested()
            if startsNewDraft { model.beginVoiceDraft("新语音") } else { model.clearUnsentPreview() }
            await gate.resolve(result)
            await prepare.value
            XCTAssertNil(model.sourceID)
            XCTAssertNil(model.targetID)
            XCTAssertNil(model.history)
            XCTAssertFalse(model.isSuggesting)
            XCTAssertEqual(model.operation, .idle)
        }
    }

    /// Verifies native navigation cannot interrupt automatic preview preparation during ranking.
    ///
    /// Returns:
    ///   Nothing. The opener is deferred until recommendations and history have finished.
    @MainActor
    func testOpeningReceiverWaitsUntilSuggestionsFinish() async {
        let source = session(1)
        let target = session(2)
        let snapshot = history(source)
        let result = suggestion(source: source, target: target)
        let gate = SuggestionResultGate()
        let opens = SuggestionRequestCounter()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            opener: { _ in _ = await opens.next() },
            discarder: { _ in },
            suggester: { _, _ in await gate.load() }
        )
        model.beginVoiceDraft("交接这项工作")
        let prepare = Task { await model.refreshSessions() }
        await gate.waitUntilRequested()
        model.selectTarget(target.id)
        await model.openTarget()
        let before = await opens.current()
        XCTAssertEqual(before, 0)
        await gate.resolve(result)
        await prepare.value
        XCTAssertEqual(model.history?.source.id, source.id)
        XCTAssertTrue(model.canSend)
        await model.openTarget()
        let after = await opens.current()
        XCTAssertEqual(after, 1)
    }

    /// Verifies another catalog refresh prevents an earlier suggestion from replacing new choices.
    ///
    /// Returns:
    ///   Nothing. The latest refresh owns the suggestion and history state.
    @MainActor
    func testNewCatalogInvalidatesOlderSuggestion() async {
        let catalog = (1...4).map { session($0) }
        let snapshots = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, history($0)) })
        let first = suggestion(source: catalog[0], target: catalog[1])
        let latest = suggestion(source: catalog[2], target: catalog[3])
        let gate = SuggestionResultGate()
        let requests = SuggestionRequestCounter()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: catalog, unavailableApplications: []) },
            historyLoader: { snapshots[$0.id]! },
            discarder: { _ in },
            suggester: { _, _ in
                if await requests.next() == 1 { return await gate.load() }
                return latest
            }
        )
        model.beginVoiceDraft("交接这项工作")
        let oldPrepare = Task { await model.refreshSessions() }
        await gate.waitUntilRequested()
        await model.refreshSessions()
        await gate.resolve(first)
        await oldPrepare.value
        XCTAssertEqual(model.sourceID, catalog[2].id)
        XCTAssertEqual(model.targetID, catalog[3].id)
        XCTAssertEqual(model.history?.source.id, catalog[2].id)
    }

    /// Verifies an empty or failed suggestion leaves manual recovery available without sending.
    ///
    /// Returns:
    ///   Nothing. Only valid, distinct manual selections with a prepared preview enable confirmation.
    @MainActor
    func testEmptyAndFailedSuggestionsAllowManualRecovery() async {
        let source = session(1)
        let target = session(2)
        let snapshot = history(source)
        for fails in [false, true] {
            let model = AgentHandoffViewModel(
                catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
                historyLoader: { _ in snapshot },
                sender: { _, _, _ in XCTFail("Recovery is only a draft"); throw SuggestionFixtureError.failed },
                discarder: { _ in },
                suggester: { _, _ in
                    if fails { throw SuggestionFixtureError.failed }
                    return AgentHandoffSuggestion(sources: [], targets: [], sourceID: nil, targetID: nil, notice: nil)
                }
            )
            model.beginVoiceDraft("交接这项工作")
            await model.refreshSessions()
            XCTAssertNil(model.sourceID)
            XCTAssertNil(model.targetID)
            XCTAssertEqual(model.suggestionFailed, fails)
            XCTAssertFalse(model.canSend)
            model.selectSource(source.id)
            model.selectTarget(target.id)
            await model.loadHistory()
            XCTAssertTrue(model.canSend)
        }
    }

    /// Verifies new confirmation and recommendation copy follows the current interface language.
    func testSuggestionCopySupportsBothLanguages() {
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(AgentHandoffCopy.text(.send, language: language),
                           language == .zh ? "确认交接" : "Confirm handoff")
            XCTAssertEqual(AgentHandoffCopy.text(.suggested, language: language),
                           language == .zh ? "建议会话" : "Suggested conversation")
            XCTAssertEqual(AgentHandoffCopy.text(.manuallySelected, language: language),
                           language == .zh ? "你选择的会话" : "Your selection")
        }
    }

    /// Creates a synthetic native session without touching installed applications.
    ///
    /// Args:
    ///   number: Unique fixture identifier.
    ///
    /// Returns:
    ///   A conversation whose stable identity remains distinct even when titles match.
    private func session(_ number: Int) -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: String(format: "00000000-0000-4000-8000-%012d", number),
                               application: .codex, title: "示例工作", workspacePath: nil,
                               updatedAt: 100, matchTexts: ["示例工作"], openCapability: .codexDeepLink)
    }

    /// Creates a snapshot that exists only as a test value.
    ///
    /// Args:
    ///   source: Exact source identity associated with the snapshot.
    ///
    /// Returns:
    ///   Visible history with an inert file location.
    private func history(_ source: AgentSessionDescriptor) -> AgentHandoffHistory {
        AgentHandoffHistory(source: source, markdown: "用户：继续\n助手：收到", messageCount: 2,
                            snapshotDate: Date(timeIntervalSince1970: 1000),
                            fileURL: URL(fileURLWithPath: "/synthetic-fixture/suggestion-history.md"))
    }

    /// Creates ranked candidate evidence separate from the eventual confirmation action.
    ///
    /// Args:
    ///   source: Suggested history conversation.
    ///   target: Suggested receiver.
    ///
    /// Returns:
    ///   An editable suggestion with two distinct native identities.
    private func suggestion(source: AgentSessionDescriptor, target: AgentSessionDescriptor) -> AgentHandoffSuggestion {
        AgentHandoffSuggestion(
            sources: [AgentHandoffSuggestionCandidate(session: source, snippet: "相关来源", timestamp: nil)],
            targets: [AgentHandoffSuggestionCandidate(session: target, snippet: "相关接收会话", timestamp: nil)],
            sourceID: source.id, targetID: target.id, notice: .ambiguous
        )
    }
}

private enum SuggestionFixtureError: Error { case failed }

private actor SuggestionResultGate {
    private var pending: CheckedContinuation<AgentHandoffSuggestion, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// Suspends until a fixture explicitly completes the suggestion request.
    ///
    /// Returns:
    ///   The fixture's result, even after cancellation, to exercise generation guards.
    func load() async -> AgentHandoffSuggestion {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// Waits until the model is suspended inside its injected suggestion dependency.
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// Completes the pending request with a deterministic candidate result.
    ///
    /// Args:
    ///   result: Suggestion returned to the waiting model.
    func resolve(_ result: AgentHandoffSuggestion) {
        pending?.resume(returning: result)
        pending = nil
    }
}

private actor SuggestionSendRecords {
    private(set) var instructions: [String] = []

    /// Records explicit sends without contacting a real desktop agent.
    ///
    /// Args:
    ///   history: Prepared fixture preview.
    ///   target: Selected fixture receiver.
    ///   instruction: Current user-edited instruction at confirmation time.
    ///
    /// Returns:
    ///   A synthetic accepted receipt.
    func send(_ history: AgentHandoffHistory, target: AgentSessionDescriptor,
              instruction: String) -> AgentHandoffDeliveryReceipt {
        instructions.append(instruction)
        return AgentHandoffDeliveryReceipt(route: .codexQueue, messageID: "fixture", target: target,
                                           usesHistoryFile: true)
    }
}

private actor SuggestionRequestCounter {
    private var count = 0

    /// Reads the fixture count without starting another operation.
    ///
    /// Returns:
    ///   The number of recorded calls.
    func current() -> Int { count }

    /// Counts injected requests to distinguish an old request from a catalog refresh.
    ///
    /// Returns:
    ///   The one-based request number.
    func next() -> Int {
        count += 1
        return count
    }
}
