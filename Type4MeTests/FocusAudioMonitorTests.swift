import XCTest
import os
@testable import Type4Me

@MainActor
final class FocusAudioMonitorTests: XCTestCase {
    /// Verifies that a stuck driver cannot prevent main-actor work or queue more starts.
    func testBlockedStartKeepsMainActorResponsiveAndCoalescesRequests() async {
        let driver = BlockingMonitorDriver()
        driver.blockStart = true
        let monitor = makeMonitor(driver)
        let ready = expectation(description: "ready")
        XCTAssertTrue(monitor.start(deviceUID: "test", onFrame: { _ in }, onReady: {
            ready.fulfill()
        }, onFailure: { _ in XCTFail("unexpected failure") }))
        await fulfillment(of: [driver.startEntered], timeout: 1)

        XCTAssertEqual(monitor.state, .starting)
        XCTAssertFalse(monitor.start(deviceUID: "duplicate", onFrame: { _ in }, onReady: {}, onFailure: { _ in }))
        XCTAssertFalse(driver.startWasOnMainThread)
        driver.releaseStart.signal()
        await fulfillment(of: [ready], timeout: 1)
        monitor.stop()
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
        XCTAssertEqual(driver.starts, 1)
    }

    /// Verifies that cancellation discards late readiness and late frames.
    func testStopDuringStartRejectsLateCallbacksAndSerializesCleanup() async {
        let driver = BlockingMonitorDriver()
        driver.blockStart = true
        let monitor = makeMonitor(driver)
        XCTAssertTrue(monitor.start(deviceUID: nil, onFrame: { _ in
            XCTFail("cancelled capture delivered audio")
        }, onReady: {
            XCTFail("cancelled capture became ready")
        }, onFailure: { _ in XCTFail("unexpected failure") }))
        await fulfillment(of: [driver.startEntered], timeout: 1)
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(monitor.state, .stopping)
        XCTAssertEqual(driver.stops, 0)
        driver.releaseStart.signal()
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertFalse(driver.stopWasOnMainThread)
        XCTAssertEqual(monitor.state, .idle)
    }

    /// Verifies that a timed-out start stays suspended until cleanup and explicit retry.
    func testStartTimeoutDoesNotRetryOrAcceptLateSuccess() async {
        let driver = BlockingMonitorDriver()
        driver.blockStart = true
        let monitor = makeMonitor(driver, timeout: 0.05)
        let failed = expectation(description: "timeout")
        monitor.start(deviceUID: nil, onFrame: { _ in XCTFail("late frame") }, onReady: {
            XCTFail("late ready")
        }, onFailure: { error in
            XCTAssertEqual(error as? FocusAudioMonitor.Failure, .startTimedOut)
            failed.fulfill()
        })
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(monitor.state, .failed)
        XCTAssertFalse(monitor.resetFailure())
        XCTAssertFalse(monitor.start(deviceUID: nil, onFrame: { _ in }, onReady: {}, onFailure: { _ in }))
        let stillBusy = await monitor.waitUntilStopped()
        XCTAssertFalse(stillBusy)
        driver.releaseStart.signal()
        await fulfillment(of: [driver.stopEntered], timeout: 1)
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
        XCTAssertEqual(monitor.state, .failed)
        XCTAssertTrue(monitor.resetFailure())
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(driver.starts, 1)
    }

    /// Verifies that a stuck stop cannot strand the UI or allow microphone handoff.
    func testStopTimeoutKeepsMainActorResponsiveAndBlocksHandoff() async {
        let driver = BlockingMonitorDriver()
        driver.blockStop = true
        let monitor = makeMonitor(driver, timeout: 0.05)
        let ready = expectation(description: "ready")
        let failed = expectation(description: "stop timeout")
        monitor.start(deviceUID: nil, onFrame: { _ in }, onReady: { ready.fulfill() }, onFailure: { error in
            XCTAssertEqual(error as? FocusAudioMonitor.Failure, .stopTimedOut)
            failed.fulfill()
        })
        await fulfillment(of: [ready], timeout: 1)
        monitor.stop()
        await fulfillment(of: [driver.stopEntered, failed], timeout: 1)
        XCTAssertEqual(monitor.state, .failed)
        XCTAssertFalse(driver.stopWasOnMainThread)
        let stillBusy = await monitor.waitUntilStopped()
        XCTAssertFalse(stillBusy)
        driver.releaseStop.signal()
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
        XCTAssertEqual(monitor.state, .failed)
    }

