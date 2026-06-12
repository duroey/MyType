import Foundation

struct FocusWakeupRetentionPolicy<Focus: Equatable> {
    struct Config {
        let maxUnknownPolls: Int
        let maxUnknownDuration: TimeInterval
    }

    enum Probe: Equatable {
        case editable(Focus, pid: pid_t)
        case unknown(pid: pid_t?)
        case confirmedNoEditableFocus
    }

    enum Decision: Equatable {
        case arm(Focus)
        case keep(Focus)
        case clear
        case none
    }

    private(set) var currentFocus: Focus?
    private var config: Config
    private var currentPID: pid_t?
    private var firstUnknownAt: Date?
    private var unknownPolls = 0

    /// Creates a focus retention policy.
    ///
    /// Args:
    ///   config: Grace settings used for transient accessibility failures.
    init(config: Config) {
        self.config = config
    }

    /// Updates grace settings without discarding the retained focus.
    ///
    /// Args:
    ///   config: New retention settings.
    mutating func updateConfig(_ config: Config) {
        self.config = config
    }

    /// Clears all retained focus state.
    mutating func reset() {
        currentFocus = nil
        currentPID = nil
        firstUnknownAt = nil
        unknownPolls = 0
    }

    /// Applies a focus probe and returns the next controller action.
    ///
    /// Args:
    ///   probe: Latest focus probe result.
    ///   now: Timestamp used for grace-window calculations.
    ///
    /// Returns:
    ///   Decision telling the caller whether to arm, keep, clear, or do nothing.
    mutating func update(_ probe: Probe, at now: Date = Date()) -> Decision {
        switch probe {
        case .editable(let focus, let pid):
            let previousFocus = currentFocus
            let previousPID = currentPID
            currentFocus = focus
            currentPID = pid
            firstUnknownAt = nil
            unknownPolls = 0
            if previousFocus == focus, previousPID == pid {
                return .keep(focus)
            }
            return .arm(focus)

        case .unknown(let pid):
            guard let focus = currentFocus else { return .none }
            if let pid, let currentPID, pid != currentPID {
                reset()
                return .clear
            }

            unknownPolls += 1
            if firstUnknownAt == nil {
                firstUnknownAt = now
            }
            let elapsed = firstUnknownAt.map { now.timeIntervalSince($0) } ?? 0
            if unknownPolls > config.maxUnknownPolls || elapsed >= config.maxUnknownDuration {
                reset()
                return .clear
            }
            return .keep(focus)

        case .confirmedNoEditableFocus:
            guard currentFocus != nil else { return .none }
            reset()
            return .clear
        }
    }
}
