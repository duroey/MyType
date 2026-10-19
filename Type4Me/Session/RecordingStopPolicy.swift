import Foundation

/// Frozen end-of-recording behavior, independent of the shortcut and processing mode.
struct RecordingStopPolicy: Equatable, Sendable {
    let enabled: Bool
    let quietThreshold: Float?
    let allowsFalseStartCancellation: Bool

    /// Resolves shared acoustic settings without reading preferences or touching capture devices.
    ///
    /// Args:
    ///   autoStopEnabled: Whether this capture is allowed to end automatically on silence.
    ///   acousticMode: Acoustic mode selected when capture starts.
    ///   calibratedQuietThreshold: Valid onset threshold for the currently selected microphone.
    ///   isAutomaticTrigger: Whether detected speech, rather than an explicit user action, started capture.
    /// Returns:
    ///   A policy that requires manual stopping when quiet calibration is unavailable.
    static func freeze(
        autoStopEnabled: Bool,
        acousticMode: FocusAcousticMode,
        calibratedQuietThreshold: Float?,
        isAutomaticTrigger: Bool
    ) -> Self {
        guard autoStopEnabled else {
            return Self(enabled: false, quietThreshold: nil, allowsFalseStartCancellation: false)
        }
        switch acousticMode {
        case .quiet:
            guard let threshold = calibratedQuietThreshold, threshold.isFinite, threshold > 0 else {
                return Self(enabled: false, quietThreshold: nil, allowsFalseStartCancellation: false)
            }
            return Self(enabled: true, quietThreshold: threshold, allowsFalseStartCancellation: false)
        case .noisy:
            return Self(
                enabled: true, quietThreshold: nil,
                allowsFalseStartCancellation: isAutomaticTrigger
            )
        }
    }
}

/// Bounded PCM-driven silence detector for captures whose ASR worker is not yet available.
struct BufferedRecordingEndGate: Sendable {
    struct Configuration: Sendable {
        static let defaultNoisyThreshold: Float = 500
        static let defaultNoisyWindowFrames = 50
        static let maximumNoisyWindowFrames = 500

        let silenceSeconds: Double
        let noisyThreshold: Float
        let noisyWindowFrames: Int

        /// Freezes validated tuning without consulting mutable application preferences.
        ///
        /// Args:
        ///   silenceSeconds: Required sustained silence in seconds.
        ///   noisyThreshold: RMS threshold used by the legacy noisy algorithm.
        ///   noisyWindowFrames: Number of capture frames in its rolling RMS average.
        init(
            silenceSeconds: Double,
            noisyThreshold: Float,
            noisyWindowFrames: Int = Self.defaultNoisyWindowFrames
        ) {
            self.silenceSeconds = FocusAutoStopSilenceSetting.normalized(silenceSeconds)
            self.noisyThreshold = noisyThreshold.isFinite && noisyThreshold > 0
                ? noisyThreshold : Self.defaultNoisyThreshold
            self.noisyWindowFrames = min(
                max(noisyWindowFrames, 1), Self.maximumNoisyWindowFrames
            )
        }
    }

    private static let frameSeconds = Double(AudioCaptureEngine.frameDurationMs) / 1_000
    private static let frameBytes = Int(AudioCaptureEngine.sampleRate * frameSeconds) * MemoryLayout<Int16>.size
    private let policy: RecordingStopPolicy
    private let configuration: Configuration
    private var quietGate: QuietWakeupEndGate?
    private var pendingFrame = Data()
    private var noisyWindow: [Float] = []
    private var noisyWindowIndex = 0
    private var noisyWindowSum: Float = 0
    private var silentFrames = 0
    private var hadSpeech: Bool
    private var ended = false

    /// Whether the trigger, PCM frames, or ASR evidence established speech for this capture.
    ///
    /// Buffered audio owners use this evidence to retain quiet speech even when
    /// its normalized UI meter level never reaches the legacy speech threshold.
    var hasDetectedSpeech: Bool { hadSpeech }

