import Foundation

/// A text delivery capability that never reads, publishes, or restores a pasteboard.
protocol ClipboardFreeTextDeliveryTarget {
    func isCurrent() -> Bool
    func observation() -> TextDeliveryObservation
    func insertUsingUnicode(shouldDispatch: () -> Bool) -> TextDeliveryAttempt
    func insertDirectly(shouldDispatch: () -> Bool) -> TextDeliveryAttempt
}

final class ClipboardFreeDeliveryTransaction {
    private let configuration: TextDeliveryConfiguration
    private let wait: (TimeInterval) -> Void

    /// Configures receipt polling without accepting any clipboard capability.
    ///
    /// Args:
    ///   configuration: Bounded receipt timing.
    ///   wait: Replaceable delay for isolated tests.
    init(configuration: TextDeliveryConfiguration = .init(),
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.configuration = configuration
        self.wait = wait
    }

    /// Sends text once; an uncertain result remains available in MyType history.
    ///
    /// Args:
    ///   target: Exact keyboard destination, with its final text already captured.
    /// Returns:
    ///   Confirmed, unconfirmed, or unsent delivery; never automatically copies.
    func deliver(to target: ClipboardFreeTextDeliveryTarget) -> TextDeliveryResult {
        let shouldDispatch = {
            guard target.isCurrent() else { return false }
            switch target.observation() {
            case .unchanged, .unavailable: return target.isCurrent()
            case .inserted, .changed, .selectionChanged, .targetChanged: return false
            }
        }
        guard shouldDispatch() else {
            let observation = target.observation()
            DebugFileLogger.log("injection: clipboard-free preflight blocked observation=\(observation)")
            return target.isCurrent() ? .notDelivered : .inputTargetChanged
        }
        var route = "unicode"
        var dispatch = target.insertUsingUnicode(shouldDispatch: shouldDispatch)
        if !dispatch.mayHaveDispatched {
            guard shouldDispatch() else {
                return target.isCurrent() ? .notDelivered : .inputTargetChanged
            }
            route = "directAX"
            dispatch = target.insertDirectly(shouldDispatch: shouldDispatch)
        }
        DebugFileLogger.log("injection: clipboard-free route=\(route) dispatch=\(dispatch)")
        guard dispatch.mayHaveDispatched else {
            return dispatch == .rejected ? .inputRejected : .notDelivered
        }
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.verificationTimeoutSeconds
        let polls = Int(ceil(configuration.verificationTimeoutSeconds / configuration.verificationPollIntervalSeconds))
        var finalObservation = TextDeliveryObservation.unavailable
        for attempt in 0...polls {
            finalObservation = target.observation()
            switch finalObservation {
            case .inserted, .targetChanged:
                return finish(dispatch: dispatch, observation: finalObservation, route: route)
            case .unchanged, .unavailable, .changed, .selectionChanged:
                // Editors may expose partial text while processing already queued events.
                // Keep observing within the existing deadline; never send the text again.
                guard attempt < polls, ProcessInfo.processInfo.systemUptime < deadline else {
                    return finish(dispatch: dispatch, observation: finalObservation, route: route)
                }
                wait(configuration.verificationPollIntervalSeconds)
            }
        }
        return finish(dispatch: dispatch, observation: finalObservation, route: route)
    }

    /// Separates a completed send from verified insertion and observable delivery failures.
    ///
    /// Args:
    ///   dispatch: Whether the complete payload, part of it, or an ambiguous AX write was sent.
    ///   observation: Last bounded observation of the original destination.
    ///   route: Delivery method used, for diagnostics without text content.
    /// Returns:
    ///   Verified insertion, normal dispatch completion, or a failure requiring attention.
    private func finish(
        dispatch: TextDeliveryAttempt, observation: TextDeliveryObservation, route: String
    ) -> TextDeliveryResult {
        let result: TextDeliveryResult
        if observation == .inserted {
            result = .inserted
        } else if dispatch == .partiallyDispatched {
            result = .inputPartiallyDispatched
        } else if dispatch == .dispatched, observation == .changed || observation == .unavailable {
            // A missing exact receipt is not a delivery error. Keep this distinct from
            // inserted so normal feedback never authorizes correction learning or retries.
            result = .inputDispatched
        } else {
            switch observation {
            case .inserted: result = .inserted
            case .unchanged, .selectionChanged: result = .inputUnchanged
            case .unavailable: result = .inputAttempted
            case .targetChanged: result = .inputTargetChanged
            case .changed: result = .inputChanged
            }
        }
        DebugFileLogger.log("injection: clipboard-free receipt route=\(route) dispatch=\(dispatch) observation=\(observation) result=\(result)")
        return result
    }
}
