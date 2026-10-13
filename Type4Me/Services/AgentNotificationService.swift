import Foundation

/// Owns passive observers while the menu bar app is alive; no agent runtime is started.
@MainActor
final class AgentNotificationService {
    static let shared = AgentNotificationService()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    /// Restores the inbox and starts independent original-desktop notification streams.
    func start() {
        guard task == nil else { return }
        let token = UUID()
        generation = token
        task = Task { [weak self] in
            let configuration: AgentNotificationConfiguration
            do { configuration = try .bundled() }
            catch {
                NSLog("[AgentInbox] Notification configuration is invalid; observers were not started.")
                if self?.generation == token { self?.task = nil }
                return
            }
            await AgentInboxStore.shared.load()
            guard !Task.isCancelled, self?.generation == token else { return }
            let emit: @Sendable (AgentInboxUpdate) async -> Void = { [weak self] update in
                guard !Task.isCancelled else { return }
                await self?.receive(update, generation: token)
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await CodexDesktopNotificationSource(configuration: configuration).run(emit: emit) }
                group.addTask { await ClaudeDesktopNotificationSource(configuration: configuration).run(emit: emit) }
                group.addTask { [weak self] in
                    await ClaudeSessionViewingSource(configuration: configuration).run { [weak self] observation in
                        guard !Task.isCancelled else { return }
                        await self?.receiveViewing(observation, generation: token)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// Cancels this app's listeners; it never interrupts or closes the original agents.
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        AgentInboxStore.shared.cancelCompletionAlerts()
    }

    /// Rejects callbacks from a stopped observer before changing the shared UI state.
    ///
    /// Args:
    ///   update: Native observation delivered off the main actor.
    ///   token: Lifecycle generation that created the observer.
    private func receive(_ update: AgentInboxUpdate, generation token: UUID) {
        guard generation == token else { return }
        AgentInboxStore.shared.apply(update)
    }

    /// Drops late observer callbacks from an earlier monitoring lifecycle.
    ///
    /// Args:
    ///   observation: Stable viewing evidence without any task/approval side effect.
    ///   token: Monitoring lifecycle that produced the evidence.
    private func receiveViewing(_ observation: ClaudeSessionViewingObservation, generation token: UUID) {
        guard generation == token else { return }
        AgentInboxStore.shared.applyViewedSession(observation)
    }
}
