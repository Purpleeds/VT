import Foundation

extension Double {
    /// Rounded to the nearest whole number for display. `Int(_:)` traps on
    /// NaN and infinity; this returns 0 instead and clamps huge values, so a
    /// bad measurement can never crash a screen.
    nonisolated var roundedInt: Int {
        guard isFinite else { return 0 }
        let value = rounded()
        if value >= 9.2e18 {
            return Int.max
        }
        if value <= -9.2e18 {
            return Int.min
        }
        return Int(value)
    }
}
