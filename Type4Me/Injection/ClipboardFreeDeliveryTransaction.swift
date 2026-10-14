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
            case .inserted, .changed, .targetChanged: return false
            }
        }
        guard shouldDispatch() else { return .notDelivered }
        var route = "unicode"
        var dispatched = target.insertUsingUnicode(shouldDispatch: shouldDispatch) == .dispatched
        if !dispatched {
            guard shouldDispatch() else { return .notDelivered }
            route = "directAX"
            dispatched = target.insertDirectly(shouldDispatch: shouldDispatch) == .dispatched
        }
        guard dispatched else { return .notDelivered }
        DebugFileLogger.log("injection: clipboard-free dispatched route=\(route)")
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.verificationTimeoutSeconds
        let polls = Int(ceil(configuration.verificationTimeoutSeconds / configuration.verificationPollIntervalSeconds))
        for attempt in 0...polls {
            switch target.observation() {
            case .inserted: return .inserted
            case .changed, .targetChanged: return .inputAttempted
            case .unchanged, .unavailable:
                guard attempt < polls, ProcessInfo.processInfo.systemUptime < deadline else { return .inputAttempted }
                wait(configuration.verificationPollIntervalSeconds)
            }
        }
        return .inputAttempted
    }
}
