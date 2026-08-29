import XCTest
@testable import Type4Me

final class FocusWakeupControllerTests: XCTestCase {
    func testExternalAudioHandoffCapacityCoversSharedStartWait() {
        let configuredSafetyFrames = 25
        let capacity = FocusExternalAudioHandoffCapacityPolicy.frameCapacity(
            preRollFrames: configuredSafetyFrames
        )
        let expectedWaitFrames = Int(ceil(
            FocusExternalAudioHandoffCapacityPolicy.sharedRecordingStartWaitSeconds
                * 1_000
                / Double(AudioCaptureEngine.frameDurationMs)
        ))

        XCTAssertEqual(capacity, expectedWaitFrames + configuredSafetyFrames)
        XCTAssertGreaterThanOrEqual(
            Double(capacity * AudioCaptureEngine.frameDurationMs) / 1_000,
            FocusExternalAudioHandoffCapacityPolicy.sharedRecordingStartWaitSeconds
        )
    }

    func testExternalAudioHandoffCapacityAddsConfiguredSafetyMargin() {
        let capacity = FocusExternalAudioHandoffCapacityPolicy.frameCapacity(
            preRollFrames: 200,
            startWaitSeconds: 3,
            frameDurationMs: 20
        )

        XCTAssertEqual(capacity, 350)
    }

    func testExternalAudioHandoffCapacityRoundsUpPartialFrame() {
        let capacity = FocusExternalAudioHandoffCapacityPolicy.frameCapacity(
            preRollFrames: 0,
            startWaitSeconds: 0.101,
            frameDurationMs: 20
        )

        XCTAssertEqual(capacity, 6)
    }

