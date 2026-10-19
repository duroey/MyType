import XCTest
import os
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class OverlappingRecordingTests: XCTestCase {
    /// Exercises prepared speech through the real output formatter without network, AX writes or paste.
    func testPreparedSpeechReachesRealOutputWithoutSecondRecognition() async throws {
        let ended = expectation(description: "recognition ended")
        let client = OverlapStreamingASR(onEnd: { ended.fulfill() })
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting()
        await session.setBufferedRecognizerForTesting { (client, config) }
        let started = await session.startBufferedRecording(mode: .direct, initialAudioChunks: [Data([1, 0])])
        XCTAssertTrue(started)
        await session.stopRecording()
        await fulfillment(of: [ended], timeout: 1)
        await client.finish("第二段的内容")
        await session.setState(.idle)
        let deadline = ContinuousClock.now + .seconds(2)
        while await session.stoppedTextForTesting() == nil, ContinuousClock.now < deadline { await Task.yield() }
        let output = await session.stoppedTextForTesting()
        XCTAssertEqual(output, "第二段的内容")
        let connects = await client.connectCount
        XCTAssertEqual(connects, 1)
    }

    /// Escape after dequeue cancels the waiting result while allowing the following recording to finish.
    func testCancelDequeuedRecognitionLeavesFollowingSegmentUsable() async throws {
        let ended = expectation(description: "cancelled segment sealed")
        let nextEnded = expectation(description: "following segment sealed")
        let processed = expectation(description: "only the following segment is processed")
        let first = OverlapStreamingASR(onEnd: { ended.fulfill() })
        let second = OverlapStreamingASR(onEnd: { nextEnded.fulfill() })
        let clients = OSAllocatedUnfairLock(initialState: [first, second])
        let output = OSAllocatedUnfairLock(initialState: [String]())
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting(recognitionObserver: { _, result in
            output.withLock { $0.append(result?.transcript.displayText ?? "unexpected recovery") }
        }) { _ in processed.fulfill() }
        await session.setBufferedRecognizerForTesting { (clients.withLock { $0.removeFirst() }, config) }
        _ = await session.startBufferedRecording(mode: .direct, initialAudioChunks: [Data([1, 0])])
        await session.stopRecording()
        await fulfillment(of: [ended], timeout: 1)
        await session.setState(.idle)
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await session.bufferedSnapshotForTesting().pendingIDs.isEmpty), ContinuousClock.now < deadline { await Task.yield() }
        let pending = await session.bufferedSnapshotForTesting().pendingIDs
        XCTAssertTrue(pending.isEmpty, "The first segment must be waiting outside the capture queue")
        await session.cancelRecording()
        _ = await session.startBufferedRecording(mode: .direct, initialAudioChunks: [Data([2, 0])])
        await session.stopRecording()
        await fulfillment(of: [nextEnded], timeout: 1)
        await second.finish("后面的录音")
        await fulfillment(of: [processed], timeout: 2)
        XCTAssertEqual(output.withLock { $0 }, ["后面的录音"])
    }

    /// A sealed segment's late partial/final cannot replace the next active capture's subtitle.
    func testLateOldTranscriptCannotReplaceNewCapture() async throws {
        let ended = expectation(description: "old segment ended")
        let newCaption = expectation(description: "new segment caption")
        let oldCaption = expectation(description: "old segment must not appear")
        oldCaption.isInverted = true
        let first = OverlapStreamingASR(onEnd: { ended.fulfill() })
        let second = OverlapStreamingASR()
        let clients = OSAllocatedUnfairLock(initialState: [first, second])
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        await session.setBufferedRecognizerForTesting { (clients.withLock { $0.removeFirst() }, config) }
        _ = await session.startBufferedRecording(mode: .direct, initialAudioChunks: [Data([1, 0])])
        let oldID = await session.bufferedSnapshotForTesting().activeID
        await session.stopRecording()
        await fulfillment(of: [ended], timeout: 1)
        _ = await session.startBufferedRecording(mode: .direct)
        await session.setOnPresentationEvent { event, id in
            if case .transcript = event {
                if id == oldID { oldCaption.fulfill() } else { newCaption.fulfill() }
            }
        }
        try await first.sendAudio(Data([1, 0]))
        await first.finish("旧段的最终结果")
        await session.appendBufferedAudioForTesting(Data(repeating: 30, count: AudioCaptureEngine.chunkByteSize))
        await fulfillment(of: [newCaption, oldCaption], timeout: 0.2)
        await session.cancelRecording()
        await session.setState(.idle)
    }

    /// Later recognition may finish first, but output keeps capture order and reuses both results.
    func testOutOfOrderFinalsAreReusedInCaptureOrder() async throws {
        let firstEnded = expectation(description: "first sealed")
        let secondEnded = expectation(description: "second sealed")
        let processed = expectation(description: "ordered consumers")
        processed.expectedFulfillmentCount = 2
        let first = OverlapStreamingASR(onEnd: { firstEnded.fulfill() })
        let second = OverlapStreamingASR(onEnd: { secondEnded.fulfill() })
        let clients = OSAllocatedUnfairLock(initialState: [first, second])
        let output = OSAllocatedUnfairLock(initialState: [String]())
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting(recognitionObserver: { _, result in
            output.withLock { $0.append(result?.transcript.displayText ?? "unexpected recovery") }
        }) { _ in processed.fulfill() }
        await session.setBufferedRecognizerForTesting { (clients.withLock { $0.removeFirst() }, config) }
        for _ in 0..<2 {
            let started = await session.startBufferedRecording(mode: .direct)
            XCTAssertTrue(started)
            await session.appendBufferedAudioForTesting(Data([7, 0]))
            await session.stopRecording()
        }
        await fulfillment(of: [firstEnded, secondEnded], timeout: 1)
        await second.finish("第二段")
        await first.finish("第一段")
        XCTAssertEqual(output.withLock { $0 }, [], "Older polishing still owns output")
        await session.setState(.idle)
        await fulfillment(of: [processed], timeout: 2)
        XCTAssertEqual(output.withLock { $0 }, ["第一段", "第二段"])
        let connectionCounts = await (first.connectCount, second.connectCount)
        XCTAssertEqual(connectionCounts.0, 1)
        XCTAssertEqual(connectionCounts.1, 1)
    }

    /// A failed live connection retains every PCM byte for the existing recovery consumer.
    func testLiveConnectionFailurePreservesCompleteAudioForRecovery() async throws {
        let session = RecognitionSession()
        let recovered = expectation(description: "full audio available")
        let audio = Data([1, 0, 2, 0, 3, 0])
        let client = OverlapStreamingASR(failConnection: true)
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        await session.prepareBufferedPipelineForTesting(recognitionObserver: { _, result in
            XCTAssertNil(result, "A connection failure must not become an empty recognized result")
        }) { recording in
            XCTAssertEqual(recording.chunks.reduce(Data(), +), audio)
            recovered.fulfill()
        }
        await session.setBufferedRecognizerForTesting { (client, config) }
        let started = await session.startBufferedRecording(mode: .direct, initialAudioChunks: [audio])
        XCTAssertTrue(started)
        await session.stopRecording()
        await session.setState(.idle)
        await fulfillment(of: [recovered], timeout: 2)
    }

    /// Requires live captions and sound feedback before the older processing worker is released.
    func testSecondCaptureStreamsWhileOlderWorkerIsPolishing() async throws {
        let session = RecognitionSession()
        let caption = expectation(description: "second recording has live words")
        let client = OverlapStreamingASR()
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        let levels = OSAllocatedUnfairLock(initialState: [Float]())
        await session.prepareBufferedPipelineForTesting { _ in }
        await session.setBufferedRecognizerForTesting { (client, config) }
        await session.setOnAudioLevel { level in levels.withLock { $0.append(level) } }
        await session.setOnPresentationEvent { event, id in
            if case .transcript(let transcript) = event,
               transcript.displayText == "第二段实时字幕", id < 0 { caption.fulfill() }
        }
        let started = await session.startBufferedRecording(mode: .direct, externalAudioInput: true)
        XCTAssertTrue(started)
        let activeID = await session.bufferedSnapshotForTesting().activeID
        let id = try XCTUnwrap(activeID)
        await session.acceptExternalAudioFrame(Data(repeating: 30, count: AudioCaptureEngine.chunkByteSize), expectedGeneration: id)
        await fulfillment(of: [caption], timeout: 1)
        let state = await session.state
        XCTAssertEqual(state, .postProcessing, "Live recognition must not wait for the old worker")
        XCTAssertGreaterThan(levels.withLock { $0.max() ?? 0 }, 0)
        await session.acceptExternalAudioFrame(Data(repeating: 0, count: AudioCaptureEngine.frameByteSize), expectedGeneration: id)
        XCTAssertEqual(levels.withLock { $0.last }, 0)
        let count = levels.withLock { $0.count }
        await session.acceptExternalAudioFrame(Data(repeating: 30, count: AudioCaptureEngine.frameByteSize), expectedGeneration: id - 100)
        XCTAssertEqual(levels.withLock { $0.count }, count)
        await session.cancelRecording()
    }

    /// Ends a Focus capture on real silence and immediately accepts another while polishing stays held.
    ///
    /// Raises:
    ///   Error: Capture ownership was not assigned.
    func testFocusCaptureRearmsBeforeOlderPolishingCompletes() async throws {
        let previousDelay = UserDefaults.standard.object(forKey: FocusAutoStopSilenceSetting.storageKey)
        UserDefaults.standard.set(0.8, forKey: FocusAutoStopSilenceSetting.storageKey)
        defer { UserDefaults.standard.set(previousDelay, forKey: FocusAutoStopSilenceSetting.storageKey) }
        let session = RecognitionSession()
        let released = OSAllocatedUnfairLock(initialState: [Int]())
        let claimed = OSAllocatedUnfairLock(initialState: [Int]())
        await session.prepareBufferedPipelineForTesting { _ in }
        await session.setOnCaptureReleased { id in released.withLock { $0.append(id) } }
        let policy = RecordingStopPolicy.freeze(
            autoStopEnabled: true, acousticMode: .quiet,
            calibratedQuietThreshold: 50, isAutomaticTrigger: true
        )
        let speechFrame = Data(Array(repeating: [UInt8(100), UInt8(0)], count: AudioCaptureEngine.samplesPerFrame).joined())
        let started = await session.startBufferedRecording(
            mode: .direct, initialAudioChunks: [speechFrame], externalAudioInput: true,
            stopPolicy: policy, onClaimed: { id in claimed.withLock { $0.append(id) } }
        )
        XCTAssertTrue(started)
        let first = try XCTUnwrap(claimed.withLock { $0.first })
        for _ in 0..<100 {
            await session.acceptExternalAudioFrame(speechFrame, expectedGeneration: first)
        }
        let speaking = await session.bufferedSnapshotForTesting()
        XCTAssertEqual(speaking.activeID, first, "Quiet speech must not be cut off while the older LLM is waiting")
        for _ in 0..<100 {
            await session.acceptExternalAudioFrame(Data(repeating: 0, count: AudioCaptureEngine.frameByteSize), expectedGeneration: first)
        }
        let finished = await session.bufferedSnapshotForTesting()
        XCTAssertNil(finished.activeID)
        XCTAssertEqual(finished.pendingIDs, [first])
        XCTAssertEqual(released.withLock { $0 }, [first])
        let worker = await session.state
        XCTAssertEqual(worker, .postProcessing)

        let secondStarted = await session.startBufferedRecording(
            mode: .direct, initialAudioChunks: [speechFrame], externalAudioInput: true, stopPolicy: policy
        )
        XCTAssertTrue(secondStarted)
        let second = await session.bufferedSnapshotForTesting()
        await session.acceptExternalAudioFrame(speechFrame, expectedGeneration: first)
        await session.emitWorkerCompletionForTesting()
        let afterOldEvents = await session.bufferedSnapshotForTesting()
        XCTAssertEqual(afterOldEvents.activeID, second.activeID)
        XCTAssertEqual(afterOldEvents.retainedBytes, second.retainedBytes)
        XCTAssertEqual(released.withLock { $0 }, [first])
        await session.cancelRecording()
        await session.setState(.idle)
    }

    /// Retains low-volume manual speech recognized by the quiet gate, even without live ASR.
    ///
    /// Raises:
    ///   Error: The capture could not be created.
    func testQuietManualBufferDoesNotDiscardLowVolumeSpeech() async throws {
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        let started = await session.startBufferedRecording(
            mode: .direct,
            stopPolicy: .freeze(autoStopEnabled: true, acousticMode: .quiet,
                                calibratedQuietThreshold: 50, isAutomaticTrigger: false)
        )
        XCTAssertTrue(started)
        let initial = await session.bufferedSnapshotForTesting()
        let id = try XCTUnwrap(initial.activeID)
        let frame = Data(Array(repeating: [UInt8(93), UInt8(0)], count: AudioCaptureEngine.samplesPerFrame).joined())
        await session.acceptExternalAudioFrame(frame, expectedGeneration: id)
        await session.stopRecording(expectedGeneration: id)
        let stopped = await session.bufferedSnapshotForTesting()
        XCTAssertEqual(stopped.pendingIDs, [id])
        XCTAssertEqual(stopped.retainedBytes, frame.count)
        await session.setState(.idle)
    }

    /// Routes Focus monitor frames to the new capture while an older polish owns the worker.
    ///
    /// Raises:
    ///   Error: The new capture did not receive an identity.
    func testExternalFramesReachNewCaptureDuringOlderPolishing() async throws {
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        _ = await session.startBufferedRecording(mode: .direct)
        let snapshot = await session.bufferedSnapshotForTesting()
        let id = try XCTUnwrap(snapshot.activeID)

        await session.acceptExternalAudioFrame(Data([7, 8]), expectedGeneration: id)
        await session.acceptExternalAudioFrame(Data([9, 10]), expectedGeneration: id - 1)

        let received = await session.bufferedSnapshotForTesting()
        let worker = await session.state
        XCTAssertEqual(received.retainedBytes, 2)
        XCTAssertEqual(worker, .postProcessing)
        await session.cancelRecording()
    }

    /// Verifies a new capture keeps the older worker's generation and hides only its UI events.
    func testBackgroundCompletionCannotOwnNewRecordingPresentation() async throws {
        let session = RecognitionSession()
        let events = OSAllocatedUnfairLock(initialState: [Int]())
        await session.prepareBufferedPipelineForTesting { _ in }
        await session.setOnPresentationEvent { _, id in events.withLock { $0.append(id) } }
        let started = await session.startBufferedRecording(mode: .direct)
        XCTAssertTrue(started)
        let activeID = await session.bufferedSnapshotForTesting().activeID
        let id = try XCTUnwrap(activeID)
        await session.emitWorkerCompletionForTesting()
        let ids = events.withLock { $0 }
        XCTAssertEqual(ids, [id, 1])
        let oldVisible = await session.isCurrentPresentation(1)
        let currentVisible = await session.isCurrentPresentation(id)
        let workerState = await session.state
        XCTAssertFalse(oldVisible)
        XCTAssertTrue(currentVisible)
        XCTAssertEqual(workerState, .postProcessing)
        await session.cancelRecording()
    }

    /// Verifies two stopped buffers wait for the original worker and preserve exact FIFO audio.
    func testQueuedAudioRunsInOrderOnlyAfterOriginalWorkFinishes() async throws {
        let session = RecognitionSession()
        let processed = expectation(description: "both buffers processed")
        processed.expectedFulfillmentCount = 2
        let results = OSAllocatedUnfairLock(initialState: [Data]())
        await session.prepareBufferedPipelineForTesting { recording in
            results.withLock { $0.append(recording.chunks.reduce(Data(), +)) }
            processed.fulfill()
        }
        for bytes: [UInt8] in [[1, 2], [3, 4]] {
            let started = await session.startBufferedRecording(mode: .direct)
            XCTAssertTrue(started)
            await session.appendBufferedAudioForTesting(Data(bytes))
            await session.stopRecording()
        }
        XCTAssertEqual(results.withLock { $0.count }, 0)
        let queued = await session.bufferedSnapshotForTesting()
        XCTAssertEqual(queued.pendingCount, 2)
        await session.setState(.idle)
        await fulfillment(of: [processed], timeout: 2)
        XCTAssertEqual(results.withLock { $0 }, [Data([1, 2]), Data([3, 4])])
    }

    /// Verifies Escape discards only the newest capture, leaving queued audio and old work intact.
    func testAbortNewestCapturePreservesOlderQueueAndWorker() async {
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        _ = await session.startBufferedRecording(mode: .direct)
        await session.appendBufferedAudioForTesting(Data([1, 2]))
        await session.stopRecording()
        let older = await session.bufferedSnapshotForTesting().pendingIDs
        _ = await session.startBufferedRecording(mode: .direct)
        await session.appendBufferedAudioForTesting(Data([3, 4]))
        await session.abortAndStopRecording()
        let snapshot = await session.bufferedSnapshotForTesting()
        let state = await session.state
        XCTAssertNil(snapshot.activeID)
        XCTAssertEqual(snapshot.pendingIDs, older)
        XCTAssertEqual(state, .postProcessing)
        await session.setState(.idle)
    }

    /// Verifies a stale stop callback cannot stop a newer buffered capture.
    func testStaleStopDoesNotSealNewCapture() async throws {
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        _ = await session.startBufferedRecording(mode: .direct)
        let activeID = await session.activeRecordingGenerationForStop()
        let id = try XCTUnwrap(activeID)
        await session.stopRecording(expectedGeneration: id - 100)
        let stillActive = await session.activeRecordingGenerationForStop()
        XCTAssertEqual(stillActive, id)
        await session.cancelRecording()
    }

    /// Verifies action modes and an occupied microphone still reject overlap.
    func testExclusiveModesAndSecondActiveCaptureAreRejected() async {
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        var action = ProcessingMode.direct
        action.executionKind = .selectionAsk
        let actionStarted = await session.startBufferedRecording(mode: action)
        XCTAssertFalse(actionStarted)
        let first = await session.startBufferedRecording(mode: .direct)
        let second = await session.startBufferedRecording(mode: .direct)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await session.cancelRecording()
    }

    /// Verifies an actual suspended LLM call survives a new recording start and cancellation.
    func testNewRecordingDoesNotCancelInFlightPolishing() async throws {
        let entered = expectation(description: "polishing entered")
        let client = HeldPolishingClient { entered.fulfill() }
        let session = RecognitionSession()
        await session.prepareBufferedPipelineForTesting { _ in }
        let caption = expectation(description: "caption during real LLM call")
        let asr = OverlapStreamingASR()
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        await session.setBufferedRecognizerForTesting { (asr, config) }
        await session.setOnPresentationEvent { event, _ in
            if case .transcript = event { caption.fulfill() }
        }
        await session.setInjectedLLMClientForTesting(client)
        let target = TargetApplicationContext(processIdentifier: 123, bundleIdentifier: "test.input", displayName: "Input")
        let snapshot = IntelliSenseContextSnapshot.appOnly(target)
        let task = Task {
            await session.processIntelliSenseForTesting(
                text: "这是上一段还没有完成润色的内容",
                startingSnapshot: snapshot,
                settings: IntelliSenseSettings(applicationAwarenessEnabled: true, contextAwarenessEnabled: false, correctionDetectionEnabled: false, expressionLearningEnabled: false),
                currentTarget: { target },
                capture: { _, _ in snapshot }
            )
        }
        await fulfillment(of: [entered], timeout: 3)
        let started = await session.startBufferedRecording(mode: .direct)
        XCTAssertTrue(started)
        await session.appendBufferedAudioForTesting(Data(repeating: 9, count: AudioCaptureEngine.chunkByteSize))
        await fulfillment(of: [caption], timeout: 1)
        await session.cancelRecording()
        await client.release()
        let result = await task.value
        XCTAssertEqual(result?.text, "这是上一段还没有完成润色的内容")
        let calls = await client.callCount
        XCTAssertEqual(calls, 1)
    }
}

