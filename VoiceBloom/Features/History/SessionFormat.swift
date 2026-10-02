import Foundation

/// Text for saved statistics (shared by History, detail and check-in screens).
nonisolated enum SessionFormat {
    /// e.g. "45 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let total = max(0, seconds.roundedInt)
        if total < 60 {
            return "\(total) s"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(remainder) min"
    }

    /// e.g. "45 seconds", "12 minutes" (VoiceOver).
    static func spokenDuration(_ seconds: Double) -> String {
        let total = max(0, seconds.roundedInt)
        if total < 60 {
            return total == 1 ? "1 second" : "\(total) seconds"
        }
        let minutes = total / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func hertz(_ frequency: Double) -> String {
        "\(frequency.roundedInt) Hz"
    }

    static func percent(_ value: Double) -> String {
        "\(value.roundedInt)%"
    }

    /// A 0–100 score, e.g. "62".
    static func score(_ value: Double?) -> String {
        value.map { "\($0.roundedInt)" } ?? "—"
    }

    static func range(low: Double?, high: Double?) -> String {
        guard let low, let high else { return "—" }
        return "\(low.roundedInt)–\(high.roundedInt) Hz"
    }

    /// e.g. "0.62%", for jitter and shimmer.
    static func precisePercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f%%", value)
    }

    static func decibels(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }
}
