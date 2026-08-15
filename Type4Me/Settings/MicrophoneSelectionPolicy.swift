import Foundation

enum MicrophoneSelectionPolicy {
    static let reconnectRefreshDelaySeconds = 1.0

    struct Result: Equatable {
        let selectedUID: String
        let lastUserSelectedUID: String
    }

    /// Resolves microphone state after an explicit user selection.
    ///
    /// Args:
    ///   uid: UID selected by the user. An empty string means system default.
    ///
    /// Returns:
    ///   Selected UID plus the persisted last concrete user selection.
    static func userSelected(_ uid: String) -> Result {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            selectedUID: trimmedUID,
            lastUserSelectedUID: trimmedUID
        )
    }

    /// Resolves microphone state after the system input-device list changes.
    ///
    /// Args:
    ///   selectedUID: Currently selected microphone UID. Empty means system default.
    ///   lastUserSelectedUID: Last concrete microphone UID chosen by the user.
    ///   availableUIDs: Current microphone UIDs reported by the system.
    ///
    /// Returns:
    ///   Updated selection. A missing current device falls back to system default
    ///   while keeping memory of the last concrete user choice. If that remembered
    ///   device later reappears while the app is on system default, it is restored.
    static func resolveAfterDeviceRefresh(
        selectedUID: String,
        lastUserSelectedUID: String,
        availableUIDs: [String]
    ) -> Result {
        let available = Set(availableUIDs)
        let selected = selectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remembered = lastUserSelectedUID.trimmingCharacters(in: .whitespacesAndNewlines)

        if !selected.isEmpty, available.contains(selected) {
            return Result(selectedUID: selected, lastUserSelectedUID: remembered)
        }

        if selected.isEmpty, !remembered.isEmpty, available.contains(remembered) {
            return Result(selectedUID: remembered, lastUserSelectedUID: remembered)
        }

        return Result(selectedUID: "", lastUserSelectedUID: remembered)
    }
}
