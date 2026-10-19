import Foundation
import XCTest
@testable import Type4Me

final class RecordingStopPolicyTests: XCTestCase {
    /// Verifies a manual Agent command inherits the calibrated quiet gate without false-start cancellation.
    func testManualQuietRecordingUsesSharedCalibration() {
        let policy = RecordingStopPolicy.freeze(
            autoStopEnabled: true, acousticMode: .quiet,
            calibratedQuietThreshold: 50, isAutomaticTrigger: false
        )
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.quietThreshold, 50)
        XCTAssertFalse(policy.allowsFalseStartCancellation)
    }

    /// Verifies missing or invalid quiet calibration cannot silently select the noisy gate.
    func testQuietRecordingWithoutUsableCalibrationRequiresManualStop() {
        let thresholds: [Float?] = [nil, 0, -1, .nan, .infinity]
        for threshold in thresholds {
            let policy = RecordingStopPolicy.freeze(
                autoStopEnabled: true, acousticMode: .quiet,
                calibratedQuietThreshold: threshold, isAutomaticTrigger: true
            )
            XCTAssertFalse(policy.enabled)
            XCTAssertNil(policy.quietThreshold)
            XCTAssertFalse(policy.allowsFalseStartCancellation)
        }
    }

    /// Verifies only an enabled automatic noisy trigger permits legacy false-start cancellation.
    func testFalseStartCancellationIsRestrictedToAutomaticNoisyTriggers() {
        for automatic in [false, true] {
            let policy = RecordingStopPolicy.freeze(
                autoStopEnabled: true, acousticMode: .noisy,
                calibratedQuietThreshold: 50, isAutomaticTrigger: automatic
            )
            XCTAssertTrue(policy.enabled)
            XCTAssertNil(policy.quietThreshold)
            XCTAssertEqual(policy.allowsFalseStartCancellation, automatic)
        }
        let quiet = RecordingStopPolicy.freeze(
            autoStopEnabled: true, acousticMode: .quiet,
            calibratedQuietThreshold: 50, isAutomaticTrigger: true
        )
        XCTAssertFalse(quiet.allowsFalseStartCancellation)
    }

    /// Verifies an explicit disabled setting wins over mode, calibration, and trigger type.
    func testDisabledAutoStopNeverEndsBufferedAudio() {
        for mode in FocusAcousticMode.allCases {
            let policy = RecordingStopPolicy.freeze(
                autoStopEnabled: false, acousticMode: mode,
                calibratedQuietThreshold: 50, isAutomaticTrigger: true
            )
            XCTAssertFalse(policy.enabled)
            XCTAssertNil(policy.quietThreshold)
            XCTAssertFalse(policy.allowsFalseStartCancellation)
            var gate = BufferedRecordingEndGate(policy: policy, configuration: configuration, hadSpeech: true)
            XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 150)))
        }
    }

    /// Replays the low-amplitude continuous speech that the old 183 RMS gate incorrectly stopped.
    func testQuietGateKeepsContinuousLowVolumeSpeechAndEndsRealSilence() {
        var gate = BufferedRecordingEndGate(policy: quietPolicy, configuration: configuration)
        XCTAssertFalse(gate.hasDetectedSpeech)
        XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 100)))
        XCTAssertFalse(gate.hasDetectedSpeech)
        XCTAssertFalse(gate.consume(waveform(amplitude: 93, frames: 100)))
        XCTAssertTrue(gate.hasDetectedSpeech)
        XCTAssertFalse(gate.consume(waveform(amplitude: 123, frames: 100)))
        XCTAssertTrue(gate.hasDetectedSpeech)
        XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 42)))
        XCTAssertTrue(gate.consume(waveform(amplitude: 0, frames: 1)))
        XCTAssertTrue(gate.hasDetectedSpeech)
        XCTAssertTrue(gate.consume(waveform(amplitude: 100, frames: 1)))
    }

    /// Verifies manual starts can wait for speech, while an already-triggered capture can end in silence.
    func testInitialSpeechOwnershipDistinguishesManualAndAutomaticCapture() {
        var manual = BufferedRecordingEndGate(policy: quietPolicy, configuration: configuration)
        XCTAssertFalse(manual.consume(waveform(amplitude: 0, frames: 200)))
        XCTAssertFalse(manual.consume(waveform(amplitude: 100, frames: 10)))
        XCTAssertTrue(manual.consume(waveform(amplitude: 0, frames: 50)))
        var automatic = BufferedRecordingEndGate(
            policy: quietPolicy, configuration: configuration, hadSpeech: true
        )
        XCTAssertFalse(automatic.consume(waveform(amplitude: 0, frames: 39)))
        XCTAssertTrue(automatic.consume(waveform(amplitude: 0, frames: 1)))
    }

    /// Verifies chunk size, nonzero Data indices, and partial PCM samples cannot change the end boundary.
    func testPCMFramingSurvivesLargeChunksDataSlicesAndOddByteBoundaries() {
        let audio = waveform(amplitude: 93, frames: 10) + waveform(amplitude: 0, frames: 50)
        var whole = BufferedRecordingEndGate(policy: quietPolicy, configuration: configuration)
        XCTAssertTrue(whole.consume(audio))

        var split = BufferedRecordingEndGate(policy: quietPolicy, configuration: configuration)
        let prefixBytes = 17
        let wrapped = Data(repeating: 0xff, count: prefixBytes) + audio + Data([0xff])
        var offset = prefixBytes
        var endedAt: Int?
        while offset < prefixBytes + audio.count {
            let end = min(offset + 317, prefixBytes + audio.count)
            if split.consume(wrapped[offset..<end]), endedAt == nil { endedAt = end - prefixBytes }
            offset = end
        }
        XCTAssertNotNil(endedAt)
        XCTAssertTrue(split.consume(Data()))

        var incomplete = BufferedRecordingEndGate(
            policy: quietPolicy, configuration: configuration, hadSpeech: true
        )
        let silence = waveform(amplitude: 0, frames: 40)
        XCTAssertFalse(incomplete.consume(silence.dropLast()))
        XCTAssertTrue(incomplete.consume(silence.suffix(1)))
    }

    /// Verifies the legacy noisy algorithm waits for speech and uses PCM duration instead of callback count.
    func testNoisyGatePreservesConfiguredThresholdWindowAndDelay() {
        let policy = RecordingStopPolicy.freeze(
            autoStopEnabled: true, acousticMode: .noisy,
            calibratedQuietThreshold: nil, isAutomaticTrigger: false
        )
        let tuning = BufferedRecordingEndGate.Configuration(
            silenceSeconds: 0.8, noisyThreshold: 183, noisyWindowFrames: 2
        )
        var gate = BufferedRecordingEndGate(policy: policy, configuration: tuning)
        XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 100)))
        XCTAssertFalse(gate.consume(waveform(amplitude: 220, frames: 20)))
        XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 39)))
        XCTAssertTrue(gate.consume(waveform(amplitude: 0, frames: 1)))
    }

    /// Verifies positively identified speech restarts the silence budget in both algorithms.
    func testSpeechEvidenceResetsTheSilenceBudget() {
        for mode in FocusAcousticMode.allCases {
            let policy = RecordingStopPolicy.freeze(
                autoStopEnabled: true, acousticMode: mode,
                calibratedQuietThreshold: 50, isAutomaticTrigger: false
            )
            var gate = BufferedRecordingEndGate(policy: policy, configuration: configuration, hadSpeech: true)
            XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 30)))
            gate.markSpeech()
            XCTAssertFalse(gate.consume(waveform(amplitude: 0, frames: 30)))
            XCTAssertTrue(gate.consume(waveform(amplitude: 0, frames: 10)))
        }
    }

    private var quietPolicy: RecordingStopPolicy {
        RecordingStopPolicy.freeze(
            autoStopEnabled: true, acousticMode: .quiet,
            calibratedQuietThreshold: 50, isAutomaticTrigger: false
        )
    }

    private var configuration: BufferedRecordingEndGate.Configuration {
        .init(silenceSeconds: 0.8, noisyThreshold: 183, noisyWindowFrames: 50)
    }

    /// Produces signed PCM16 alternating samples with an exact, nonzero RMS and no DC bias.
    ///
    /// Args:
    ///   amplitude: Absolute PCM16 sample amplitude; zero produces silence.
    ///   frames: Number of complete capture frames.
    /// Returns:
    ///   Little-endian mono PCM at the capture engine's sample rate.
    private func waveform(amplitude: Int16, frames: Int) -> Data {
        let samplesPerFrame = Int(AudioCaptureEngine.sampleRate) * AudioCaptureEngine.frameDurationMs / 1_000
        var result = Data(capacity: samplesPerFrame * frames * MemoryLayout<Int16>.size)
        for index in 0..<(samplesPerFrame * frames) {
            let value = UInt16(bitPattern: index.isMultiple(of: 2) ? amplitude : -amplitude)
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return result
    }
}
