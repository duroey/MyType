import Foundation

enum FocusAcousticMode: String, CaseIterable, Sendable {
    case noisy, quiet
    static let storageKey = "tf_focusAcousticMode"

    /// Resolves a persisted mode, preserving the legacy algorithm by default.
    static func resolve(_ raw: String?) -> Self { Self(rawValue: raw ?? "") ?? .noisy }

    /// Returns the label for the current UI language without persisting translated text.
    func label(english: Bool) -> String {
        switch self {
        case .noisy: return english ? "Noisy Mode" : "嘈杂模式"
        case .quiet: return english ? "Quiet Mode" : "安静模式"
        }
    }
}

/// Shared tuning for the verified quiet-room prototype, in 20 ms audio frames.
enum QuietWakeupConfiguration {
    static let calibrationFrames = 150
    static let minimumThreshold: Float = 50
    static let noiseMultiplier: Float = 2.5
    static let noiseMargin: Float = 20
    static let windowFrames = 5
    static let onsetFrames = 6
    static let releaseFrames = 40
    static let releaseRatio: Float = 0.6
}

struct QuietWakeupGate: Sendable {
    private var calibration: [Float] = []
    private var window: [Float] = []
    private var consecutive = 0
    private(set) var threshold: Float?
    var calibrationRemaining: Int { max(0, QuietWakeupConfiguration.calibrationFrames - calibration.count) }

    /// Feeds one frame, calibrating once and subsequently detecting an onset.
    ///
    /// Args:
    ///   rms: Finite, nonnegative PCM16-scale RMS for a 20 ms frame.
    /// Returns:
    ///   True after enough consecutive raw and smoothed frames cross the fixed threshold.
    mutating func consume(_ rms: Float) -> Bool {
        guard rms.isFinite, rms >= 0 else { return false }
        guard let threshold else {
            calibration.append(rms)
            if calibration.count == QuietWakeupConfiguration.calibrationFrames {
                let sorted = calibration.sorted()
                let p95 = sorted[Int(Float(sorted.count) * 0.95)]
                self.threshold = max(QuietWakeupConfiguration.minimumThreshold,
                    p95 * QuietWakeupConfiguration.noiseMultiplier, p95 + QuietWakeupConfiguration.noiseMargin)
            }
            return false
        }
        window.append(rms)
        if window.count > QuietWakeupConfiguration.windowFrames { window.removeFirst() }
        let average = window.reduce(0, +) / Float(window.count)
        consecutive = rms >= threshold && average >= threshold ? consecutive + 1 : 0
        return consecutive >= QuietWakeupConfiguration.onsetFrames
    }

    /// Clears onset history between utterances without repeating calibration.
    mutating func rearm() { window.removeAll(keepingCapacity: true); consecutive = 0 }
}

struct QuietWakeupEndGate: Sendable {
    let threshold: Float
    private var window: [Float] = []
    private var quietFrames = 0

    /// Freezes the lower release threshold for this recording session.
    ///
    /// Args:
    ///   onsetThreshold: Calibrated threshold that actually triggered this session.
    init(onsetThreshold: Float) {
        threshold = onsetThreshold * QuietWakeupConfiguration.releaseRatio
    }

    /// Checks sustained silence using the same smoothing as the prototype.
    ///
    /// Args:
    ///   rms: RMS of one complete 20 ms frame.
    /// Returns:
    ///   True after 800 ms of smoothed audio below the release threshold.
    mutating func consume(_ rms: Float) -> Bool {
        guard rms.isFinite, rms >= 0 else { quietFrames = 0; return false }
        window.append(rms)
        if window.count > QuietWakeupConfiguration.windowFrames { window.removeFirst() }
        let average = window.reduce(0, +) / Float(window.count)
        quietFrames = average < threshold ? quietFrames + 1 : 0
        return quietFrames >= QuietWakeupConfiguration.releaseFrames
    }
}
