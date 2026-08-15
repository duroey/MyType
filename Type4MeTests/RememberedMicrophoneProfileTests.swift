import XCTest
@testable import Type4Me

final class RememberedMicrophoneProfileTests: XCTestCase {
    func testReplacingProfileKeepsOnlyLatestManualDevice() {
        let defaults = makeDefaults()

        RememberedMicrophoneProfileStore.replace(
            deviceUID: "mic-a",
            focusWakeupEnabled: true,
            defaults: defaults
        )
        RememberedMicrophoneProfileStore.replace(
            deviceUID: "mic-b",
            focusWakeupEnabled: false,
            defaults: defaults
        )

        XCTAssertEqual(
            RememberedMicrophoneProfileStore.load(defaults: defaults),
            RememberedMicrophoneProfile(deviceUID: "mic-b", focusWakeupEnabled: false)
        )
        XCTAssertNil(
            RememberedMicrophoneProfilePolicy.restorableDeviceUID(
                profile: RememberedMicrophoneProfileStore.load(defaults: defaults),
                availableUIDs: ["mic-a"]
            )
        )
    }

    func testDisconnectedProfileDeviceStopsRuntimeWithoutChangingPreference() {
        let profile = RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: true)

        let enabled = RememberedMicrophoneProfilePolicy.effectiveFocusWakeupEnabled(
            profile: profile,
            fallbackEnabled: true,
            availableUIDs: ["mic-b"]
        )

        XCTAssertFalse(enabled)
        XCTAssertTrue(profile.focusWakeupEnabled)
    }

    func testDisconnectedProfileProducesDisabledRuntimeSettingsWithoutChangingPreference() {
        let profile = RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: true)

        let settings = RememberedMicrophoneProfilePolicy.runtimeSettings(
            profile: profile,
            fallbackEnabled: true,
            availableUIDs: ["mic-b"]
        )

        XCTAssertNil(settings.selectedDeviceUID)
        XCTAssertFalse(settings.focusWakeupEnabled)
        XCTAssertTrue(profile.focusWakeupEnabled)
    }

    func testReconnectedProfileProducesSavedRuntimeSettings() {
        let profile = RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: true)

        let settings = RememberedMicrophoneProfilePolicy.runtimeSettings(
            profile: profile,
            fallbackEnabled: false,
            availableUIDs: ["mic-a", "mic-b"]
        )

        XCTAssertEqual(settings.selectedDeviceUID, "mic-a")
        XCTAssertTrue(settings.focusWakeupEnabled)
    }

    func testReconnectedProfileDeviceRestoresEnabledPreference() {
        let profile = RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: true)

        XCTAssertTrue(
            RememberedMicrophoneProfilePolicy.effectiveFocusWakeupEnabled(
                profile: profile,
                fallbackEnabled: false,
                availableUIDs: ["mic-a", "mic-b"]
            )
        )
        XCTAssertEqual(
            RememberedMicrophoneProfilePolicy.restorableDeviceUID(
                profile: profile,
                availableUIDs: ["mic-a", "mic-b"]
            ),
            "mic-a"
        )
    }

    func testDisabledProfileStaysDisabledAfterReconnect() {
        let profile = RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: false)

        XCTAssertFalse(
            RememberedMicrophoneProfilePolicy.effectiveFocusWakeupEnabled(
                profile: profile,
                fallbackEnabled: true,
                availableUIDs: ["mic-a"]
            )
        )
    }

    func testFocusSettingUpdatesRememberedProfile() {
        let defaults = makeDefaults()
        RememberedMicrophoneProfileStore.replace(
            deviceUID: "mic-a",
            focusWakeupEnabled: true,
            defaults: defaults
        )

        RememberedMicrophoneProfileStore.updateFocusWakeupEnabled(false, defaults: defaults)

        XCTAssertEqual(
            RememberedMicrophoneProfileStore.load(defaults: defaults),
            RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: false)
        )
    }

    func testLegacySelectionMigratesIntoSingleProfile() {
        let defaults = makeDefaults()

        let profile = RememberedMicrophoneProfileStore.migrateIfNeeded(
            selectedUID: "",
            lastUserSelectedUID: "mic-a",
            focusWakeupEnabled: true,
            defaults: defaults
        )

        XCTAssertEqual(
            profile,
            RememberedMicrophoneProfile(deviceUID: "mic-a", focusWakeupEnabled: true)
        )
        XCTAssertEqual(RememberedMicrophoneProfileStore.load(defaults: defaults), profile)
    }

    func testSystemDefaultSelectionClearsRememberedProfile() {
        let defaults = makeDefaults()
        RememberedMicrophoneProfileStore.replace(
            deviceUID: "mic-a",
            focusWakeupEnabled: true,
            defaults: defaults
        )

        RememberedMicrophoneProfileStore.clear(defaults: defaults)

        XCTAssertNil(RememberedMicrophoneProfileStore.load(defaults: defaults))
        XCTAssertTrue(
            RememberedMicrophoneProfilePolicy.effectiveFocusWakeupEnabled(
                profile: nil,
                fallbackEnabled: true,
                availableUIDs: []
            )
        )
    }

    /// Creates an isolated defaults suite for profile persistence tests.
    ///
    /// Returns:
    ///   An empty UserDefaults store unique to the current test.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "RememberedMicrophoneProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
