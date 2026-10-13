import Foundation

/// Routes only transcripts from the existing dedicated Agent shortcut.
@MainActor
final class AgentCommandService {
    static let shared = AgentCommandService()

    /// Classifies a spoken request and enters an existing, cancellable workflow.
    ///
    /// Args:
    ///   text: Original transcript from the Agent shortcut, never ordinary dictation.
    ///
    /// Returns:
    ///   Navigation feedback or a prepared handoff; this method never sends history.
    func handle(_ text: String) async -> AgentRouterResult {
        guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }
        switch AgentActivityQuery.parse(text).intent {
        case .cancel, .browse, .continueLast, .ordinal:
            return await AgentRouterService.shared.handle(text)
        case .search:
            break
        }
        await AgentRouterService.shared.cancelPendingSelection()
        guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }

        let intent: AgentIntent?
        do {
            let decision = try await AgentIntentClassifier.shared.classify(text)
            guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }
            intent = decision.intent == .uncertain
                ? await AgentIntentPickerController.shared.choose(text: text)
                : decision.intent
        } catch is CancellationError {
            return AgentRouterResult(outcome: .cancelled)
        } catch {
            guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }
            intent = await AgentIntentPickerController.shared.choose(
                text: text, error: error as? AgentIntentClassifierError ?? .unavailable
            )
        }
        guard !Task.isCancelled else { return AgentRouterResult(outcome: .cancelled) }
        switch intent {
        case .wake:
            return await AgentRouterService.shared.handle(text)
        case .handoff:
            let accepted = AgentHandoffWindowController.shared.show(voiceInstruction: text)
            return AgentRouterResult(outcome: accepted ? .handoffPrepared : .handoffBusy)
        case .uncertain, nil:
            return AgentRouterResult(outcome: .cancelled)
        }
    }
}
