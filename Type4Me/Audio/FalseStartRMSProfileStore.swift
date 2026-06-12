import Foundation

struct FalseStartRMSProfileSnapshot: Sendable {
    let highFalseStartRMS: Float
    let samples: Int
    let updatedAt: Date
}

enum FalseStartRMSProfileStore {
    private static let samplesKey = "tf_focusFalseStartRMSProfileSamples"
    private static let updatedAtKey = "tf_focusFalseStartRMSProfileUpdatedAt"
    private static let defaultMaxSamples = 40

    /// Returns the persisted false-start RMS profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    ///
    /// Returns:
    ///   A robust upper RMS profile for recent false starts, or nil when empty.
    static func snapshot(defaults: UserDefaults = .standard) -> FalseStartRMSProfileSnapshot? {
        let samples = storedSamples(defaults: defaults)
        let updatedAt = Date(timeIntervalSince1970: defaults.double(forKey: updatedAtKey))
        return profileSnapshot(for: samples, updatedAt: updatedAt)
    }

    /// Persists one RMS sample from an ASR-empty false start.
    ///
    /// Args:
    ///   rms: Average RMS value that crossed the wake threshold.
    ///   defaults: UserDefaults source used by the app or tests.
    ///   maxSamples: Optional sample cap. Production uses the configured default.
    ///   source: Diagnostic source label.
    ///
    /// Returns:
    ///   Updated false-start profile, or the existing profile when the sample is invalid.
    @discardableResult
    static func record(
        _ rms: Float,
        defaults: UserDefaults = .standard,
        maxSamples: Int? = nil,
        source: String = "focus"
    ) -> FalseStartRMSProfileSnapshot? {
        guard rms.isFinite, rms > 0 else {
            return snapshot(defaults: defaults)
        }

        let limit = maxSamples.map { max(1, $0) } ?? configuredMaxSamples(defaults: defaults)
        var samples = storedSamples(defaults: defaults)
        samples.append(rms)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }

        defaults.set(samples.map(Double.init), forKey: samplesKey)
        let updatedAt = Date()
        defaults.set(updatedAt.timeIntervalSince1970, forKey: updatedAtKey)
        let snapshot = profileSnapshot(for: samples, updatedAt: updatedAt)
        if let snapshot {
            DebugFileLogger.log(
                "false-start RMS profile updated source=\(source) high=\(Int(snapshot.highFalseStartRMS)) samples=\(snapshot.samples)"
            )
        }
        return snapshot
    }

    /// Clears the persisted false-start RMS profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: updatedAtKey)
    }

    /// Computes a robust profile from false-start RMS samples.
    ///
    /// Args:
    ///   samples: Raw false-start RMS samples.
    ///   updatedAt: Timestamp assigned to the resulting profile.
    ///
    /// Returns:
    ///   High-percentile false-start RMS, or nil when no valid samples remain.
    nonisolated static func profileSnapshot(
        for samples: [Float],
        updatedAt: Date
    ) -> FalseStartRMSProfileSnapshot? {
        let values = samples.filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return FalseStartRMSProfileSnapshot(
            highFalseStartRMS: percentile(values, rank: 0.8),
            samples: values.count,
            updatedAt: updatedAt
        )
    }

    /// Reads stored false-start RMS samples from UserDefaults.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    ///
    /// Returns:
    ///   Valid RMS samples as Float values.
    private static func storedSamples(defaults: UserDefaults) -> [Float] {
        guard let values = defaults.array(forKey: samplesKey) as? [Double] else {
            return []
        }
        return values.map(Float.init).filter { $0.isFinite && $0 > 0 }
    }

    /// Reads the configured sample cap for the false-start profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    ///
    /// Returns:
    ///   Maximum number of recent false-start samples to retain.
    private static func configuredMaxSamples(defaults: UserDefaults) -> Int {
        let configured = defaults.object(forKey: "tf_focusFalseStartRMSProfileMaxSamples") == nil
            ? defaultMaxSamples
            : defaults.integer(forKey: "tf_focusFalseStartRMSProfileMaxSamples")
        return max(5, configured)
    }

    /// Calculates nearest-rank percentile for RMS samples.
    ///
    /// Args:
    ///   values: RMS values to summarize.
    ///   rank: Percentile rank in 0...1.
    ///
    /// Returns:
    ///   Percentile value, or zero when empty.
    private static func percentile(_ values: [Float], rank: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clampedRank = min(max(rank, 0), 1)
        let index = Int((Float(sorted.count - 1) * clampedRank).rounded())
        return sorted[index]
    }
}
