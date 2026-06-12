import XCTest
@testable import Type4Me

final class GeneralSettingsTabTests: XCTestCase {
    func testEnablingMicKeepAliveDisablesFocusWakeup() {
        let resolved = GeneralSettingsTab.resolvedAudioFeatureSettings(
            micKeepAlive: false,
            focusWakeupEnabled: true,
            changedFeature: .micKeepAlive,
            enabled: true
        )

        XCTAssertTrue(resolved.micKeepAlive)
        XCTAssertFalse(resolved.focusWakeupEnabled)
    }

    func testEnablingFocusWakeupDisablesMicKeepAlive() {
        let resolved = GeneralSettingsTab.resolvedAudioFeatureSettings(
            micKeepAlive: true,
            focusWakeupEnabled: false,
            changedFeature: .focusWakeup,
            enabled: true
        )

        XCTAssertFalse(resolved.micKeepAlive)
        XCTAssertTrue(resolved.focusWakeupEnabled)
    }

    func testDisablingMicKeepAliveDoesNotEnableFocusWakeup() {
        let resolved = GeneralSettingsTab.resolvedAudioFeatureSettings(
            micKeepAlive: true,
            focusWakeupEnabled: false,
            changedFeature: .micKeepAlive,
            enabled: false
        )

        XCTAssertFalse(resolved.micKeepAlive)
        XCTAssertFalse(resolved.focusWakeupEnabled)
    }

    func testDisablingFocusWakeupDoesNotEnableMicKeepAlive() {
        let resolved = GeneralSettingsTab.resolvedAudioFeatureSettings(
            micKeepAlive: false,
            focusWakeupEnabled: true,
            changedFeature: .focusWakeup,
            enabled: false
        )

        XCTAssertFalse(resolved.micKeepAlive)
        XCTAssertFalse(resolved.focusWakeupEnabled)
    }
}
