import XCTest
@testable import Type4Me

final class NoiseFloorCalibratorStatsTests: XCTestCase {
    func testNoisyCalibrationUsesHighPercentileInsteadOfMedianOnly() {
        let samples = Array(repeating: Float(100), count: 90)
            + Array(repeating: Float(900), count: 10)

        let result = NoiseFloorCalibrator.calibrationStatistics(for: samples)

        XCTAssertEqual(result.noiseFloor, 100, accuracy: 0.001)
        XCTAssertEqual(result.threshold, 980, accuracy: 0.001)
    }
}
