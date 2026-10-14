import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffVoiceDraftTests: XCTestCase {
    /// Verifies a new voice request cannot inherit an earlier source, receiver, or reviewed history.
    ///
    /// Returns:
    ///   Nothing. Checks the exact voice text survives while explicit selection is required again.
    @MainActor
    func testNewVoiceDraftClearsSelectionsAndKeepsOriginalText() async {
        let source = session(number: 1)
        let target = session(number: 2)
        let snapshot = history(source: source)
        let discarded = expectation(description: "Previous unused preview discarded")
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { _, _, _ in
                XCTFail("Preparing a draft must not send it")
                throw AgentHandoffDeliveryError.deliveryUncertain
            },
            discarder: { _ in discarded.fulfill() }
        )
        await model.refreshSessions()
        model.selectSource(source.id)
        model.selectTarget(target.id)
        model.sourceFilter = "旧来源"
        model.targetFilter = "旧目标"
        model.instruction = "之前的工作"
        await model.loadHistory()
        XCTAssertTrue(model.canSend)

        let original = " 把 Codex 里研究的方法交给 Claude，让它接着做。\n"
        XCTAssertTrue(model.beginVoiceDraft(original))
        XCTAssertEqual(model.instruction, original)
        XCTAssertEqual(model.voiceInstruction, original)
        XCTAssertNil(model.sourceID)
        XCTAssertNil(model.targetID)
        XCTAssertNil(model.history)
        XCTAssertEqual(model.sourceFilter, "")
        XCTAssertEqual(model.targetFilter, "")
        XCTAssertFalse(model.canSend)
        await model.send()
        await fulfillment(of: [discarded], timeout: 1)
    }

    /// Verifies a new voice draft discards a late preview from the previous source.
    ///
    /// Returns:
    ///   Nothing. Checks an older request cannot restore history after selections have been cleared.
    @MainActor
    func testNewVoiceDraftInvalidatesPendingHistory() async {
        let source = session(number: 1)
        let snapshot = history(source: source)
        let gate = VoiceDraftHistoryGate()
        let discarded = expectation(description: "Late preview discarded")
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source], unavailableApplications: []) },
            historyLoader: { _ in await gate.load() },
            discarder: { _ in discarded.fulfill() }
        )
        await model.refreshSessions()
        model.selectSource(source.id)
        let load = Task { await model.loadHistory() }
        await gate.waitUntilRequested()
        XCTAssertTrue(model.beginVoiceDraft("把另外一个会话交给 Claude"))
        await gate.resolve(snapshot)
        await load.value
        XCTAssertNil(model.history)
        XCTAssertNil(model.sourceID)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.operation, .idle)
        await fulfillment(of: [discarded], timeout: 1)
    }

    /// Verifies another voice request cannot replace a draft while native delivery is in flight.
    ///
    /// Returns:
    ///   Nothing. Checks the original instruction and receiver remain tied to the accepted send.
    @MainActor
    func testVoiceDraftIsRejectedDuringDelivery() async {
        let source = session(number: 1)
        let target = session(number: 2)
        let snapshot = history(source: source)
        let gate = VoiceDraftHistoryGate()
        let model = AgentHandoffViewModel(
            catalogLoader: { AgentSessionCatalogSnapshot(sessions: [source, target], unavailableApplications: []) },
            historyLoader: { _ in snapshot },
            sender: { _, target, _ in
                _ = await gate.load()
                return AgentHandoffDeliveryReceipt(route: .codexQueue, messageID: "fixture", target: target,
                                                   usesHistoryFile: true)
            },
            discarder: { _ in }
        )
        await model.refreshSessions()
        XCTAssertTrue(model.beginVoiceDraft("继续第一项工作"))
        model.selectSource(source.id)
        model.selectTarget(target.id)
        await model.loadHistory()
        let send = Task { await model.send() }
        await gate.waitUntilRequested()
        XCTAssertFalse(model.beginVoiceDraft("换成第二项工作"))
        XCTAssertEqual(model.instruction, "继续第一项工作")
        XCTAssertEqual(model.voiceInstruction, "继续第一项工作")
        XCTAssertEqual(model.sourceID, source.id)
        XCTAssertEqual(model.targetID, target.id)
        await gate.resolve(snapshot)
        await send.value
        XCTAssertEqual(model.receipt?.target.id, target.id)
    }

    /// Verifies voice guidance renders from the selected language rather than a stored translation.
    ///
    /// Returns:
    ///   Nothing. Checks both directions of an interface language change.
    func testVoiceDraftHintFollowsLanguageChanges() {
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(AgentHandoffCopy.text(.voiceInstructionHint, language: language), language == .zh
                ? "已根据语音建议来源和接收会话，可更换；确认后才会发送。"
                : "Conversations are suggested from your voice request. You can change them; nothing is sent until you confirm.")
        }
    }

    /// Creates a native session fixture without touching real conversations.
    ///
    /// Args:
    ///   number: Unique identity suffix.
    ///
    /// Returns:
    ///   A synthetic Codex session that can be selected for model-level validation.
    private func session(number: Int) -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: String(format: "00000000-0000-4000-8000-%012d", number),
                               application: .codex, title: "示例工作", workspacePath: nil,
                               updatedAt: 100, matchTexts: ["示例工作"], openCapability: .codexDeepLink)
    }

    /// Creates a visible-history fixture kept entirely in memory.
    ///
    /// Args:
    ///   source: The fixture's exact source session.
    ///
    /// Returns:
    ///   A synthetic snapshot whose file is never read or written.
    private func history(source: AgentSessionDescriptor) -> AgentHandoffHistory {
        AgentHandoffHistory(source: source, markdown: "用户：继续工作\n助手：收到", messageCount: 2,
                            snapshotDate: Date(timeIntervalSince1970: 1_000),
                            fileURL: URL(fileURLWithPath: "/synthetic-fixture/voice-history.md"))
    }
}

private actor VoiceDraftHistoryGate {
    private var pending: CheckedContinuation<AgentHandoffHistory, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// Suspends a fixture operation until the test supplies its result.
    ///
    /// Returns:
    ///   The snapshot explicitly provided by the test.
    func load() async -> AgentHandoffHistory {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// Waits until the fixture has begun the operation being tested.
    ///
    /// Returns:
    ///   Nothing. The model is suspended at its dependency boundary on return.
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// Completes the pending fixture operation.
    ///
    /// Args:
    ///   history: Snapshot returned to the suspended dependency.
    func resolve(_ history: AgentHandoffHistory) {
        pending?.resume(returning: history)
        pending = nil
    }
}
