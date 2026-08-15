import Foundation

struct RememberedMicrophoneProfile: Codable, Equatable, Sendable {
    let deviceUID: String
    var focusWakeupEnabled: Bool
}

struct RememberedMicrophoneRuntimeSettings: Equatable, Sendable {
    let selectedDeviceUID: String?
    let focusWakeupEnabled: Bool
}

enum RememberedMicrophoneProfileStore {
    static let storageKey = "tf_rememberedMicrophoneProfile"

    /// Loads the single profile associated with the last manually selected microphone.
    ///
    /// Args:
    ///   defaults: User defaults store containing the encoded profile.
    ///
    /// Returns:
    ///   The remembered microphone profile, or nil when no explicit device is remembered.
    static func load(defaults: UserDefaults = .standard) -> RememberedMicrophoneProfile? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(RememberedMicrophoneProfile.self, from: data)
        } catch {
            DebugFileLogger.log("remembered microphone profile decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Replaces the remembered profile with a newly selected microphone.
    ///
    /// Args:
    ///   deviceUID: Unique identifier of the microphone selected by the user.
    ///   focusWakeupEnabled: User preference to save for that microphone.
    ///   defaults: User defaults store receiving the encoded profile.
    ///
    /// Returns:
    ///   The stored profile, or nil when the device UID is empty or encoding fails.
    @discardableResult
    static func replace(
        deviceUID: String,
        focusWakeupEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> RememberedMicrophoneProfile? {
        let normalizedUID = deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty else {
            clear(defaults: defaults)
            return nil
        }

        let profile = RememberedMicrophoneProfile(
            deviceUID: normalizedUID,
            focusWakeupEnabled: focusWakeupEnabled
        )
        do {
            defaults.set(try JSONEncoder().encode(profile), forKey: storageKey)
            return profile
        } catch {
            DebugFileLogger.log("remembered microphone profile encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Updates the Auto Focus preference in the currently remembered profile.
    ///
    /// Args:
    ///   enabled: New user preference for Auto Focus.
    ///   defaults: User defaults store containing the profile.
    static func updateFocusWakeupEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard let profile = load(defaults: defaults) else { return }
        replace(
            deviceUID: profile.deviceUID,
            focusWakeupEnabled: enabled,
            defaults: defaults
        )
    }

    /// Creates the single profile from the legacy microphone settings when needed.
    ///
    /// Args:
    ///   selectedUID: Currently selected microphone UID.
    ///   lastUserSelectedUID: Last concrete microphone UID selected by the user.
    ///   focusWakeupEnabled: Existing global Auto Focus preference to migrate.
    ///   defaults: User defaults store receiving the migrated profile.
    ///
    /// Returns:
    ///   The existing or newly migrated profile, or nil for system-default selection.
    @discardableResult
    static func migrateIfNeeded(
        selectedUID: String,
        lastUserSelectedUID: String,
        focusWakeupEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> RememberedMicrophoneProfile? {
        if let profile = load(defaults: defaults) {
            return profile
        }

        let rememberedUID = lastUserSelectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceUID = rememberedUID.isEmpty ? selected : rememberedUID
        guard !deviceUID.isEmpty else { return nil }
        return replace(
            deviceUID: deviceUID,
            focusWakeupEnabled: focusWakeupEnabled,
            defaults: defaults
        )
    }

    /// Removes the remembered explicit-device profile.
    ///
    /// Args:
    ///   defaults: User defaults store from which the profile is removed.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

enum RememberedMicrophoneProfilePolicy {
    /// Resolves the live settings after reconciling the remembered microphone.
    ///
    /// Args:
    ///   profile: Single profile for the last manually selected microphone.
    ///   fallbackEnabled: Current Auto Focus setting when no profile exists.
    ///   availableUIDs: Microphone UIDs currently reported by the operating system.
    ///
    /// Returns:
    ///   Live device selection and Auto Focus setting. A missing remembered
    ///   device produces system-default selection with Auto Focus disabled.
    static func runtimeSettings(
        profile: RememberedMicrophoneProfile?,
        fallbackEnabled: Bool,
        availableUIDs: [String]
    ) -> RememberedMicrophoneRuntimeSettings {
        guard let profile else {
            return RememberedMicrophoneRuntimeSettings(
                selectedDeviceUID: nil,
                focusWakeupEnabled: fallbackEnabled
            )
        }

        let selectedDeviceUID = restorableDeviceUID(
            profile: profile,
            availableUIDs: availableUIDs
        )
        return RememberedMicrophoneRuntimeSettings(
            selectedDeviceUID: selectedDeviceUID,
            focusWakeupEnabled: selectedDeviceUID == nil ? false : profile.focusWakeupEnabled
        )
    }

    /// Resolves whether Auto Focus may run for the currently remembered microphone.
    ///
    /// Args:
    ///   profile: Single profile for the last manually selected microphone.
    ///   fallbackEnabled: Global preference used when the user selected system default.
    ///   availableUIDs: Microphone UIDs currently reported by the operating system.
    ///
    /// Returns:
    ///   True when the saved preference is enabled and its device is available.
    static func effectiveFocusWakeupEnabled(
        profile: RememberedMicrophoneProfile?,
        fallbackEnabled: Bool,
        availableUIDs: [String]
    ) -> Bool {
        guard let profile else { return fallbackEnabled }
        return profile.focusWakeupEnabled && Set(availableUIDs).contains(profile.deviceUID)
    }

    /// Resolves the remembered device that can be restored after reconnecting.
    ///
    /// Args:
    ///   profile: Single profile for the last manually selected microphone.
    ///   availableUIDs: Microphone UIDs currently reported by the operating system.
    ///
    /// Returns:
    ///   The remembered device UID when it is available, otherwise nil.
    static func restorableDeviceUID(
        profile: RememberedMicrophoneProfile?,
        availableUIDs: [String]
    ) -> String? {
        guard let profile, Set(availableUIDs).contains(profile.deviceUID) else { return nil }
        return profile.deviceUID
    }
}

extension Notification.Name {
    static let rememberedMicrophoneProfileDidChange = Notification.Name(
        "MyTypeRememberedMicrophoneProfileDidChange"
    )
}
