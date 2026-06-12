import Foundation

struct SpeechRMSProfileSnapshot: Sendable {
    let lowSpeechRMS: Float
    let medianSpeechRMS: Float
    let samples: Int
    let updatedAt: Date
}

enum SpeechRMSProfileStore {
    private static let samplesKey = "tf_focusSpeechRMSProfileSamples"
    private static let updatedAtKey = "tf_focusSpeechRMSProfileUpdatedAt"
    private static let defaultMaxSamples = 80

    /// Returns the persisted user speech RMS profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    ///
    /// Returns:
    ///   A robust speech RMS profile, or nil when no valid speech samples exist.
    static func snapshot(defaults: UserDefaults = .standard) -> SpeechRMSProfileSnapshot? {
        let samples = storedSamples(defaults: defaults)
        let updatedAt = Date(timeIntervalSince1970: defaults.double(forKey: updatedAtKey))
        return profileSnapshot(for: samples, updatedAt: updatedAt)
    }

    /// Persists a confirmed user speech RMS sample.
    ///
    /// Args:
    ///   rms: RMS value captured during a recording that ASR has already recognized as text.
    ///   defaults: UserDefaults source used by the app or tests.
    ///   maxSamples: Optional sample cap. Production uses the configured default.
    ///   source: Diagnostic source label.
    ///
    /// Returns:
    ///   Updated speech profile, or the existing profile when the new sample is invalid.
    @discardableResult
    static func record(
        _ rms: Float,
        defaults: UserDefaults = .standard,
        maxSamples: Int? = nil,
        source: String = "auto-stop"
    ) -> SpeechRMSProfileSnapshot? {
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
                "speech RMS profile updated source=\(source) low=\(Int(snapshot.lowSpeechRMS)) median=\(Int(snapshot.medianSpeechRMS)) samples=\(snapshot.samples)"
            )
        }
        return snapshot
    }

    /// Clears the persisted speech RMS profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: updatedAtKey)
    }

    /// Computes a robust speech profile from RMS samples.
    ///
    /// Args:
    ///   samples: Raw RMS samples captured from ASR-confirmed speech.
    ///   updatedAt: Timestamp assigned to the resulting profile.
    ///
    /// Returns:
    ///   Low and median speech RMS, or nil when no valid samples remain.
    nonisolated static func profileSnapshot(
        for samples: [Float],
        updatedAt: Date
    ) -> SpeechRMSProfileSnapshot? {
        let values = samples.filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return SpeechRMSProfileSnapshot(
            lowSpeechRMS: percentile(values, rank: 0.2),
            medianSpeechRMS: median(values),
            samples: values.count,
            updatedAt: updatedAt
        )
    }

    /// Reads stored RMS samples from UserDefaults.
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

    /// Reads the configured sample cap for the speech profile.
    ///
    /// Args:
    ///   defaults: UserDefaults source used by the app or tests.
    ///
    /// Returns:
    ///   Maximum number of recent speech samples to retain.
    private static func configuredMaxSamples(defaults: UserDefaults) -> Int {
        let configured = defaults.object(forKey: "tf_focusSpeechRMSProfileMaxSamples") == nil
            ? defaultMaxSamples
            : defaults.integer(forKey: "tf_focusSpeechRMSProfileMaxSamples")
        return max(5, configured)
    }

    /// Calculates median for an RMS sample list.
    ///
    /// Args:
    ///   values: RMS values to summarize.
    ///
    /// Returns:
    ///   Median value, or zero when empty.
    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
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
