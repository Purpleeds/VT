import Foundation

/// What the 5-minute placement test measured (SPEC section 1, step 6).
nonisolated struct PlacementResult: Sendable, Equatable, Codable {
    /// Pitch-match tones sung within ±10 Hz.
    var pitchMatches = 0
    var pitchAttempts = 0
    /// Share of a held "ee" in the bright resonance zone (0–100).
    var brightResonancePercent: Double?
    /// From the reading passage.
    var readingInTarget: Double?
    var readingResonance: Double?
    var readingWeight: Double?
    var readingIntonation: Double?
}

/// Turns placement results into a starting lesson week.
///
/// Each phase is skipped only when the skills it teaches are already there,
/// and phases are never skipped out of order:
/// - Week 3 (resonance) if pitch matching is solid (4 of 5 tones).
/// - Week 7 (pitch) if a held "ee" stays bright 60%+ of the time.
/// - Week 10 (vocal weight) if reading is 50%+ in target with resonance 55+.
/// - Week 12 (intonation) if reading weight is 55+ and intonation 45+.
nonisolated enum PlacementScoring {
    /// Reference tones for pitch matching (E3 … A3, the low end of a
    /// feminine speaking range).
    static let tones: [Double] = [164.81, 185.00, 196.00, 207.65, 220.00]
    static let matchTolerance = 10.0

    static func isMatch(sung: Double?, target: Double) -> Bool {
        guard let sung else { return false }
        return abs(sung - target) <= matchTolerance
    }

    static func recommendedWeek(for result: PlacementResult) -> Int {
        guard result.pitchAttempts > 0,
              Double(result.pitchMatches) / Double(result.pitchAttempts) >= 0.8
        else { return 1 }
        guard (result.brightResonancePercent ?? 0) >= 60 else { return 3 }
        guard (result.readingInTarget ?? 0) >= 50, (result.readingResonance ?? 0) >= 55 else { return 7 }
        guard (result.readingWeight ?? 0) >= 55, (result.readingIntonation ?? 0) >= 45 else { return 10 }
        return 12
    }

    static func explanation(forWeek week: Int) -> String {
        switch week {
        case 12...:
            "Your pitch, resonance and vocal weight are already well developed. You’ll start with intonation and expression (week 12)."
        case 10...:
            "Pitch and resonance are strong. You’ll start with vocal weight (week 10)."
        case 7...:
            "Your resonance is already bright. You’ll start with the pitch phase (week 7)."
        case 3...:
            "You match pitch well. You’ll skip the foundations and start with resonance (week 3)."
        default:
            "Starting at week 1 builds the habits every later skill relies on: breathing, relaxation and pitch awareness."
        }
    }
}
