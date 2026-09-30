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

    /// Focus wakeup keeps the bar in `.focusWaiting` while a text field has
    /// focus; typed input must still be reachable from there.
    func testManualInputCanBeginWhileFocusWakeupIsWaiting() {
        for phase in [FloatingBarPhase.hidden, .focusWaiting, .done, .error] {
            XCTAssertTrue(AppDelegate.canBeginManualInput(from: phase), "\(phase)")
        }
        for phase in [FloatingBarPhase.preparing, .recording, .processing, .recovering] {
            XCTAssertFalse(AppDelegate.canBeginManualInput(from: phase), "\(phase)")
        }
    }
}