    /// Verifies cleanup of partially initialized hardware after a driver exception.
    func testDriverFailureCleansUpAndRemainsSuspended() async {
        let driver = BlockingMonitorDriver()
        driver.failStart = true
        let monitor = makeMonitor(driver)
        let failed = expectation(description: "driver failure")
        monitor.start(deviceUID: nil, onFrame: { _ in XCTFail("failed frame") }, onReady: {
            XCTFail("failed ready")
        }, onFailure: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 1)
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(monitor.state, .failed)
    }

    /// Verifies that cancellation cannot accidentally authorize a pending handoff.
    func testCancelledReleaseWaitReturnsFalse() async {
        let driver = BlockingMonitorDriver()
        driver.blockStart = true
        let monitor = makeMonitor(driver)
        monitor.start(deviceUID: nil, onFrame: { _ in }, onReady: {}, onFailure: { _ in })
        await fulfillment(of: [driver.startEntered], timeout: 1)
        monitor.stop()
        let waiter = Task { await monitor.waitUntilStopped() }
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertFalse(cancelled)
        driver.releaseStart.signal()
        let released = await monitor.waitUntilStopped()
        XCTAssertTrue(released)
    }

    /// Verifies that calibration never opens a second microphone while Focus owns it.
    func testCalibrationHonorsFailedFocusHandoffBeforeOpeningHardware() async {
        let previous = NoiseFloorCalibrator.waitForFocusAudioRelease
        defer { NoiseFloorCalibrator.waitForFocusAudioRelease = previous }
        NoiseFloorCalibrator.waitForFocusAudioRelease = { false }
        let result = await NoiseFloorCalibrator.calibrate(duration: 0, minSamples: 0, source: "handoff-test")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.samples, 0)
        XCTAssertNotNil(result.error)
    }

    /// Verifies that the UI's existing recording-start error remains bilingual.
    func testFailurePresentationUsesExistingLocalizedRecordingError() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "tf_language")
        defer {
            if let previous { defaults.set(previous, forKey: "tf_language") }
            else { defaults.removeObject(forKey: "tf_language") }
        }
        defaults.set("zh", forKey: "tf_language")
        XCTAssertEqual(AudioCaptureError.converterCreationFailed.localizedDescription, "录音启动失败")
        defaults.set("en", forKey: "tf_language")
        XCTAssertEqual(AudioCaptureError.converterCreationFailed.localizedDescription, "Failed to start recording")
    }

    /// Verifies that a new capture accepts current frames but rejects the old producer.
    func testRestartDeliversCurrentAudioAndRejectsOldGeneration() async {
        let producers = OSAllocatedUnfairLock(initialState: [FocusAudioMonitor.FrameHandler]())
        let monitor = FocusAudioMonitor(
            configuration: .init(operationTimeout: 1),
            startCapture: { _, onFrame in producers.withLock { $0.append(onFrame) } },
            stopCapture: {}
        )
        var frames: [Data] = []
        let firstReady = expectation(description: "first ready")
        let firstFrame = expectation(description: "first frame")
        monitor.start(deviceUID: nil, onFrame: {
            frames.append($0)
            firstFrame.fulfill()
        }, onReady: { firstReady.fulfill() }, onFailure: { _ in XCTFail("failure") })
        await fulfillment(of: [firstReady], timeout: 1)
        let oldProducer = producers.withLock { $0[0] }
        oldProducer(Data([1]))
        await fulfillment(of: [firstFrame], timeout: 1)
        monitor.stop()
        let firstReleased = await monitor.waitUntilStopped()
        XCTAssertTrue(firstReleased)

        let secondReady = expectation(description: "second ready")
        let secondFrame = expectation(description: "second frame")
        monitor.start(deviceUID: "replacement", onFrame: {
            frames.append($0)
            secondFrame.fulfill()
        }, onReady: { secondReady.fulfill() }, onFailure: { _ in XCTFail("failure") })
        await fulfillment(of: [secondReady], timeout: 1)
        oldProducer(Data([99]))
        let currentProducer = producers.withLock { $0[1] }
        currentProducer(Data([2]))
        await fulfillment(of: [secondFrame], timeout: 1)
        monitor.stop()
        let secondReleased = await monitor.waitUntilStopped()
        XCTAssertTrue(secondReleased)
        XCTAssertEqual(frames, [Data([1]), Data([2])])
    }

    /// Verifies that invalid or excessive diagnostic tuning cannot create unbounded waits.
    func testDeadlineConfigurationIsBounded() {
        let suite = "FocusAudioMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FocusAudioMonitor.Configuration.load(defaults: defaults).operationTimeout, 5)
        defaults.set(-1, forKey: "tf_focusAudioOperationTimeout")
        XCTAssertEqual(FocusAudioMonitor.Configuration.load(defaults: defaults).operationTimeout, 5)
        defaults.set(500, forKey: "tf_focusAudioOperationTimeout")
        XCTAssertEqual(FocusAudioMonitor.Configuration.load(defaults: defaults).operationTimeout, 30)
    }

    /// Builds a monitor with fake capture operations and a bounded test deadline.
    ///
    /// Args:
    ///   driver: Fake hardware controlled by the test.
    ///   timeout: Deadline for one lifecycle operation, in seconds.
    ///
    /// Returns:
    ///   A monitor that never accesses a real microphone.
    private func makeMonitor(_ driver: BlockingMonitorDriver, timeout: TimeInterval = 1) -> FocusAudioMonitor {
        FocusAudioMonitor(
            configuration: .init(operationTimeout: timeout),
            startCapture: { _, onFrame in try driver.start(onFrame: onFrame) },
            stopCapture: { driver.stop() }
        )
    }
}

