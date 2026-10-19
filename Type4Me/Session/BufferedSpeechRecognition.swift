import Foundation

/// Recognition settings captured when a segment starts, including its streaming/batch choice.
struct BufferedASRSetup: Sendable {
    let provider: ASRProvider
    let config: any ASRProviderConfig
    let options: ASRRequestOptions
}

/// One completed recognition, ready for the existing ordered output pipeline.
struct BufferedASRResult: Sendable {
    let transcript: RecognitionTranscript
    let finishingSeconds: TimeInterval
}

/// Independent streaming recognition for audio captured while an older result is processing.
///
/// The capture callback enqueues synchronously so the final short packet cannot be overtaken
/// by endAudio. Audio is retained separately by BoundedRecordingQueue for one full replay
/// on failure. No provider event is allowed to finish or reset the shared output worker.
final class BufferedSpeechRecognition: @unchecked Sendable {
    struct Configuration: Sendable {
        var connectionTimeout: Duration = .seconds(10)
        var finishingTimeout: Duration = .seconds(45)
        var maximumBytes = BufferedRecordingConfiguration.defaultMaximumBytes
        var chunkBytes = BufferedRecordingConfiguration.storageChunkBytes
    }

    enum Outcome: Sendable {
        case recognized(BufferedASRResult)
        case replayRequired
        case cancelled
    }

    let setup: BufferedASRSetup
    private let client: any SpeechRecognizer
    private let configuration: Configuration
    private let onTranscript: @Sendable (RecognitionTranscript) -> Void
    private let lock = NSLock()
    private let stream: AsyncStream<Data>
    private let input: AsyncStream<Data>.Continuation
    private var tail = Data()
    private var acceptedBytes = 0
    private var sealedAt: Date?
    private var ending = false
    private var endRequestedAt: ContinuousClock.Instant?
    private var finalAfterEnd = false
    private var uploadFinished = false
    private var terminalReceived = false
    private var transcript = RecognitionTranscript.empty
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var tasks: [Task<Void, Never>] = []
    private var connected = false

    /// Starts a connection without blocking capture; both connection and finishing are bounded.
    ///
    /// Args:
    ///   setup: Immutable provider, credentials, mode and request options.
    ///   client: A newly created recognizer owned exclusively by this segment.
    ///   configuration: Memory, packet and timeout limits.
    ///   onTranscript: Live caption callback carrying only this segment's text.
    init(
        setup: BufferedASRSetup, client: any SpeechRecognizer,
        configuration: Configuration = .init(),
        onTranscript: @escaping @Sendable (RecognitionTranscript) -> Void
    ) {
        self.setup = setup
        self.client = client
        var limits = configuration
        limits.maximumBytes = max(MemoryLayout<Int16>.size, min(
            limits.maximumBytes, BufferedRecordingConfiguration.hardMaximumBytes
        ))
        limits.maximumBytes -= limits.maximumBytes % MemoryLayout<Int16>.size
        limits.chunkBytes = max(MemoryLayout<Int16>.size, min(
            limits.maximumBytes, limits.chunkBytes - limits.chunkBytes % MemoryLayout<Int16>.size
        ))
        self.configuration = limits
        self.onTranscript = onTranscript
        (stream, input) = AsyncStream.makeStream()
        register(Task { [self] in await run() })
        register(Task { [self] in
            do { try await Task.sleep(for: configuration.connectionTimeout) } catch { return }
            if lock.withLock({ !connected }) { resolve(.replayRequired) }
        })
    }

    /// Enqueues complete PCM samples, coalescing small frames into bounded upload packets.
    ///
    /// Args:
    ///   data: Mono 16 kHz PCM16, already accepted by the owning capture queue.
    func append(_ data: Data) {
        let invalid = lock.withLock { () -> Bool in
            guard outcome == nil, sealedAt == nil else { return false }
            guard data.count.isMultiple(of: MemoryLayout<Int16>.size),
                  data.count <= configuration.maximumBytes - acceptedBytes else { return true }
            acceptedBytes += data.count
            tail.append(data)
            while tail.count >= configuration.chunkBytes {
                input.yield(Data(tail.prefix(configuration.chunkBytes)))
                tail.removeFirst(configuration.chunkBytes)
            }
            return false
        }
        if invalid { resolve(.replayRequired) }
    }

    /// Flushes the last partial packet before closing input; recognition finishes in the background.
    func seal() {
        let shouldWait = lock.withLock { () -> Bool in
            guard outcome == nil, sealedAt == nil else { return false }
            sealedAt = Date()
            if !tail.isEmpty { input.yield(tail); tail = Data() }
            input.finish()
            return true
        }
        if shouldWait {
            register(Task { [self] in
                do { try await Task.sleep(for: configuration.finishingTimeout) } catch { return }
                resolve(.replayRequired)
            })
        }
    }

