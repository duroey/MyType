import XCTest
@testable import Type4Me

final class QuietWakeupGateTests: XCTestCase {
    func testQuietCalibrationAndSpikeRejection() {
        var gate = QuietWakeupGate()
        for _ in 0..<150 { XCTAssertFalse(gate.consume(20)) }
        XCTAssertEqual(gate.threshold, 50)
        XCTAssertFalse(gate.consume(10_000))
        for _ in 0..<30 { XCTAssertFalse(gate.consume(20)) }
        for _ in 0..<6 { XCTAssertFalse(gate.consume(110)) }
        XCTAssertTrue(gate.consume(110))
        gate.rearm()
        XCTAssertEqual(gate.threshold, 50)
        XCTAssertFalse(gate.consume(110))
    }

    func testReleaseHysteresisAndScatteredDips() {
        var gate = QuietWakeupEndGate(onsetThreshold: 50, silenceSeconds: 0.8)
        XCTAssertEqual(gate.threshold, 30, accuracy: 0.0001)
        for _ in 0..<100 { XCTAssertFalse(gate.consume(40)) }
        for index in 0..<400 { XCTAssertFalse(gate.consume(index % 20 < 3 ? 10 : 110)) }
        for _ in 0..<30 { XCTAssertFalse(gate.consume(20)) }
        for _ in 0..<5 { XCTAssertFalse(gate.consume(110)) }
        for _ in 0..<43 { XCTAssertFalse(gate.consume(20)) }
        XCTAssertTrue(gate.consume(20))
    }

    func testIndependentCalibrationAndLegacyDefault() {
        var first = QuietWakeupGate()
        for _ in 0..<150 { _ = first.consume(100) }
        XCTAssertEqual(first.threshold, 250)
        let replacement = QuietWakeupGate()
        XCTAssertNil(replacement.threshold)
        XCTAssertEqual(FocusAcousticMode.resolve(nil), .noisy)
        XCTAssertEqual(FocusAcousticMode.resolve("unknown"), .noisy)
        XCTAssertEqual(FocusAcousticMode.quiet.label(english: false), "安静模式")
        XCTAssertEqual(FocusAcousticMode.quiet.label(english: true), "Quiet Mode")
        XCTAssertEqual(FocusAcousticMode.noisy.label(english: false), "嘈杂模式")
    }

    func testSharedDelayControlsRelease() {
        for seconds in [0.1, 0.8, 1.0, 2.0] {
            var gate = QuietWakeupEndGate(onsetThreshold: 50, silenceSeconds: seconds)
            let frames = Int(ceil(seconds * 50))
            for _ in 0..<(frames - 1) { XCTAssertFalse(gate.consume(0)) }
            XCTAssertTrue(gate.consume(0))
        }
    }

    func testSharedCalibrationMatchesAutomaticCalibration() {
        let samples = Array(repeating: Float(20), count: 150)
        let calibrated = QuietWakeupGate.calibratedThreshold(samples: samples)
        var gate = QuietWakeupGate(calibratedThreshold: calibrated)
        XCTAssertEqual(gate.threshold, 50)
        for _ in 0..<5 { XCTAssertFalse(gate.consume(110)) }
        XCTAssertTrue(gate.consume(110))
    }
}
