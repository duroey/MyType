import XCTest
@testable import Type4Me

final class AppStartupPolicyTests: XCTestCase {
    func testStartupNoiseCalibrationFollowsFocusWakeupSetting() {
        let suiteName = "AppStartupPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertTrue(AppDelegate.shouldCalibrateNoiseFloorAtStartup(defaults: defaults))

        defaults.set(false, forKey: "tf_focusWakeupEnabled")
        XCTAssertFalse(AppDelegate.shouldCalibrateNoiseFloorAtStartup(defaults: defaults))

        defaults.set(true, forKey: "tf_focusWakeupEnabled")
        XCTAssertTrue(AppDelegate.shouldCalibrateNoiseFloorAtStartup(defaults: defaults))
    }
}
