import XCTest
import os
@testable import Type4Me

final class BufferedSpeechRecognitionTests: XCTestCase {
    /// Verifies the final short packet is uploaded before endAudio and recognized only once.
    func testTailIsUploadedBeforeEndAndFinalCanBeReused() async throws {
        let client = ScriptedBufferedASR(finalText: "完整的一句话")
        let recognition = try makeRecognition(client)
        recognition.append(Data([1, 0, 2, 0]))
        recognition.append(Data([3, 0]))
        recognition.seal()
        let outcome = await recognition.result()
        guard case .recognized(let result) = outcome else { return XCTFail("Expected complete recognition") }
        XCTAssertEqual(result.transcript.displayText, "完整的一句话")
        let calls = await client.calls
        XCTAssertEqual(calls, ["connect", "audio:4", "audio:2", "end"])
        let audio = await client.audio
        XCTAssertEqual(audio, Data([1, 0, 2, 0, 3, 0]))
        guard case .recognized(let reused) = await recognition.result() else { return XCTFail("Missing retained result") }
        XCTAssertEqual(reused.transcript, result.transcript)
        let reusedCalls = await client.calls
        XCTAssertEqual(reusedCalls, calls, "Reading a queued result must not start a second request")
    }

    /// A closed socket after partial text is not proof that all recorded speech was recognized.
    func testPartialThenCompletedRequiresFullAudioRecovery() async throws {
        let client = ScriptedBufferedASR(finalText: "只有半句", finalIsConfirmed: false)
        let recognition = try makeRecognition(client)
        recognition.append(Data([1, 0]))
        recognition.seal()
        guard case .replayRequired = await recognition.result() else {
            return XCTFail("Partial text must never be delivered as full recognition")
        }
    }

    /// A sentence finalized during recording does not cover later audio when the socket closes.
    func testHistoricalSentenceFinalCannotStandInForRecordingFinal() async throws {
        let ended = expectation(description: "endAudio sent")
        let sentence = expectation(description: "early sentence arrived")
        let client = ScriptedBufferedASR(onEnd: { ended.fulfill() })
        let recognition = try makeRecognition(client) { value in
            if value.isFinal { sentence.fulfill() }
        }
        await client.emitSentenceFinal("前半句")
        await fulfillment(of: [sentence], timeout: 1)
        recognition.append(Data([1, 0, 2, 0]))
        recognition.seal()
        await fulfillment(of: [ended], timeout: 1)
        await client.closeWithoutFinal()
        guard case .replayRequired = await recognition.result() else {
            return XCTFail("Earlier final cannot prove that the rest of the audio was recognized")
        }
    }

    /// Releasing the hotkey does not make endAudio's return value a final recognition receipt.
    func testWaitsForFinalAfterEndAudioReturns() async throws {
        let ended = expectation(description: "endAudio returned")
        let client = ScriptedBufferedASR(onEnd: { ended.fulfill() })
        let recognition = try makeRecognition(client)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let result = await recognition.result()
            finished.withLock { $0 = true }
            return result
        }
        recognition.append(Data([1, 0]))
        recognition.seal()
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertFalse(finished.withLock { $0 })
        await client.finish(text: "尾音也到了")
        guard case .recognized(let result) = await task.value else { return XCTFail("Expected final text") }
        XCTAssertEqual(result.transcript.displayText, "尾音也到了")
    }

    /// A stalled final receipt has a deadline and leaves the retained PCM eligible for recovery.
    func testMissingFinalTimesOutInsteadOfBlockingOutputQueue() async throws {
        let recognition = try makeRecognition(ScriptedBufferedASR(), finishingTimeout: .milliseconds(30))
        recognition.append(Data([1, 0]))
        recognition.seal()
        guard case .replayRequired = await recognition.result() else { return XCTFail("Expected bounded recovery") }
    }

    /// Cancellation also works while connect is suspended; late connection success cannot restart upload.
    func testCancelledConnectionDoesNotUploadAfterLateConnectReturns() async throws {
        let connecting = expectation(description: "connect suspended")
        let disconnected = expectation(description: "late connection released")
        let client = ScriptedBufferedASR(holdConnect: true, onConnect: { connecting.fulfill() },
                                        onDisconnect: { disconnected.fulfill() })
        disconnected.expectedFulfillmentCount = 2
        let recognition = try makeRecognition(client)
        recognition.append(Data([1, 0, 2, 0]))
        await fulfillment(of: [connecting], timeout: 1)
        recognition.cancel()
        guard case .cancelled = await recognition.result() else { return XCTFail("Expected cancellation") }
        await client.releaseConnection()
        await fulfillment(of: [disconnected], timeout: 1)
        let calls = await client.calls
        XCTAssertEqual(calls, ["connect"])
    }

    /// endAudio must wait for a suspended tail upload, not merely for the input stream to close.
    func testEndCannotOvertakeHeldTailUpload() async throws {
        let uploading = expectation(description: "tail upload suspended")
        let client = ScriptedBufferedASR(finalText: "尾包", holdUpload: true, onUpload: { uploading.fulfill() })
        let recognition = try makeRecognition(client)
        recognition.append(Data([1, 0]))
        recognition.seal()
        await fulfillment(of: [uploading], timeout: 1)
        let beforeRelease = await client.calls
        XCTAssertEqual(beforeRelease, ["connect", "audio:2"])
        await client.releaseUpload()
        guard case .recognized = await recognition.result() else { return XCTFail("Expected complete tail") }
        let afterRelease = await client.calls
        XCTAssertEqual(afterRelease, ["connect", "audio:2", "end"])
    }

    /// Repeated identical partials cannot keep resetting the caller's silence detector.
    func testRepeatedCaptionIsNotPublishedAsNewSpeech() async throws {
        let firstCaption = expectation(description: "first new text")
        let finalCaption = expectation(description: "final changed text")
        let captions = OSAllocatedUnfairLock(initialState: [String]())
        let connected = expectation(description: "connected")
        let client = ScriptedBufferedASR(onConnect: { connected.fulfill() })
        let recognition = try makeRecognition(client) { value in
            captions.withLock { $0.append(value.displayText) }
            if value.displayText == "你好" { firstCaption.fulfill() }
            if value.displayText == "你好世界" { finalCaption.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 1)
        for _ in 0..<3 { await client.emitPartial("你好") }
        await fulfillment(of: [firstCaption], timeout: 1)
        recognition.seal()
        await client.finish(text: "你好世界")
        await fulfillment(of: [finalCaption], timeout: 1)
        XCTAssertEqual(captions.withLock { $0 }, ["你好", "你好世界"])
        recognition.cancel()
    }

    /// Builds an isolated provider connection with small packets and explicit test deadlines.
    private func makeRecognition(
        _ client: ScriptedBufferedASR, finishingTimeout: Duration = .seconds(1),
        onTranscript: @escaping @Sendable (RecognitionTranscript) -> Void = { _ in }
    ) throws -> BufferedSpeechRecognition {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test-only"]))
        return BufferedSpeechRecognition(
            setup: .init(provider: .volcano, config: config, options: .init()), client: client,
            configuration: .init(connectionTimeout: .seconds(1), finishingTimeout: finishingTimeout,
                                 maximumBytes: 64, chunkBytes: 4), onTranscript: onTranscript
        )
    }
}

