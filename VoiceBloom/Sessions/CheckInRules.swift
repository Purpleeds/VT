import Foundation

/// One "How did your throat feel?" answer.
nonisolated struct ComfortReport: Sendable, Equatable {
    let date: Date
    let comfort: ComfortRating
}

/// What the app suggests after a check-in.
nonisolated enum CheckInAdvice: Sendable, Equatable {
    case none
    /// "Sore" twice within 3 days: take a rest day.
    case restDay
    /// "Sore" keeps coming back (3 times within 7 days): rest, and see a
    /// doctor or speech-language pathologist.
    case seeSpecialist

    var title: String {
        switch self {
        case .none: ""
        case .restDay: "Take a rest day"
        case .seeSpecialist: "Please get your throat checked"
        }
    }

    var message: String {
        switch self {
        case .none:
            ""
        case .restDay:
            "Your throat has felt sore twice in the last 3 days. Give your voice a day off from training, drink water, and avoid shouting or whispering. If the soreness continues, see a doctor or speech-language pathologist."
        case .seeSpecialist:
            "Your throat has felt sore several times this week. Rest your voice, and please see a doctor or speech-language pathologist before training hard again. Voice training should never hurt."
        }
    }
}

/// Vocal-health rules for check-ins (SPEC section 4).
nonisolated enum CheckInRules {
    /// "Sore" reports within this many calendar days (today included)
    /// suggest a rest day.
    static let restWindowDays = 3
    static let restReportCount = 2
    /// Repeated soreness within a week recommends seeing a professional.
    static let specialistWindowDays = 7
    static let specialistReportCount = 3

    static func advice(for reports: [ComfortReport], now: Date, calendar: Calendar = .current) -> CheckInAdvice {
        let soreDates = reports.filter { $0.comfort == .sore }.map(\.date)
        let weekCount = soreDates.filter { isWithin(days: specialistWindowDays, date: $0, now: now, calendar: calendar) }.count
        if weekCount >= specialistReportCount {
            return .seeSpecialist
        }
        let recentCount = soreDates.filter { isWithin(days: restWindowDays, date: $0, now: now, calendar: calendar) }.count
        if recentCount >= restReportCount {
            return .restDay
        }
        return .none
    }

    /// True on the day a rest day was suggested and the day after (the rest
    /// day itself when the check-in was in the evening).
    static func isRestDaySuggested(suggestedOn date: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return isWithin(days: 2, date: date, now: now, calendar: calendar)
    }

    /// True when `date` falls on today or one of the `days − 1` calendar days
    /// before it (and not in the future).
    static func isWithin(days: Int, date: Date, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        guard let elapsed = calendar.dateComponents([.day], from: day, to: today).day else { return false }
        return elapsed >= 0 && elapsed < days
    }
}
