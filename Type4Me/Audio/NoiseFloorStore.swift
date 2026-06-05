import Foundation
import os

struct NoiseFloorSnapshot: Sendable {
    let noiseFloor: Float
    let threshold: Float
    let samples: Int
    let source: String
    let measuredAt: Date
}

struct NoiseFloorCalibrationResult: Sendable {
    let success: Bool
    let enabled: Bool
    let samples: Int
    let noiseFloor: Float?
    let threshold: Float
    let duration: TimeInterval
    let message: String?
    let error: String?
}

enum NoiseFloorStore {
    private static let state = OSAllocatedUnfairLock<NoiseFloorSnapshot?>(initialState: nil)

    /// Returns the latest shared noise-floor snapshot.
    ///
    /// Returns:
    ///   The most recent calibrated noise floor, or nil when no calibration has
    ///   completed in the current process.
    static func snapshot() -> NoiseFloorSnapshot? {
        state.withLock { $0 }
    }

    /// Stores a shared noise-floor snapshot for wakeup and silence decisions.
    ///
    /// Args:
    ///   noiseFloor: Median ambient RMS measured from 20ms audio frames.
    ///   threshold: Effective RMS threshold derived from the measured floor.
    ///   samples: Number of frames used by the measurement.
    ///   source: Short label identifying the calibration caller.
    static func update(noiseFloor: Float, threshold: Float, samples: Int, source: String) {
        let snapshot = NoiseFloorSnapshot(
            noiseFloor: noiseFloor,
            threshold: threshold,
            samples: samples,
            source: source,
            measuredAt: Date()
        )
        state.withLock { $0 = snapshot }
        DebugFileLogger.log(
            "noise floor updated source=\(source) floor=\(Int(noiseFloor)) threshold=\(Int(threshold)) samples=\(samples)"
        )
    }
}

enum NoiseFloorCalibrator {
    private static let samples = OSAllocatedUnfairLock(initialState: [Float]())
    private static let isRunning = OSAllocatedUnfairLock(initialState: false)
    private static let fallbackThreshold: Float = 500
    private static let noiseMargin: Float = 120
    private static let minThreshold: Float = 120

    /// Calibrates ambient RMS once if no process-local snapshot exists yet.
    ///
    /// Args:
    ///   duration: Time window in seconds used to sample ambient audio.
    ///   minSamples: Minimum number of 20ms frames required to accept the result.
    ///
    /// Returns:
    ///   Calibration result using the Python MyType response shape.
    @discardableResult
    static func calibrateIfNeeded(
        duration: TimeInterval = 1.5,
        minSamples: Int = 10
    ) async -> NoiseFloorCalibrationResult {
        if let snapshot = NoiseFloorStore.snapshot() {
            return NoiseFloorCalibrationResult(
                success: true,
                enabled: true,
                samples: snapshot.samples,
                noiseFloor: snapshot.noiseFloor,
                threshold: snapshot.threshold,
                duration: duration,
                message: "底噪校准完成",
                error: nil
            )
        }
        return await calibrate(duration: duration, minSamples: minSamples, source: "startup")
    }

    /// Measures ambient RMS with a short one-shot capture session.
    ///
    /// Args:
    ///   duration: Time window in seconds used to sample ambient audio.
    ///   minSamples: Minimum number of 20ms frames required to accept the result.
    ///   source: Short label written to diagnostic logs.
    ///
    /// Returns:
    ///   Calibration result using the Python MyType response shape.
    @discardableResult
    static func calibrate(
        duration: TimeInterval,
        minSamples: Int,
        source: String
    ) async -> NoiseFloorCalibrationResult {
        let started = isRunning.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
        guard started else {
            return NoiseFloorCalibrationResult(
                success: false,
                enabled: true,
                samples: 0,
                noiseFloor: nil,
                threshold: configuredFallbackThreshold(),
                duration: duration,
                message: nil,
                error: "底噪校准正在进行"
            )
        }
        defer { isRunning.withLock { $0 = false } }

        samples.withLock { $0.removeAll(keepingCapacity: true) }
        let engine = AudioCaptureEngine()
        engine.selectedDeviceUID = UserDefaults.standard.string(forKey: "tf_selectedMicrophoneUID")
        engine.onAudioFrame = { frame in
            let rms = rms16(frame)
            samples.withLock { $0.append(rms) }
        }

        do {
            try engine.start()
            DebugFileLogger.log("noise floor calibration started source=\(source) duration=\(duration)s")
        } catch {
            DebugFileLogger.log("noise floor calibration failed to start source=\(source): \(error)")
            return NoiseFloorCalibrationResult(
                success: false,
                enabled: true,
                samples: 0,
                noiseFloor: nil,
                threshold: configuredFallbackThreshold(),
                duration: duration,
                message: nil,
                error: "底噪校准失败: \(error.localizedDescription)"
            )
        }

        try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
        engine.stop()

        let values = samples.withLock { $0 }
        guard values.count >= minSamples else {
            DebugFileLogger.log("noise floor calibration skipped source=\(source) samples=\(values.count)")
            return NoiseFloorCalibrationResult(
                success: false,
                enabled: true,
                samples: values.count,
                noiseFloor: nil,
                threshold: configuredFallbackThreshold(),
                duration: duration,
                message: nil,
                error: "采样帧不足，已继续使用配置默认阈值"
            )
        }
        let floor = median(values)
        let threshold = max(floor + noiseMargin, minThreshold)
        NoiseFloorStore.update(noiseFloor: floor, threshold: threshold, samples: values.count, source: source)
        return NoiseFloorCalibrationResult(
            success: true,
            enabled: true,
            samples: values.count,
            noiseFloor: floor,
            threshold: threshold,
            duration: duration,
            message: "底噪校准完成",
            error: nil
        )
    }

    /// Reads the configured fallback threshold used when calibration fails.
    ///
    /// Returns:
    ///   Configured focus/silence RMS fallback, preserving the Python fallback of 500.
    private static func configuredFallbackThreshold() -> Float {
        let defaults = UserDefaults.standard
        return Float(defaults.object(forKey: "tf_focusAutoStopRMSThreshold") as? Double ?? Double(fallbackThreshold))
    }

    /// Calculates median RMS from collected frame values.
    ///
    /// Args:
    ///   values: RMS samples collected during calibration.
    ///
    /// Returns:
    ///   Median value, or zero for an empty list.
    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Calculates RMS from PCM16 audio bytes.
    ///
    /// Args:
    ///   data: PCM16 little-endian audio bytes.
    ///
    /// Returns:
    ///   Root mean square amplitude in Int16 sample units.
    private static func rms16(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let value = Float(base[index])
                sum += value * value
            }
        }
        return sqrt(sum / Float(sampleCount))
    }
}
