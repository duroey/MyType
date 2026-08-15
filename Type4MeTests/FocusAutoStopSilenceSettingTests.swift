import XCTest
@testable import Type4Me

final class FocusAutoStopSilenceSettingTests: XCTestCase {
    func testDefaultDelayIsOneSecond() {
        XCTAssertEqual(FocusAutoStopSilenceSetting.defaultSeconds, 1.0, accuracy: 0.001)
    }

    func testLegacyFastOptionsNormalizeToOneSecond() {
        XCTAssertEqual(FocusAutoStopSilenceSetting.normalized(0.6), 1.0, accuracy: 0.001)
        XCTAssertEqual(FocusAutoStopSilenceSetting.normalized(0.9), 1.0, accuracy: 0.001)
    }

    func testDelayHasMinimumButNoUpperLimit() {
        XCTAssertEqual(FocusAutoStopSilenceSetting.normalized(0.05), 0.1, accuracy: 0.001)
        XCTAssertEqual(FocusAutoStopSilenceSetting.normalized(12.3), 12.3, accuracy: 0.001)
    }

    func testTextInputParsesOneDecimalDelay() {
        XCTAssertEqual(FocusAutoStopSilenceSetting.parsed("1.4"), 1.4, accuracy: 0.001)
        XCTAssertEqual(FocusAutoStopSilenceSetting.parsed("abc"), 1.0, accuracy: 0.001)
    }

    func testDelayFormatsAsOneDecimalPlace() {
        XCTAssertEqual(FocusAutoStopSilenceSetting.formatted(1.24), "1.2")
        XCTAssertEqual(FocusAutoStopSilenceSetting.formatted(1.25), "1.3")
    }

    func testReadNormalizesStoredDefaults() {
        let suiteName = "FocusAutoStopSilenceSettingTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(FocusAutoStopSilenceSetting.read(from: suite), 1.0, accuracy: 0.001)

        suite.set(0.9, forKey: FocusAutoStopSilenceSetting.storageKey)
        XCTAssertEqual(FocusAutoStopSilenceSetting.read(from: suite), 1.0, accuracy: 0.001)

        suite.set(9.7, forKey: FocusAutoStopSilenceSetting.storageKey)
        XCTAssertEqual(FocusAutoStopSilenceSetting.read(from: suite), 9.7, accuracy: 0.001)
    }
}
