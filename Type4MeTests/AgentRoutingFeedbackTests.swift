import XCTest
@testable import Type4Me

@MainActor
final class AgentRoutingFeedbackTests: XCTestCase {
    /// Verifies one visible semantic result renders in Chinese, English, then Chinese.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Exercises protocol dispatch used by every persistent floating-bar style.
    func testVisibleFeedbackFollowsLanguageChangesWithoutReplacingTheResult() {
        let state = makeState()
        let result = AgentRouterResult(outcome: .requestedOpen, activityTitle: "论文", application: .codex)
        state.activityKind = .revise
        state.latestReviseUndoTicketID = UUID()
        state.showAgentRoutingResult(result)
        let barState: any FloatingBarState = state

        XCTAssertEqual(barState.feedbackMessage(for: .zh), "已请求打开「论文」的 Codex 会话。")
        XCTAssertEqual(barState.feedbackMessage(for: .en), "Requested the Codex conversation for “论文”.")
        XCTAssertEqual(barState.feedbackMessage(for: .zh), "已请求打开「论文」的 Codex 会话。")
        XCTAssertEqual(state.agentRoutingResult, result)
        XCTAssertEqual(state.feedbackKind, .macActionSuccess)
        XCTAssertEqual(state.barPhase, .done)
        XCTAssertTrue(state.segments.isEmpty)
        XCTAssertEqual(state.activityKind, .standard)
        XCTAssertNil(state.latestReviseUndoTicketID)
        state.cancel()
    }

    /// Verifies navigation results reuse status presentation without claiming text injection.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts preview and choice states are unsure and failures stay failures.
    func testRoutingStatusesMapToExistingActionFeedback() {
        for outcome in [AgentRouterResult.Outcome.matchedPreview, .selectionRequired, .cancelled, .historyIndexUpdating, .newTaskPrepared] {
            XCTAssertEqual(AppState.agentRoutingFeedbackStatus(for: AgentRouterResult(outcome: outcome)), .unsure)
        }
        for outcome in [AgentRouterResult.Outcome.requestedOpen, .openedWithoutContinuation] {
            XCTAssertEqual(AppState.agentRoutingFeedbackStatus(for: AgentRouterResult(outcome: outcome)), .success)
        }
        for outcome in [AgentRouterResult.Outcome.noMatch, .noSessions, .noPreviousActivity, .noPendingSelection,
                        .unsupported, .failed, .catalogUnavailable] {
            XCTAssertEqual(AppState.agentRoutingFeedbackStatus(for: AgentRouterResult(outcome: outcome)), .failure)
        }
    }

    /// Verifies a pending choice uses unsure feedback and an unsupported target uses failure.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Checks actual presentation state without showing a window.
    func testRoutingPresentationUsesUnsureAndFailureStyles() {
        let state = makeState()
        state.showAgentRoutingResult(AgentRouterResult(outcome: .selectionRequired))
        XCTAssertEqual(state.feedbackKind, .macActionUnsure)
        XCTAssertEqual(state.barPhase, .done)
        state.showAgentRoutingResult(AgentRouterResult(outcome: .unsupported, application: .claudeCode))
        XCTAssertEqual(state.feedbackKind, .macActionFailure)
        XCTAssertEqual(state.barPhase, .error)
        XCTAssertEqual(state.feedbackMessage(for: .zh), "暂不能从外部定位 Claude Code 的这个原会话。")
        XCTAssertEqual(state.feedbackMessage(for: .en), "This existing Claude Code conversation cannot be located externally yet.")
        state.cancel()
    }

    /// Verifies phase changes discard semantic routing text before another workflow begins.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Uses state transitions without starting audio, ASR, or a real panel.
    func testOtherWorkflowPhasesClearRoutingFeedback() {
        let state = makeState()
        for phase in [FloatingBarPhase.preparing, .focusWaiting, .recording, .processing, .recovering, .hidden] {
            state.showAgentRoutingResult(AgentRouterResult(outcome: .selectionRequired))
            state.barPhase = phase
            XCTAssertNil(state.agentRoutingResult)
        }
        state.cancel()
    }

    /// Verifies later feedback messages replace routing text even within the same done phase.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. Asserts other action and error feedback retain their original messages.
    func testOtherFeedbackClearsSemanticResultAndUsesExistingMessage() {
        let state = makeState()
        state.showAgentRoutingResult(AgentRouterResult(outcome: .selectionRequired))
        state.showMacActionResult(message: "Other action", status: .success)
        XCTAssertNil(state.agentRoutingResult)
        XCTAssertEqual(state.feedbackMessage(for: .zh), "Other action")
        XCTAssertEqual(state.feedbackMessage(for: .en), "Other action")

        state.showAgentRoutingResult(AgentRouterResult(outcome: .cancelled))
        state.showError("Other error")
        XCTAssertNil(state.agentRoutingResult)
        XCTAssertEqual(state.feedbackMessage(for: .zh), "Other error")
        XCTAssertEqual(state.feedbackMessage(for: .en), "Other error")
        state.cancel()
    }

    /// Creates isolated state without reading real mode files or writing real preferences.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   App state with no panel callbacks, audio processes, or external agent actions.
    private func makeState() -> AppState {
        let suite = "Type4MeTests.AgentRoutingFeedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let modeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-feedback-modes-\(UUID().uuidString).json")
        return AppState(modeStorage: ModeStorage(fileURL: modeURL, userDefaults: defaults), userDefaults: defaults)
    }
}
