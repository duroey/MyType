import XCTest
@testable import Type4Me

final class GeneralSettingsTabTests: XCTestCase {
    /// Guards the UI boundary without opening hardware or changing real preferences.
    ///
    /// Direct keep-alive calls bypass the app-owned wait for Focus microphone release.
    func testSettingsCannotBypassCoordinatedMicrophoneHandoff() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/UI/Settings/GeneralSettingsTab.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("AudioKeepAliveManager."),
            "Settings must notify the app coordinator so Focus releases the microphone first."
        )
    }

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
