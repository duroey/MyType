import Foundation

struct FocusWakeupAdaptivePenalty {
    struct Config {
        let windowSize: Int
        let falseStartStepDb: Float
        let falseStartBurstStepDb: Float
        let maxPenaltyDb: Float
        let successRecoveryDb: Float
        let successRecoveryCount: Int
        let highFalseStartRate: Float
        let highFalseStartMinimumSamples: Int

        /// Loads adaptive wakeup penalty settings from UserDefaults.
        ///
        /// Args:
        ///   defaults: UserDefaults source used by the running app or tests.
        ///
        /// Returns:
        ///   Configured feedback-window penalty settings.
        static func load(defaults: UserDefaults = .standard) -> Config {
            Config(
                windowSize: max(1, defaults.integerOrDefault("tf_focusPenaltyWindowSize", defaultValue: 20)),
                falseStartStepDb: Float(defaults.object(forKey: "tf_focusFalseStartPenaltyDb") as? Double ?? 8),
                falseStartBurstStepDb: Float(defaults.object(forKey: "tf_focusFalseStartBurstPenaltyDb") as? Double ?? 6),
                maxPenaltyDb: Float(defaults.object(forKey: "tf_focusFalseStartMaxPenaltyDb") as? Double ?? 24),
                successRecoveryDb: Float(defaults.object(forKey: "tf_focusSuccessRecoveryDb") as? Double ?? 0.5),
                successRecoveryCount: max(1, defaults.integerOrDefault("tf_focusSuccessRecoveryCount", defaultValue: 5)),
                highFalseStartRate: Float(defaults.object(forKey: "tf_focusFalseStartHighRate") as? Double ?? 0.25),
                highFalseStartMinimumSamples: max(
                    1,
                    defaults.integerOrDefault("tf_focusFalseStartHighRateMinSamples", defaultValue: 5)
                )
            )
        }
    }

    private enum Outcome {
        case falseStart
        case success
    }

    private let config: Config
    private var currentPenaltyDb: Float
    private var recentOutcomes: [Outcome]
    private var consecutiveSuccesses: Int

    /// Creates a decibel-domain feedback penalty.
    ///
    /// Args:
    ///   config: Penalty tuning values.
    ///   now: Initial timestamp kept for call-site compatibility.
    ///   initialPenaltyDb: Initial penalty in dB, mainly used by tests.
    init(config: Config, now: Date = Date(), initialPenaltyDb: Float = 0) {
        self.config = config
        self.currentPenaltyDb = min(max(initialPenaltyDb, 0), max(config.maxPenaltyDb, 0))
        self.recentOutcomes = []
        self.consecutiveSuccesses = 0
    }

    /// Raises the penalty after an RMS-triggered false start.
    ///
    /// Args:
    ///   now: Timestamp kept for call-site compatibility.
    mutating func registerFalseStart(at now: Date = Date()) {
        appendOutcome(.falseStart)
        consecutiveSuccesses = 0
        let burstStep = shouldApplyBurstPenalty()
            ? max(config.falseStartBurstStepDb, 0)
            : 0
        currentPenaltyDb = min(
            currentPenaltyDb + max(config.falseStartStepDb, 0) + burstStep,
            max(config.maxPenaltyDb, 0)
        )
    }

    /// Lowers the penalty after a stable run of successful inputs.
    ///
    /// Args:
    ///   now: Timestamp kept for call-site compatibility.
    mutating func registerSuccessfulInput(at now: Date = Date()) {
        appendOutcome(.success)
        consecutiveSuccesses += 1
        guard consecutiveSuccesses >= config.successRecoveryCount else { return }
        currentPenaltyDb = max(currentPenaltyDb - max(config.successRecoveryDb, 0), 0)
        consecutiveSuccesses = 0
    }

    /// Clears penalty and feedback history after a new ambient calibration.
    mutating func reset() {
        currentPenaltyDb = 0
        recentOutcomes.removeAll(keepingCapacity: true)
        consecutiveSuccesses = 0
    }

    /// Replaces tuning values while preserving current feedback pressure.
    ///
    /// Args:
    ///   config: New penalty tuning values.
    ///   now: Timestamp kept for call-site compatibility.
    mutating func updateConfig(_ config: Config, at now: Date = Date()) {
        var updated = FocusWakeupAdaptivePenalty(config: config, now: now, initialPenaltyDb: currentPenaltyDb)
        updated.recentOutcomes = Array(recentOutcomes.suffix(config.windowSize))
        updated.consecutiveSuccesses = min(consecutiveSuccesses, config.successRecoveryCount - 1)
        self = updated
    }

    /// Returns the current feedback penalty in dB.
    ///
    /// Args:
    ///   now: Timestamp kept for call-site compatibility.
    ///
    /// Returns:
    ///   Current penalty in decibels.
    mutating func penaltyDb(at now: Date = Date()) -> Float {
        currentPenaltyDb
    }

    /// Applies the current penalty to a linear RMS threshold.
    ///
    /// Args:
    ///   baseThreshold: RMS threshold before false-start history is applied.
    ///   now: Timestamp kept for call-site compatibility.
    ///
    /// Returns:
    ///   RMS threshold multiplied by the decibel-domain penalty factor.
    mutating func effectiveThreshold(baseThreshold: Float, at now: Date = Date()) -> Float {
        baseThreshold * Self.multiplier(forPenaltyDb: penaltyDb(at: now))
    }

    /// Converts a dB penalty to a linear RMS multiplier.
    ///
    /// Args:
    ///   penaltyDb: Decibel penalty.
    ///
    /// Returns:
    ///   Linear amplitude multiplier for RMS thresholds.
    static func multiplier(forPenaltyDb penaltyDb: Float) -> Float {
        Float(pow(10.0, Double(max(penaltyDb, 0) / 20)))
    }

    /// Appends a wakeup outcome to the bounded feedback window.
    ///
    /// Args:
    ///   outcome: Latest wakeup outcome.
    private mutating func appendOutcome(_ outcome: Outcome) {
        recentOutcomes.append(outcome)
        if recentOutcomes.count > config.windowSize {
            recentOutcomes.removeFirst(recentOutcomes.count - config.windowSize)
        }
    }

    /// Returns whether the recent window shows a high false-start rate.
    ///
    /// Returns:
    ///   True when the bounded window is noisy enough to add burst penalty.
    private func shouldApplyBurstPenalty() -> Bool {
        guard recentOutcomes.count >= config.highFalseStartMinimumSamples else {
            return false
        }
        let falseStarts = recentOutcomes.filter { $0 == .falseStart }.count
        let rate = Float(falseStarts) / Float(recentOutcomes.count)
        return rate >= config.highFalseStartRate
    }
}

private extension UserDefaults {
    /// Reads an integer default while preserving an explicit zero value.
    ///
    /// Args:
    ///   key: UserDefaults key.
    ///   defaultValue: Fallback used when the key does not exist.
    ///
    /// Returns:
    ///   Stored integer or fallback value.
    func integerOrDefault(_ key: String, defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }
}
