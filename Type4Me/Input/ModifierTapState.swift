import CoreGraphics

/// Tracks whether a modifier-only hotkey was used as a real tap.
struct ModifierTapState {
    private(set) var targetIsDown = false
    private(set) var isDirty = false

    /// Marks the target modifier as pressed.
    mutating func pressTarget() {
        targetIsDown = true
        isDirty = false
    }

    /// Marks the target modifier as released.
    ///
    /// Returns:
    ///   True when the modifier was pressed and released without any intervening
    ///   non-modifier key, meaning it should fire as a single-key tap.
    mutating func releaseTarget() -> Bool {
        defer {
            targetIsDown = false
            isDirty = false
        }
        return targetIsDown && !isDirty
    }

    /// Marks that a non-modifier key was pressed while the target modifier is down.
    mutating func markNonModifierKeyDown() {
        if targetIsDown {
            isDirty = true
        }
    }

    /// Clears any pending tap state.
    mutating func reset() {
        targetIsDown = false
        isDirty = false
    }
}
