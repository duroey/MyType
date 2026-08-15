import Foundation

enum FocusAutoStopSilenceSetting {
    static let storageKey = "tf_focusAutoStopSilenceSeconds"
    static let defaultSeconds = 1.0
    static let minimumSeconds = 0.1

    private static let legacyFastValues = [0.6, 0.9]
    private static let comparisonTolerance = 0.0001

    /// Normalizes a user-provided silence delay.
    ///
    /// Args:
    ///   value: Raw delay in seconds.
    ///
    /// Returns:
    ///   A usable delay with legacy fast values migrated to the default, a 0.1s
    ///   lower bound, and no upper bound.
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSeconds }
        if legacyFastValues.contains(where: { abs($0 - value) < comparisonTolerance }) {
            return defaultSeconds
        }
        return max(value, minimumSeconds)
    }

    /// Parses editable text into a silence delay.
    ///
    /// Args:
    ///   text: User-entered seconds text.
    ///
    /// Returns:
    ///   A normalized delay, or the default delay when the text is empty or invalid.
    static func parsed(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else {
            return defaultSeconds
        }
        return normalized(value)
    }

    /// Formats a silence delay for display in settings.
    ///
    /// Args:
    ///   value: Raw delay in seconds.
    ///
    /// Returns:
    ///   A one-decimal-place string after normalization.
    static func formatted(_ value: Double) -> String {
        var decimal = Decimal(normalized(value))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 1, .plain)
        return String(format: "%.1f", NSDecimalNumber(decimal: rounded).doubleValue)
    }

    /// Reads the saved silence delay from defaults.
    ///
    /// Args:
    ///   defaults: Defaults store to read from.
    ///
    /// Returns:
    ///   The normalized saved delay, or the default delay when no value exists.
    static func read(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultSeconds
        }
        return normalized(defaults.double(forKey: storageKey))
    }
}