private actor OverlapStreamingASR: SpeechRecognizer {
    private let stream: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation

    private let onEnd: @Sendable () -> Void
    private let failConnection: Bool
    private(set) var connectCount = 0

    init(failConnection: Bool = false, onEnd: @escaping @Sendable () -> Void = {}) {
        (stream, continuation) = AsyncStream.makeStream()
        self.failConnection = failConnection
        self.onEnd = onEnd
    }
    var events: AsyncStream<RecognitionEvent> { stream }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        connectCount += 1
        if failConnection { throw URLError(.cannotConnectToHost) }
    }
    func sendAudio(_ data: Data) async throws {
        continuation.yield(.transcript(RecognitionTranscript(
            confirmedSegments: [], partialText: "第二段实时字幕", authoritativeText: "", isFinal: false
        )))
    }
    func endAudio() async throws { onEnd() }
    func finish(_ text: String) {
        continuation.yield(.transcript(.init(confirmedSegments: [text], partialText: "", authoritativeText: "", isFinal: true)))
        continuation.yield(.completed)
    }
    func disconnect() async { continuation.finish() }
}

private actor HeldPolishingClient: LLMClient {
    let onEnter: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(onEnter: @escaping @Sendable () -> Void) { self.onEnter = onEnter }

    /// Holds a real processing call until the test has started and cancelled another capture.
    func process(text: String, prompt: String, config: LLMConfig, inputBoundary: LLMInputBoundary) async throws -> String {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onEnter()
        }
        try Task.checkCancellation()
        return text
    }

    /// Releases the pending call without cancelling its task.
    func release() { continuation?.resume(); continuation = nil }
    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
