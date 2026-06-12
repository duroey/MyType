import XCTest
@testable import Type4Me

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testInitialStateIsIdle() async {
        let session = RecognitionSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = RecognitionSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = RecognitionSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForSoniox() async {
        KeychainService.selectedASRProvider = .soniox
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testShouldAttemptBatchFallbackWhenStreamingErrorWasObserved() {
        let shouldFallback = RecognitionSession.shouldAttemptBatchFallback(
            uploadFailed: false,
            asrTeardownClean: true,
            streamingError: DeepgramASRError.closed(code: 1008, reason: "policy violation")
        )

        XCTAssertTrue(shouldFallback)
    }

    func testAutoStopThresholdUsesCalibratedNoiseThreshold() {
        let snapshot = NoiseFloorSnapshot(
            noiseFloor: 100,
            threshold: 980,
            samples: 100,
            source: "test",
            measuredAt: Date()
        )

        let threshold = RecognitionSession.resolveAutoStopEffectiveThreshold(
            noiseSnapshot: snapshot,
            fallbackThreshold: 500,
            triggerThreshold: nil
        )

        XCTAssertEqual(threshold, 980, accuracy: 0.001)
    }

    func testAutoStopThresholdPrefersFocusTriggerThreshold() {
        let snapshot = NoiseFloorSnapshot(
            noiseFloor: 100,
            threshold: 980,
            samples: 100,
            source: "test",
            measuredAt: Date()
        )

        let threshold = RecognitionSession.resolveAutoStopEffectiveThreshold(
            noiseSnapshot: snapshot,
            fallbackThreshold: 500,
            triggerThreshold: 3_204
        )

        XCTAssertEqual(threshold, 3_204, accuracy: 0.001)
    }

    func testAutoStopThresholdFallsBackBeforeCalibration() {
        let threshold = RecognitionSession.resolveAutoStopEffectiveThreshold(
            noiseSnapshot: nil,
            fallbackThreshold: 500,
            triggerThreshold: nil
        )

        XCTAssertEqual(threshold, 500, accuracy: 0.001)
    }

    func testAutoStopThresholdKeepsMinimumFloor() {
        let snapshot = NoiseFloorSnapshot(
            noiseFloor: 20,
            threshold: 60,
            samples: 100,
            source: "test",
            measuredAt: Date()
        )

        let threshold = RecognitionSession.resolveAutoStopEffectiveThreshold(
            noiseSnapshot: snapshot,
            fallbackThreshold: 500,
            triggerThreshold: nil
        )

        XCTAssertEqual(threshold, 120, accuracy: 0.001)
    }

    func testAutoStopThresholdIsPreservedAfterASRText() {
        let threshold = RecognitionSession.autoStopThresholdAfterASRText(
            currentThreshold: 2_347
        )

        XCTAssertEqual(threshold, 2_347, accuracy: 0.001)
    }
}