    /// Creates an end gate using the capture engine's mono PCM16 frame format.
    ///
    /// Args:
    ///   policy: Shared frozen recording policy.
    ///   configuration: Frozen silence duration and noisy-mode tuning.
    ///   hadSpeech: Whether the automatic trigger already established speech before this capture.
    init(
        policy: RecordingStopPolicy,
        configuration: Configuration,
        hadSpeech: Bool = false
    ) {
        self.policy = policy
        self.configuration = configuration
        self.hadSpeech = hadSpeech
        quietGate = policy.quietThreshold.map {
            QuietWakeupEndGate(onsetThreshold: $0, silenceSeconds: configuration.silenceSeconds)
        }
        pendingFrame.reserveCapacity(Self.frameBytes)
        noisyWindow.reserveCapacity(configuration.noisyWindowFrames)
    }

    /// Adds independent speech evidence, such as an actual change in the ASR transcript.
    ///
    /// Repeated unchanged partial events must not call this method, because doing so
    /// would extend the silence deadline even after the speaker stopped.
    mutating func markSpeech() {
        guard !ended else { return }
        hadSpeech = true
        silentFrames = 0
        if let threshold = policy.quietThreshold {
            quietGate = QuietWakeupEndGate(
                onsetThreshold: threshold, silenceSeconds: configuration.silenceSeconds
            )
        }
    }

    /// Consumes any number of PCM bytes while retaining at most one incomplete frame.
    ///
    /// Args:
    ///   pcm: Little-endian mono PCM16 bytes; chunk and sample boundaries may be split.
    /// Returns:
    ///   True once sustained silence ends this capture; subsequent calls stay true.
    mutating func consume(_ pcm: Data) -> Bool {
        guard policy.enabled, !ended else { return ended }
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let count = min(Self.frameBytes - pendingFrame.count, pcm.endIndex - offset)
            pendingFrame.append(pcm[offset..<(offset + count)])
            offset += count
            guard pendingFrame.count == Self.frameBytes else { continue }
            let rms = Self.rms16(pendingFrame)
            pendingFrame.removeAll(keepingCapacity: true)
            if consumeFrame(rms) {
                ended = true
                return true
            }
        }
        return false
    }

    /// Evaluates one complete capture frame using the selected acoustic algorithm.
    ///
    /// Args:
    ///   rms: RMS amplitude of exactly one capture frame.
    /// Returns:
    ///   True after speech has occurred and the configured silence interval has elapsed.
    private mutating func consumeFrame(_ rms: Float) -> Bool {
        if var gate = quietGate {
            if !hadSpeech {
                guard rms >= gate.threshold else { return false }
                hadSpeech = true
            }
            let result = gate.consume(rms)
            quietGate = gate
            return result
        }

        if noisyWindow.count < configuration.noisyWindowFrames {
            noisyWindow.append(rms)
            noisyWindowSum += rms
        } else {
            noisyWindowSum += rms - noisyWindow[noisyWindowIndex]
            noisyWindow[noisyWindowIndex] = rms
            noisyWindowIndex = (noisyWindowIndex + 1) % configuration.noisyWindowFrames
        }
        let average = noisyWindowSum / Float(noisyWindow.count)
        if average >= configuration.noisyThreshold {
            hadSpeech = true
            silentFrames = 0
            return false
        }
        guard hadSpeech else { return false }
        silentFrames += 1
        return Double(silentFrames) * Self.frameSeconds >= configuration.silenceSeconds
    }

    /// Decodes PCM16 without assuming Data storage alignment or native byte order.
    ///
    /// Args:
    ///   frame: One complete, sample-aligned PCM16 frame.
    /// Returns:
    ///   Root mean square sample amplitude.
    private static func rms16(_ frame: Data) -> Float {
        frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let samples = bytes.count / MemoryLayout<Int16>.size
            var squares: Float = 0
            for index in 0..<samples {
                let low = UInt16(bytes[index * MemoryLayout<Int16>.size])
                let high = UInt16(bytes[index * MemoryLayout<Int16>.size + 1]) << 8
                let sample = Float(Int16(bitPattern: low | high))
                squares += sample * sample
            }
            return sqrt(squares / Float(samples))
        }
    }
}
