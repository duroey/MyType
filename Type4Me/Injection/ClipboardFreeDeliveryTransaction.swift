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

    /// Configures optional tracking verification without accepting any clipboard capability.
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
    ///   Dispatch completion or a sending failure, without reading the editor after sending.
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
        switch dispatch {
        case .dispatched: return .inputDispatched
        case .partiallyDispatched: return .inputPartiallyDispatched
        case .uncertain: return .inputAttempted
        case .rejected: return .inputRejected
        case .unavailable: return .notDelivered
        }
    }

    /// Confirms an exact insertion solely for optional correction tracking, never for completion UI.
    ///
    /// Args:
    ///   target: Original destination retained by the completed delivery.
    /// Returns:
    ///   True only for an exact receipt. Enter, editing or leaving the field may invalidate tracking.
    func verifyInsertion(to target: ClipboardFreeTextDeliveryTarget) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.verificationTimeoutSeconds
        let polls = Int(ceil(configuration.verificationTimeoutSeconds / configuration.verificationPollIntervalSeconds))
        for attempt in 0...polls {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            switch target.observation() {
            case .inserted: return !Task.isCancelled
            case .targetChanged: return false
            case .unchanged, .unavailable, .changed, .selectionChanged:
                guard attempt < polls, ProcessInfo.processInfo.systemUptime < deadline else {
                    return false
                }
                wait(configuration.verificationPollIntervalSeconds)
            }
        }
        return false
    }
}