private final class BlockingMonitorDriver: @unchecked Sendable {
    private struct Snapshot {
        var starts = 0
        var stops = 0
        var startWasOnMainThread = false
        var stopWasOnMainThread = false
    }

    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())
    let startEntered = XCTestExpectation(description: "driver entered start")
    let stopEntered = XCTestExpectation(description: "driver entered stop")
    let releaseStart = DispatchSemaphore(value: 0)
    let releaseStop = DispatchSemaphore(value: 0)
    var blockStart = false
    var blockStop = false
    var failStart = false
    var starts: Int { snapshot.withLock { $0.starts } }
    var stops: Int { snapshot.withLock { $0.stops } }
    var startWasOnMainThread: Bool { snapshot.withLock { $0.startWasOnMainThread } }
    var stopWasOnMainThread: Bool { snapshot.withLock { $0.stopWasOnMainThread } }

    /// Simulates synchronous hardware startup, optionally waiting or throwing.
    ///
    /// Args:
    ///   onFrame: Callback exercised after startup, including cancelled startups.
    func start(onFrame: @escaping @Sendable (Data) -> Void) throws {
        snapshot.withLock {
            $0.starts += 1
            $0.startWasOnMainThread = Thread.isMainThread
        }
        startEntered.fulfill()
        if blockStart { _ = releaseStart.wait(timeout: .now() + 2) }
        if failStart { throw AudioCaptureError.noInputDevice }
        onFrame(Data([1, 2]))
    }

    /// Simulates synchronous hardware teardown with an optional bounded wait.
    func stop() {
        snapshot.withLock {
            $0.stops += 1
            $0.stopWasOnMainThread = Thread.isMainThread
        }
        stopEntered.fulfill()
        if blockStop { _ = releaseStop.wait(timeout: .now() + 2) }
    }
}
