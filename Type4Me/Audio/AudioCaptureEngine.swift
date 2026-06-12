@preconcurrency import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed
    case microphonePermissionDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return L("录音启动失败", "Failed to start recording")
        case .microphonePermissionDenied:
            return L("未授予麦克风权限", "Microphone permission not granted")
        case .noInputDevice:
            return L("找不到麦克风", "No microphone found")
        }
    }
}

struct PCM16FrameStats: Equatable, Sendable {
    let sampleCount: Int
    let rms: Float
    let minSample: Int
    let maxSample: Int
    let zeroRatio: Float
}

final class AudioCaptureEngine: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Static properties

    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1
    static let chunkDurationMs: Int = 200
    static let samplesPerChunk: Int = 3200
    static let chunkByteSize: Int = 6400
    static let frameDurationMs: Int = 20
    static let samplesPerFrame: Int = 320
    static let frameByteSize: Int = 640
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    static func makePCMBuffer(from pcmData: Data) -> AVAudioPCMBuffer? {
        guard pcmData.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        guard let mData = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        pcmData.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: pcmData.count)
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(pcmData.count)
        return buffer
    }

    /// Calculates lightweight diagnostics for PCM16 audio bytes.
    ///
    /// Args:
    ///   data: PCM16 little-endian audio bytes.
    ///
    /// Returns:
    ///   Sample count, RMS, min/max sample, and zero-sample ratio.
    nonisolated static func pcm16FrameStats(from data: Data) -> PCM16FrameStats {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return PCM16FrameStats(sampleCount: 0, rms: 0, minSample: 0, maxSample: 0, zeroRatio: 0)
        }

        var sum: Float = 0
        var minSample = Int(Int16.max)
        var maxSample = Int(Int16.min)
        var zeroSamples = 0
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let sample = Int(base[index])
                let value = Float(sample)
                sum += value * value
                minSample = min(minSample, sample)
                maxSample = max(maxSample, sample)
                if sample == 0 {
                    zeroSamples += 1
                }
            }
        }
        return PCM16FrameStats(
            sampleCount: sampleCount,
            rms: sqrt(sum / Float(sampleCount)),
            minSample: minSample,
            maxSample: maxSample,
            zeroRatio: Float(zeroSamples) / Float(sampleCount)
        )
    }

    // MARK: - Device Selection

    /// Set before calling `start()`. Empty string or nil means system default.
    var selectedDeviceUID: String?

    /// Returns a list of available audio input devices (UID + display name).
    static func availableAudioDevices() -> [(uid: String, name: String)] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Resolve the capture device: use selectedDeviceUID if set and valid, otherwise system default.
    private func resolveDevice() -> AVCaptureDevice? {
        if let uid = selectedDeviceUID, !uid.isEmpty,
           let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Public

    var onAudioChunk: ((Data) -> Void)?
    var onAudioFrame: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    // MARK: - Private

    private var captureSession: AVCaptureSession?
    private let stateLock = NSLock()
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var frameBuffer = Data()
    private var accumulatedAudio = Data()
    private var converter: AVAudioConverter?
    private let outputQueue = DispatchQueue(label: "com.mytype.audiocapture")
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private let outputQueueTag: UInt8 = 1
    private var activeOutput: AVCaptureAudioDataOutput?
    private var levelCounter = 0
    private var sessionNotificationTokens: [NSObjectProtocol] = []

    // MARK: - Warm-up

    private var isWarmedUp = false
    private var warmSession: AVCaptureSession?

    override init() {
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: outputQueueTag)
    }

    /// Pre-initialize the audio capture pipeline so the first real recording starts instantly.
    func warmUp() {
        guard !isWarmedUp else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[Audio] Warm-up skipped: microphone permission not granted")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                guard let device = self.resolveDevice() else { return }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                session.startRunning()
                // Keep it alive briefly to fully initialize CoreAudio, then stop
                Thread.sleep(forTimeInterval: 0.3)
                session.stopRunning()
                self.isWarmedUp = true
                NSLog("[Audio] Warm-up complete (device: %@)", device.localizedName)
            } catch {
                NSLog("[Audio] Warm-up failed: %@", String(describing: error))
            }
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Reset state
        bufferLock.lock()
        buffer = Data()
        frameBuffer = Data()
        accumulatedAudio = Data()
        bufferLock.unlock()
        converter = nil

        try startWithAVCapture()
    }

    private func startWithAVCapture() throws {
        let session = AVCaptureSession()

        guard let device = resolveDevice() else {
            throw AudioCaptureError.noInputDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addOutput(output)
        stateLock.withLock {
            activeOutput = output
        }
        installSessionDiagnostics(for: session, device: device)

        session.startRunning()
        captureSession = session
        isWarmedUp = true
        NSLog("[Audio] Capture session started (AVCapture), device: %@", device.localizedName)
        DebugFileLogger.log(
            "audio capture started device=\(device.localizedName) uid=\(device.uniqueID) running=\(session.isRunning)"
        )
    }

    func stop() {
        let session = captureSession
        DebugFileLogger.log("audio capture stop requested running=\(session?.isRunning ?? false)")
        session?.stopRunning()
        drainOutputQueue()
        let output = stateLock.withLock { () -> AVCaptureAudioDataOutput? in
            let current = activeOutput
            activeOutput = nil
            return current
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        removeSessionDiagnostics()
        captureSession = nil
        flushRemaining()
        bufferLock.lock()
        converter = nil
        onAudioChunk = nil
        onAudioFrame = nil
        onAudioLevel = nil
        bufferLock.unlock()
        levelCounter = 0
        NSLog("[Audio] Capture session stopped")
        DebugFileLogger.log("audio capture stopped")
    }

    /// Installs AVCaptureSession lifecycle diagnostics for the active session.
    ///
    /// Args:
    ///   session: Capture session whose runtime notifications should be logged.
    ///   device: Input device attached to the capture session.
    private func installSessionDiagnostics(for session: AVCaptureSession, device: AVCaptureDevice) {
        removeSessionDiagnostics()
        let center = NotificationCenter.default
        let deviceDescription = "\(device.localizedName) uid=\(device.uniqueID)"
        sessionNotificationTokens = [
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                DebugFileLogger.log(
                    "audio capture runtime error device=\(deviceDescription) error=\(String(describing: error))"
                )
            },
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { notification in
                DebugFileLogger.log(
                    "audio capture interrupted device=\(deviceDescription) userInfo=\(String(describing: notification.userInfo))"
                )
            },
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { _ in
                DebugFileLogger.log("audio capture interruption ended device=\(deviceDescription)")
            },
            center.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: nil
            ) { _ in
                DebugFileLogger.log("audio capture session did start running device=\(deviceDescription)")
            },
            center.addObserver(
                forName: .AVCaptureSessionDidStopRunning,
                object: session,
                queue: nil
            ) { _ in
                DebugFileLogger.log("audio capture session did stop running device=\(deviceDescription)")
            },
        ]
    }

    /// Removes AVCaptureSession diagnostic observers for the previous session.
    private func removeSessionDiagnostics() {
        let center = NotificationCenter.default
        for token in sessionNotificationTokens {
            center.removeObserver(token)
        }
        sessionNotificationTokens = []
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let isActiveOutput = stateLock.withLock { activeOutput === output }
        guard isActiveOutput else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Emit audio level ~20 times/sec (every 3rd callback at typical 60Hz buffer rate)
        levelCounter += 1
        if levelCounter % 3 == 0, let onAudioLevel {
            let level = Self.calculateLevel(from: pcmBuffer)
            onAudioLevel(level)
        }

        // Heartbeat log every ~5s (300 callbacks at ~60Hz)
        if levelCounter % 300 == 0 {
            let level = Self.calculateLevel(from: pcmBuffer)
            DebugFileLogger.log("audio heartbeat callback=\(levelCounter) bufferSize=\(buffer.count) level=\(String(format: "%.3f", level))")
        }

        // Create or recreate converter when source format changes
        bufferLock.lock()
        let sourceFormat = pcmBuffer.format
        if converter == nil || converter?.inputFormat != sourceFormat {
            if converter != nil {
                NSLog("[Audio] Input format changed, rebuilding converter: %@", sourceFormat.description)
            }
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            NSLog("[Audio] Input format: %@", sourceFormat.description)
        }
        guard let conv = converter else {
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        convert(buffer: pcmBuffer, using: conv)
    }

    // MARK: - Internal

    private func convert(buffer pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * Self.sampleRate / pcmBuffer.format.sampleRate
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        nonisolated(unsafe) var hasData = true
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil else { return }

        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        let chunk = Data(bytes: mData, count: byteCount)

        bufferLock.lock()
        accumulatedAudio.append(chunk)
        frameBuffer.append(chunk)
        buffer.append(chunk)
        emitFullFrames()
        emitFullChunks()
        bufferLock.unlock()
    }

    /// Returns the full recorded PCM audio since the last start().
    func getRecordedAudio() -> Data {
        bufferLock.lock()
        let data = accumulatedAudio
        bufferLock.unlock()
        return data
    }

    /// Emit all complete chunks from the buffer. Must be called with bufferLock held.
    private func emitFullChunks() {
        while buffer.count >= Self.chunkByteSize {
            let chunk = buffer.prefix(Self.chunkByteSize)
            buffer.removeFirst(Self.chunkByteSize)
            onAudioChunk?(Data(chunk))
        }
    }

    /// Emits all complete 20ms PCM frames from the frame buffer.
    ///
    /// The callback mirrors Python MyType's `block_ms=20` capture path so wakeup
    /// and silence detection use the same temporal resolution as the old app.
    private func emitFullFrames() {
        while frameBuffer.count >= Self.frameByteSize {
            let frame = frameBuffer.prefix(Self.frameByteSize)
            frameBuffer.removeFirst(Self.frameByteSize)
            onAudioFrame?(Data(frame))
        }
    }

    /// RMS → normalized 0..1 level from float PCM buffer.
    private static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let ptr = channelData[0]
        var sum: Float = 0
        // Sample every 16th frame for efficiency (256 samples max)
        let stride = max(1, frames / 256)
        var count = 0
        var i = 0
        while i < frames {
            sum += ptr[i] * ptr[i]
            count += 1
            i += stride
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50dB..0dB → 0..1
        return max(0, min(1, (db + 50) / 50))
    }

    private func bufferSize() -> Int {
        bufferLock.lock()
        let size = buffer.count
        bufferLock.unlock()
        return size
    }

    private func drainOutputQueue() {
        if DispatchQueue.getSpecific(key: outputQueueKey) == outputQueueTag {
            return  // already on outputQueue, skip to avoid deadlock
        }
        outputQueue.sync {}
    }

    private func flushRemaining() {
        bufferLock.lock()
        let remaining = buffer
        buffer = Data()
        bufferLock.unlock()

        if !remaining.isEmpty {
            onAudioChunk?(remaining)
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)

        if let floatData = pcmBuffer.floatChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: floatData[0])
        } else if let int16Data = pcmBuffer.int16ChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: int16Data[0])
        } else {
            return nil
        }

        return pcmBuffer
    }
}