/// Substitutes the network boundary only; upload ordering and lifecycle remain production code.
private actor ScriptedBufferedASR: SpeechRecognizer {
    private let stream: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let finalText: String?
    private let finalIsConfirmed: Bool
    private let holdConnect: Bool
    private let holdUpload: Bool
    private let onConnect: @Sendable () -> Void
    private let onUpload: @Sendable () -> Void
    private let onEnd: @Sendable () -> Void
    private let onDisconnect: @Sendable () -> Void
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var uploadWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    private(set) var audio = Data()

    init(
        finalText: String? = nil, finalIsConfirmed: Bool = true,
        holdConnect: Bool = false, holdUpload: Bool = false,
        onConnect: @escaping @Sendable () -> Void = {}, onUpload: @escaping @Sendable () -> Void = {},
        onEnd: @escaping @Sendable () -> Void = {}, onDisconnect: @escaping @Sendable () -> Void = {}
    ) {
        (stream, continuation) = AsyncStream.makeStream()
        self.finalText = finalText
        self.finalIsConfirmed = finalIsConfirmed
        self.holdConnect = holdConnect
        self.holdUpload = holdUpload
        self.onConnect = onConnect
        self.onUpload = onUpload
        self.onEnd = onEnd
        self.onDisconnect = onDisconnect
    }

    var events: AsyncStream<RecognitionEvent> { stream }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        calls.append("connect")
        if holdConnect {
            await withCheckedContinuation { connectWaiter = $0; onConnect() }
        } else { onConnect() }
    }

    func sendAudio(_ data: Data) async throws {
        calls.append("audio:\(data.count)")
        if holdUpload {
            await withCheckedContinuation { uploadWaiter = $0; onUpload() }
        } else { onUpload() }
        audio.append(data)
    }

    func endAudio() async throws {
        calls.append("end")
        if let finalText { finish(text: finalText, isFinal: finalIsConfirmed) }
        onEnd()
    }

    func emitPartial(_ text: String) {
        continuation.yield(.transcript(.init(
            confirmedSegments: [], partialText: text, authoritativeText: "", isFinal: false
        )))
    }

    func finish(text: String, isFinal: Bool = true) {
        continuation.yield(.transcript(.init(
            confirmedSegments: isFinal ? [text] : [], partialText: isFinal ? "" : text,
            authoritativeText: "", isFinal: isFinal
        )))
        continuation.yield(.completed)
    }

    func emitSentenceFinal(_ text: String) {
        continuation.yield(.transcript(.init(
            confirmedSegments: [text], partialText: "", authoritativeText: "", isFinal: true
        )))
    }

    func closeWithoutFinal() { continuation.yield(.completed) }

    func releaseConnection() { connectWaiter?.resume(); connectWaiter = nil }
    func releaseUpload() { uploadWaiter?.resume(); uploadWaiter = nil }
    func disconnect() async { continuation.finish(); onDisconnect() }
}
