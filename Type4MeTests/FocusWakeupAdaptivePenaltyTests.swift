import Foundation
import XCTest
@testable import Type4Me

final class FocusWakeupAdaptivePenaltyTests: XCTestCase {
    private let config = FocusWakeupAdaptivePenalty.Config(
        windowSize: 20,
        falseStartStepDb: 8,
        falseStartBurstStepDb: 6,
        maxPenaltyDb: 24,
        successRecoveryDb: 0.5,
        successRecoveryCount: 5,
        highFalseStartRate: 0.25,
        highFalseStartMinimumSamples: 5
    )

    func testDefaultConfigUsesFeedbackWindowPenalty() {
        let defaults = UserDefaults(suiteName: "FocusWakeupAdaptivePenaltyTests.defaultConfig")!
        defaults.removePersistentDomain(forName: "FocusWakeupAdaptivePenaltyTests.defaultConfig")

        let config = FocusWakeupAdaptivePenalty.Config.load(defaults: defaults)

        XCTAssertEqual(config.windowSize, 20)
        XCTAssertEqual(config.falseStartStepDb, 8, accuracy: 0.001)
        XCTAssertEqual(config.falseStartBurstStepDb, 6, accuracy: 0.001)
        XCTAssertEqual(config.maxPenaltyDb, 24, accuracy: 0.001)
        XCTAssertEqual(config.successRecoveryDb, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.successRecoveryCount, 5)
        XCTAssertEqual(config.highFalseStartRate, 0.25, accuracy: 0.001)
        XCTAssertEqual(config.highFalseStartMinimumSamples, 5)
    }

    func testFalseStartsIncreaseThresholdByDecibelMultiplier() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        XCTAssertEqual(penalty.penaltyDb(at: now), 0, accuracy: 0.001)
        XCTAssertEqual(penalty.effectiveThreshold(baseThreshold: 300, at: now), 300, accuracy: 0.001)

        penalty.registerFalseStart(at: now)

        XCTAssertEqual(penalty.penaltyDb(at: now), 8, accuracy: 0.001)
        XCTAssertEqual(
            penalty.effectiveThreshold(baseThreshold: 300, at: now),
            300 * pow(10, 8.0 / 20.0),
            accuracy: 0.5
        )
    }

    func testHighFalseStartRateAddsBurstPenalty() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        for _ in 0..<4 {
            penalty.registerSuccessfulInput(at: now)
        }
        penalty.registerFalseStart(at: now)
        XCTAssertEqual(penalty.penaltyDb(at: now), 8, accuracy: 0.001)

        penalty.registerFalseStart(at: now)

        XCTAssertEqual(penalty.penaltyDb(at: now), 22, accuracy: 0.001)
    }

    func testFalseStartPenaltyIsCapped() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        for _ in 0..<10 {
            penalty.registerFalseStart(at: now)
        }

        XCTAssertEqual(penalty.penaltyDb(at: now), 24, accuracy: 0.001)
    }

    func testSuccessfulInputRecoversAfterStableRun() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        penalty.registerFalseStart(at: now)
        for _ in 0..<4 {
            penalty.registerSuccessfulInput(at: now)
        }

        XCTAssertEqual(penalty.penaltyDb(at: now), 8, accuracy: 0.001)

        penalty.registerSuccessfulInput(at: now)

        XCTAssertEqual(penalty.penaltyDb(at: now), 7.5, accuracy: 0.001)
    }

    func testPenaltyDoesNotDecayWithTimeAlone() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        penalty.registerFalseStart(at: now)

        XCTAssertEqual(penalty.penaltyDb(at: now.addingTimeInterval(240)), 8, accuracy: 0.001)
    }

    func testResetClearsPenaltyAndFeedbackWindow() {
        let now = Date(timeIntervalSince1970: 0)
        var penalty = FocusWakeupAdaptivePenalty(config: config, now: now)

        penalty.registerFalseStart(at: now)
        penalty.reset()

        XCTAssertEqual(penalty.penaltyDb(at: now), 0, accuracy: 0.001)
        for _ in 0..<5 {
            penalty.registerSuccessfulInput(at: now)
        }
        XCTAssertEqual(penalty.penaltyDb(at: now), 0, accuracy: 0.001)
    }
}