    /// Rejects truncated upload input so the consumer replays the exact retained PCM instead.
    func requireReplay() { resolve(.replayRequired) }

    /// Cancels this segment only, promptly releasing any consumer waiting for its result.
    func cancel() { resolve(.cancelled) }

    /// Waits for a terminal result without keeping the microphone or earlier output worker busy.
    func result() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Outcome? in
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Registers a task atomically with cancellation, including tasks created during shutdown.
    private func register(_ task: Task<Void, Never>) {
        let finished = lock.withLock { () -> Bool in
            guard outcome == nil else { return true }
            tasks.append(task)
            return false
        }
        if finished { task.cancel() }
    }

    /// Uploads in capture order and keeps provider events independent of the shared session actor.
    private func run() async {
        do {
            try await client.connect(config: setup.config, options: setup.options)
            let stopped = lock.withLock { () -> Bool in connected = true; return outcome != nil }
            if stopped { await client.disconnect(); return }
            // Some providers replace their event stream during connect.
            let events = await client.events
            register(Task { [self] in
                for await event in events {
                    if Task.isCancelled { return }
                    receive(event)
                }
                // A closed stream without an explicit terminal receipt is not full recognition.
                if lock.withLock({ !terminalReceived }) { resolve(.replayRequired) }
            })
            let audioInput = ASRProviderRegistry.capabilities(for: setup.provider, config: setup.config).audioInput
            for await data in stream {
                try Task.checkCancellation()
                switch audioInput {
                case .pcmData: try await client.sendAudio(data)
                case .pcmBuffer:
                    guard let buffer = AudioCaptureEngine.makePCMBuffer(from: data) else {
                        resolve(.replayRequired)
                        return
                    }
                    try await client.sendAudioBuffer(buffer)
                }
            }
            try Task.checkCancellation()
            lock.withLock { ending = true; endRequestedAt = .now }
            try await client.endAudio()
            lock.withLock { uploadFinished = true }
            completeIfReady()
        } catch {
            // Do not log provider errors here: some contain credentials or transcript fragments.
            resolve(.replayRequired)
        }
    }

    /// Accepts captions immediately but requires complete upload plus a terminal provider receipt.
    ///
    /// Args:
    ///   event: An event from this segment's private provider connection.
    private func receive(_ event: RecognitionEvent) {
        switch event {
        case .transcript(let value):
            let accepted = lock.withLock { () -> Bool in
                guard outcome == nil else { return false }
                let changed = value.displayText != transcript.displayText
                transcript = value
                finalAfterEnd = value.isFinal && endRequestedAt.map { value.emitTime >= $0 } == true
                // Volcano's asyncFinal is a session-level signal. Other providers can emit
                // isFinal for individual utterances and must also send their completed event.
                if finalAfterEnd, setup.provider == .volcano { terminalReceived = true }
                return changed
            }
            if accepted { onTranscript(value) }
            completeIfReady()
        case .completed:
            let endedEarly = lock.withLock { () -> Bool in
                guard ending else { return true }
                terminalReceived = true
                return false
            }
            if endedEarly { resolve(.replayRequired) } else { completeIfReady() }
        case .error: resolve(.replayRequired)
        default: break
        }
    }

    /// Publishes a reusable transcript only after all audio and endAudio have succeeded.
    private func completeIfReady() {
        let result = lock.withLock { () -> Outcome? in
            guard outcome == nil, uploadFinished, terminalReceived, let sealedAt else { return nil }
            // Some clients emit completed on a closed socket even if no final text arrived.
            // A partial caption is never sufficient evidence to skip full-audio recovery.
            guard finalAfterEnd, transcript.isFinal, transcript.partialText.isEmpty else { return .replayRequired }
            return .recognized(BufferedASRResult(
                transcript: transcript, finishingSeconds: max(0, Date().timeIntervalSince(sealedAt))
            ))
        }
        if let result { resolve(result) }
    }

    /// Resolves once, cancels bounded background work and disconnects only this recognizer.
    ///
    /// Args:
    ///   value: The sole final result delivered to ordered output or cancellation.
    private func resolve(_ value: Outcome) {
        let pending = lock.withLock { () -> ([CheckedContinuation<Outcome, Never>], [Task<Void, Never>])? in
            guard outcome == nil else { return nil }
            outcome = value
            input.finish()
            tail = Data()
            let pending = (waiters, tasks)
            waiters.removeAll()
            tasks.removeAll()
            return pending
        }
        guard let (waiters, tasks) = pending else { return }
        for task in tasks { task.cancel() }
        for waiter in waiters { waiter.resume(returning: value) }
        Task { [client] in await client.disconnect() }
    }
}
