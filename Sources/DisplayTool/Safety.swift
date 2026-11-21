import Foundation

/// Arithmetic that decides which brightness value may reach a monitor.
/// Kept free of hardware access so it can be unit tested.
enum Safety {
    /// Minimum-brightness choices offered in the menu, in percent.
    /// Zero is not offered: a fully dark panel can look dead, and hides the menu on that screen.
    static let minimumPresets = [5, 10, 20, 30]
    static let defaultMinimum = 10

    /// Limits a requested percentage to the range [minimum, 100].
    static func clampedPercent(_ requested: Int, minimum: Int) -> Int {
        min(100, max(minimum, requested))
    }

    /// Converts a percentage into the monitor's own raw scale.
    /// The result is never below the minimum, never above the monitor's maximum, and never zero.
    static func rawValue(percent: Int, minimum: Int, maximum: Int) -> Int {
        let limited = clampedPercent(percent, minimum: minimum)
        let raw = Int((Double(limited) * Double(maximum) / 100).rounded())
        return min(maximum, max(1, raw))
    }

    /// Converts a raw monitor value to a percentage of its maximum.
    static func percent(raw: Int, maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        return min(100, Int((Double(raw) * 100 / Double(maximum)).rounded()))
    }
}

/// User preferences, stored in UserDefaults.
enum Settings {
    private static let minimumKey = "minimumBrightnessPercent"

    /// Lowest brightness the slider may send. Only values from `Safety.minimumPresets` are accepted.
    static var minimumPercent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: minimumKey)
            return Safety.minimumPresets.contains(stored) ? stored : Safety.defaultMinimum
        }
        set {
            UserDefaults.standard.set(newValue, forKey: minimumKey)
        }
    }
}
