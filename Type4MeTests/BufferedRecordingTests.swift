import XCTest
@testable import Type4Me

final class BufferedRecordingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Verifies FIFO completion, exact samples, actual capture times, and unique negative ownership.
    func testPreservesFIFOAudioModeAndCaptureTimes() throws {
        let queue = BoundedRecordingQueue()
        let first = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertLessThan(first, 0)
        XCTAssertEqual(queue.append(Data([1, 2, 3, 4]), to: first, at: start), .accepted)
        let firstRecording = try XCTUnwrap(queue.finish(id: first, at: start.addingTimeInterval(2)))
        let second = try queue.start(mode: .direct, target: nil, at: start.addingTimeInterval(3)).get()
        XCTAssertLessThan(second, 0)
        XCTAssertNotEqual(first, second)
        queue.finish(id: second, at: start.addingTimeInterval(4))
        XCTAssertEqual(queue.snapshot().pendingIDs, [first, second])
        XCTAssertEqual(firstRecording.duration, 2)
        XCTAssertEqual(firstRecording.startedAt, start)
        XCTAssertEqual(firstRecording.mode, .direct)
        XCTAssertEqual(firstRecording.chunks, [Data([1, 2, 3, 4])])
        XCTAssertEqual(queue.dequeue()?.id, first)
        XCTAssertEqual(queue.dequeue()?.id, second)
        XCTAssertNil(queue.dequeue())
        XCTAssertEqual(queue.snapshot().retainedBytes, 0)
    }

    /// Verifies that pending recordings and the active capture share the segment capacity.
    func testCapacityIncludesActiveAndPendingSegments() throws {
        let queue = BoundedRecordingQueue(configuration: .init(maximumSegments: 2))
        let first = try queue.start(mode: .direct, target: nil, at: start).get()
        assertStartFailure(queue.start(mode: .direct, target: nil, at: start), equals: .alreadyRecording)
        queue.finish(id: first, at: start)
        let second = try queue.start(mode: .direct, target: nil, at: start).get()
        queue.finish(id: second, at: start)
        XCTAssertFalse(queue.snapshot().canStart)
        assertStartFailure(queue.start(mode: .direct, target: nil, at: start), equals: .capacityReached)
        _ = queue.dequeue()
        XCTAssertTrue(queue.snapshot().canStart)
    }

    /// Verifies bounded partial acceptance and tail retention at the queue-wide byte limit.
    func testMemoryLimitKeepsOnlyBoundedPCMAndRejectsLaterCallbacks() throws {
        let queue = BoundedRecordingQueue(configuration: .init(maximumBytes: 8))
        let first = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data([1, 2, 3, 4]), to: first, at: start), .accepted)
        queue.finish(id: first, at: start)
        let second = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data([5, 6, 7, 8, 9, 10]), to: second, at: start), .stopRequired(.memoryLimit))
        XCTAssertEqual(queue.append(Data([11, 12]), to: second, at: start), .stopRequired(.memoryLimit))
        XCTAssertEqual(queue.snapshot().retainedBytes, 8)
        let recording = try XCTUnwrap(queue.finish(id: second, at: start))
        XCTAssertEqual(recording.chunks, [Data([5, 6, 7, 8])])
        XCTAssertEqual(recording.byteCount, 4)
    }

    /// Verifies both wall-clock and sample-count duration limits independently.
    func testDurationLimitsCannotBeBypassedByCallbackTiming() throws {
        let queue = BoundedRecordingQueue(configuration: .init(maximumDuration: 1))
        let first = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data([1, 2]), to: first, at: start.addingTimeInterval(1)), .stopRequired(.durationLimit))
        XCTAssertEqual(queue.snapshot().retainedBytes, 0)
        queue.cancel(id: first)
        let second = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data(repeating: 1, count: 32_002), to: second, at: start), .stopRequired(.durationLimit))
        XCTAssertEqual(queue.snapshot().retainedBytes, 32_000)
    }

    /// Verifies cancellation and stale callbacks affect only the matching recording.
    func testCancellationDoesNotDiscardOtherSegments() throws {
        let queue = BoundedRecordingQueue()
        let first = try queue.start(mode: .direct, target: nil, at: start).get()
        _ = queue.append(Data([1, 2]), to: first, at: start)
        queue.finish(id: first, at: start)
        let second = try queue.start(mode: .direct, target: nil, at: start).get()
        _ = queue.append(Data([3, 4]), to: second, at: start)
        XCTAssertTrue(queue.cancel(id: first))
        XCTAssertEqual(queue.snapshot().activeID, second)
        XCTAssertEqual(queue.append(Data([9, 9]), to: first, at: start), .staleRecording)
        XCTAssertNil(queue.finish(id: first, at: start))
        XCTAssertTrue(queue.cancel(id: second))
        XCTAssertFalse(queue.cancel(id: second))
        XCTAssertEqual(queue.snapshot().retainedBytes, 0)
    }

    /// Verifies repeated one-sample callbacks cannot create unbounded chunk-array overhead.
    func testCoalescesTinyChunksAndRejectsPartialPCM16Samples() throws {
        let queue = BoundedRecordingQueue()
        let id = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data([1]), to: id, at: start), .invalidPCM)
        for _ in 0..<4_000 { _ = queue.append(Data([1, 2]), to: id, at: start) }
        let recording = try XCTUnwrap(queue.finish(id: id, at: start))
        XCTAssertEqual(recording.byteCount, 8_000)
        XCTAssertEqual(recording.chunks.map(\.count), [6_400, 1_600])
    }

    /// Verifies level evidence and cross-shortcut mode selection remain attached to their segment.
    func testFreezesSpeechAndUpdatedModeAtFinish() throws {
        let queue = BoundedRecordingQueue()
        let id = try queue.start(mode: .direct, target: nil, at: start).get()
        var replacement = ProcessingMode.direct
        replacement.name = "Buffered test mode"
        XCTAssertTrue(queue.switchActiveMode(to: replacement))
        queue.markSpeech(for: id - 100)
        queue.markSpeech(for: id)
        let recording = try XCTUnwrap(queue.finish(id: id, at: start))
        XCTAssertEqual(recording.mode.name, "Buffered test mode")
        XCTAssertTrue(recording.speechDetected)
        XCTAssertFalse(queue.switchActiveMode(to: .direct))
    }

    /// Verifies IDs remain distinct across independent queues, even if the first queue empties.
    func testIDsAreUniqueAcrossQueueInstances() throws {
        let first = BoundedRecordingQueue()
        let second = BoundedRecordingQueue()
        let a = try first.start(mode: .direct, target: nil, at: start).get()
        first.cancel(id: a)
        let b = try second.start(mode: .direct, target: nil, at: start).get()
        XCTAssertNotEqual(a, b)
        XCTAssertLessThan(b, 0)
    }

    /// Verifies concurrent callback writes obey the memory bound and preserve exact byte accounting.
    func testConcurrentAppendsStayWithinConfiguredCapacity() throws {
        let queue = BoundedRecordingQueue(configuration: .init(maximumBytes: 6_400))
        let date = start
        let id = try queue.start(mode: .direct, target: nil, at: date).get()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            _ = queue.append(Data(repeating: 1, count: 64), to: id, at: date)
        }
        let recording = try XCTUnwrap(queue.finish(id: id, at: date))
        XCTAssertEqual(recording.byteCount, 6_400)
        XCTAssertEqual(recording.chunks.reduce(0) { $0 + $1.count }, 6_400)
        XCTAssertEqual(queue.snapshot().retainedBytes, 6_400)
    }

    /// Verifies preferences cannot remove hard limits or introduce invalid arithmetic.
    func testConfigurationDefaultsAndHardBounds() throws {
        let defaults = BufferedRecordingMemoryDefaults()
        let configuration = BufferedRecordingConfiguration.load(defaults: defaults)
        XCTAssertEqual(configuration.maximumSegments, 3)
        XCTAssertEqual(configuration.maximumDuration, 120)
        defaults.values["tf_bufferedRecordingMaximumSegments"] = Int.max
        defaults.values["tf_bufferedRecordingMaximumDuration"] = 1_000_000
        defaults.values["tf_bufferedRecordingMaximumBytes"] = Int.max
        let bounded = BufferedRecordingConfiguration.load(defaults: defaults)
        XCTAssertEqual(bounded.maximumSegments, BufferedRecordingConfiguration.hardMaximumSegments)
        XCTAssertEqual(bounded.maximumDuration, BufferedRecordingConfiguration.hardMaximumDuration)
        XCTAssertEqual(bounded.maximumBytes, BufferedRecordingConfiguration.hardMaximumBytes)
        XCTAssertEqual(BufferedRecordingConfiguration(maximumDuration: .nan).maximumDuration, 120)
        XCTAssertEqual(BufferedRecordingConfiguration(maximumBytes: 7).maximumBytes, 6)
    }

    /// Verifies input requires the same process, control and window while optional documents are compared when known.
    func testTargetGuardRejectsChangedOrMissingKnownIdentity() {
        XCTAssertTrue(ConcurrentRecordingTarget.permitsDelivery(
            ownerMatches: true, elementMatches: true, windowMatches: true,
            originalDocument: nil, currentDocument: nil
        ))
        for evidence in [(false, true, true), (true, false, true), (true, true, false)] {
            XCTAssertFalse(ConcurrentRecordingTarget.permitsDelivery(
                ownerMatches: evidence.0, elementMatches: evidence.1, windowMatches: evidence.2,
                originalDocument: nil, currentDocument: nil
            ))
        }
        XCTAssertFalse(ConcurrentRecordingTarget.permitsDelivery(
            ownerMatches: true, elementMatches: true, windowMatches: true,
            originalDocument: "document-a", currentDocument: "document-b"
        ))
        XCTAssertFalse(ConcurrentRecordingTarget.permitsDelivery(
            ownerMatches: true, elementMatches: true, windowMatches: true,
            originalDocument: "document-a", currentDocument: nil
        ))
    }

    /// Verifies invalid wall-clock values cannot create an unbounded active segment.
    func testInvalidDatesFailClosed() throws {
        let queue = BoundedRecordingQueue()
        assertStartFailure(queue.start(mode: .direct, target: nil, at: Date(timeIntervalSince1970: .nan)), equals: .invalidDate)
        let id = try queue.start(mode: .direct, target: nil, at: start).get()
        XCTAssertEqual(queue.append(Data([1, 2]), to: id, at: Date(timeIntervalSince1970: .infinity)), .stopRequired(.durationLimit))
        XCTAssertNil(queue.finish(id: id, at: Date(timeIntervalSince1970: .nan)))
        XCTAssertTrue(queue.cancel(id: id))
    }

    /// Checks an admission failure without requiring its success payload to be thrown.
    ///
    /// Args:
    ///   result: Queue admission outcome.
    ///   expected: Required failure reason.
    private func assertStartFailure(
        _ result: Result<Int, BoundedRecordingQueue.StartFailure>,
        equals expected: BoundedRecordingQueue.StartFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .failure(let actual): XCTAssertEqual(actual, expected, file: file, line: line)
        case .success: XCTFail("Unexpected queue admission", file: file, line: line)
        }
    }
}

/// Preference fake that never writes the user's settings or creates a persistent suite.
private final class BufferedRecordingMemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]

    /// Returns only explicitly supplied in-memory preference values.
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
}