    func testExternalAudioHandoffBuffersThenSwitchesToDirectDelivery() {
        var handoff = FocusExternalAudioHandoffBuffer()
        let first = Data([1])
        let second = Data([2])
        let direct = Data([3])

        handoff.beginBuffering(maxBufferedFrames: 3)

        XCTAssertEqual(handoff.route(first), .buffered)
        XCTAssertEqual(handoff.route(second), .buffered)
        let generation = handoff.claimDirectDelivery()
        XCTAssertEqual(handoff.route(direct), .queuedForDirectDelivery)
        XCTAssertEqual(handoff.phase, .direct)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation!), first)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation!), second)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation!), direct)
        XCTAssertNil(handoff.takeNextDeliveryFrame(ownerGeneration: generation!))
    }

    func testExternalAudioHandoffQueuesFramesAfterAtomicClaimExactlyOnce() {
        var handoff = FocusExternalAudioHandoffBuffer()
        let beforeClaim = Data([1])
        let afterClaim = Data([2])
        let nextLiveFrame = Data([3])

        handoff.beginBuffering(maxBufferedFrames: 3)
        XCTAssertEqual(handoff.route(beforeClaim), .buffered)
        let generation = handoff.claimDirectDelivery()!
        XCTAssertEqual(handoff.route(afterClaim), .queuedForDirectDelivery)
        XCTAssertEqual(handoff.route(nextLiveFrame), .queuedForDirectDelivery)

        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation), beforeClaim)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation), afterClaim)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation), nextLiveFrame)
        XCTAssertNil(handoff.takeNextDeliveryFrame(ownerGeneration: generation))
    }

    func testExternalAudioHandoffUsesConfiguredFrameLimit() {
        var handoff = FocusExternalAudioHandoffBuffer()
        let dropped = Data([1])
        let retainedFirst = Data([2])
        let retainedSecond = Data([3])

        handoff.beginBuffering(maxBufferedFrames: 2)
        XCTAssertEqual(handoff.route(dropped), .buffered)
        XCTAssertEqual(handoff.route(retainedFirst), .buffered)
        XCTAssertEqual(handoff.route(retainedSecond), .buffered)

        let generation = handoff.claimDirectDelivery()!
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation), retainedFirst)
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: generation), retainedSecond)
        XCTAssertNil(handoff.takeNextDeliveryFrame(ownerGeneration: generation))
    }

    func testExternalAudioHandoffResetInvalidatesOldDeliveryGeneration() {
        var handoff = FocusExternalAudioHandoffBuffer()
        handoff.beginBuffering(maxBufferedFrames: 2)
        XCTAssertEqual(handoff.route(Data([1])), .buffered)
        let oldGeneration = handoff.claimDirectDelivery()!

        handoff.reset()
        handoff.beginBuffering(maxBufferedFrames: 2)
        XCTAssertEqual(handoff.route(Data([2])), .buffered)
        let newGeneration = handoff.claimDirectDelivery()!

        XCTAssertTrue(handoff.bufferedFrames.isEmpty)
        XCTAssertNil(handoff.takeNextDeliveryFrame(ownerGeneration: oldGeneration))
        XCTAssertEqual(handoff.takeNextDeliveryFrame(ownerGeneration: newGeneration), Data([2]))
    }

    func testShouldRestoreFocusWaitingWhenMonitorIsRunningAndPanelHidden() {
        let now = Date(timeIntervalSinceReferenceDate: 100)

        let shouldRestore = FocusWakeupController.shouldRestoreFocusWaitingUI(
            isMonitoringAudio: true,
            isFocusRecording: false,
            isManualRecordingPaused: false,
            isStartGatePausedByEscape: false,
            hasCurrentFocus: true,
            rearmBlockedUntil: Date(timeIntervalSinceReferenceDate: 99),
            now: now,
            barPhase: .hidden
        )

        XCTAssertTrue(shouldRestore)
    }

    func testShouldReopenWhenMonitorStartedButNoFramesArrived() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 101.2)

        let shouldReopen = FocusWakeupController.shouldReopenAudioMonitor(
            isMonitoringAudio: true,
            noFrameReopen: 1.0,
            lastFrameAt: nil,
            monitorStartedAt: startedAt,
            now: now
        )

        XCTAssertTrue(shouldReopen)
    }

    func testShouldNotReopenBeforeNoFrameTimeout() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 100.5)

        let shouldReopen = FocusWakeupController.shouldReopenAudioMonitor(
            isMonitoringAudio: true,
            noFrameReopen: 1.0,
            lastFrameAt: nil,
            monitorStartedAt: startedAt,
            now: now
        )

        XCTAssertFalse(shouldReopen)
    }

    func testShouldReopenFromLastFrameTimestampWhenFramesPreviouslyArrived() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let lastFrameAt = Date(timeIntervalSinceReferenceDate: 102)
        let now = Date(timeIntervalSinceReferenceDate: 103.1)

        let shouldReopen = FocusWakeupController.shouldReopenAudioMonitor(
            isMonitoringAudio: true,
            noFrameReopen: 1.0,
            lastFrameAt: lastFrameAt,
            monitorStartedAt: startedAt,
            now: now
        )

        XCTAssertTrue(shouldReopen)
    }

    func testSpeechProfileGentlyLiftsStartThreshold() {
        let threshold = FocusWakeupController.speechProfileStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: 10_500,
            minGap: 200,
            blend: 0.25
        )

        XCTAssertEqual(threshold, 3_000)
    }

    func testSpeechProfileIsIgnoredWhenTooCloseToNoise() {
        let threshold = FocusWakeupController.speechProfileStartThreshold(
            noiseThreshold: 1_000,
            speechLowRMS: 1_100,
            minGap: 200,
            blend: 0.25
        )

        XCTAssertEqual(threshold, 1_000)
    }

    func testSpeechProfileBlendCanBeConfigured() {
        let threshold = FocusWakeupController.speechProfileStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: 10_500,
            minGap: 200,
            blend: 0.35
        )

        XCTAssertEqual(threshold, 4_000)
    }

    func testSpeechProfileThresholdFallsBackToNoiseWithoutProfile() {
        let threshold = FocusWakeupController.speechProfileStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: nil,
            minGap: 200,
            blend: 0.35
        )

        XCTAssertEqual(threshold, 500)
    }

    func testFalseStartProfileMovesThresholdAboveLearnedNoise() {
        let threshold = FocusWakeupController.learnedStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: 10_500,
            falseStartHighRMS: 4_200,
            minGap: 200,
            blend: 0.25,
            falseStartMargin: 200,
            falseStartCapBlend: 0.6,
            coldStartCapMultiplier: 2
        )

        XCTAssertEqual(threshold, 4_400)
    }

    func testFalseStartProfileCannotCrossSpeechSideCap() {
        let threshold = FocusWakeupController.learnedStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: 10_500,
            falseStartHighRMS: 9_000,
            minGap: 200,
            blend: 0.25,
            falseStartMargin: 200,
            falseStartCapBlend: 0.6,
            coldStartCapMultiplier: 2
        )

        XCTAssertEqual(threshold, 6_500)
    }

    func testFalseStartProfileIsCappedDuringColdStart() {
        let threshold = FocusWakeupController.learnedStartThreshold(
            noiseThreshold: 500,
            speechLowRMS: nil,
            falseStartHighRMS: 2_000,
            minGap: 200,
            blend: 0.25,
            falseStartMargin: 200,
            falseStartCapBlend: 0.6,
            coldStartCapMultiplier: 2
        )

        XCTAssertEqual(threshold, 1_000)
    }

    func testFocusWakeupDefaultsToVoicePolishMode() {
        let mode = FocusWakeupController.resolvedFocusWakeupMode(
            modes: ProcessingMode.defaults,
            storedModeId: nil,
            provider: .volcano
        )

        XCTAssertEqual(mode.id, ProcessingMode.formalWritingId)
    }

    func testFocusWakeupUsesStoredTextMode() {
        let mode = FocusWakeupController.resolvedFocusWakeupMode(
            modes: ProcessingMode.defaults,
            storedModeId: ProcessingMode.promptOptimizeId.uuidString,
            provider: .volcano
        )

        XCTAssertEqual(mode.id, ProcessingMode.promptOptimizeId)
    }

    func testFocusWakeupRejectsAgentRouterMode() {
        let mode = FocusWakeupController.resolvedFocusWakeupMode(
            modes: ProcessingMode.defaults,
            storedModeId: ProcessingMode.agentRouterModeId.uuidString,
            provider: .volcano
        )

        XCTAssertEqual(mode.id, ProcessingMode.formalWritingId)
    }

    func testFocusWakeupFallsBackToDirectWhenVoicePolishIsMissing() {
        let mode = FocusWakeupController.resolvedFocusWakeupMode(
            modes: [.direct],
            storedModeId: nil,
            provider: .volcano
        )

        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

}
