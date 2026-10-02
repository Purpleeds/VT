import Foundation

/// A break suggestion during practice (SPEC section 14: a 45-minute daily
/// soft limit with break suggestions).
nonisolated enum BreakAdvice: Equatable, Sendable {
    case none
    /// Every 15 minutes of active practice in one session.
    case shortBreak(sessionMinutes: Int)
    /// Within 5 minutes of the daily limit.
    case nearLimit(remainingMinutes: Int)
    /// The daily limit is reached; practice isn't blocked, just discouraged.
    case overLimit(todayMinutes: Int)

    var title: String {
        switch self {
        case .none: ""
        case .shortBreak: "Time for a short break"
        case .nearLimit: "Almost at today’s limit"
        case .overLimit: "That’s plenty for today"
        }
    }

    var message: String {
        switch self {
        case .none:
            ""
        case .shortBreak(let minutes):
            "You’ve been practicing for \(minutes) minutes. Rest your voice for a few minutes: sip some water, relax your jaw and shoulders, and breathe quietly."
        case .nearLimit(let remaining):
            "About \(remaining) minute\(remaining == 1 ? "" : "s") left of the suggested \(Int(BreakAdvisor.dailyLimitMinutes)) minutes a day. A gentle cool-down is a good way to finish."
        case .overLimit(let minutes):
            "You’ve practiced \(minutes) minutes today, past the suggested \(Int(BreakAdvisor.dailyLimitMinutes)). Your voice gets stronger while it rests, so consider stopping here and coming back tomorrow."
        }
    }

    var systemImage: String {
        switch self {
        case .none: "checkmark.circle"
        case .shortBreak: "cup.and.saucer.fill"
        case .nearLimit: "hourglass"
        case .overLimit: "moon.zzz.fill"
        }
    }
}

nonisolated enum BreakAdvisor {
    static let dailyLimitMinutes = 45.0
    static let breakIntervalMinutes = 15.0
    static let nearLimitMinutes = 5.0

    /// - Parameters:
    ///   - todayMinutes: practice today, including the session in progress.
    ///   - sessionMinutes: active practice in the current session.
    static func advice(todayMinutes: Double, sessionMinutes: Double) -> BreakAdvice {
        if todayMinutes >= dailyLimitMinutes {
            return .overLimit(todayMinutes: Int(todayMinutes))
        }
        if todayMinutes >= dailyLimitMinutes - nearLimitMinutes {
            return .nearLimit(remainingMinutes: max(1, Int((dailyLimitMinutes - todayMinutes).rounded(.up))))
        }
        let blocks = Int(sessionMinutes / breakIntervalMinutes)
        if blocks >= 1 {
            return .shortBreak(sessionMinutes: blocks * Int(breakIntervalMinutes))
        }
        return .none
    }
}

/// One stored session, reduced to what the health summary needs.
nonisolated struct HealthSessionInput: Sendable, Equatable {
    let date: Date
    let minutes: Double
    let comfort: ComfortRating?
    let strainWarnings: Int
}

/// The Vocal Health Center's overview of the last week.
nonisolated struct VocalHealthSummary: Sendable, Equatable {
    var todayMinutes: Double = 0
    var weekMinutes: Double = 0
    var fineCount = 0
    var tiredCount = 0
    var soreCount = 0
    var strainWarnings = 0
    var recentStrainWarnings = 0
    var advice: CheckInAdvice = .none

    static let windowDays = 7
    /// Strain warnings in the last 2 days that suggest an easy day.
    static let strainEasyDayCount = 3

    var remainingMinutes: Double {
        max(0, BreakAdvisor.dailyLimitMinutes - todayMinutes)
    }

    var checkInCount: Int { fineCount + tiredCount + soreCount }

    /// Rest-day suggestion from strain warnings (check-ins have their own rule).
    var suggestsEasyDay: Bool {
        recentStrainWarnings >= Self.strainEasyDayCount
    }

    static func make(sessions: [HealthSessionInput], now: Date, calendar: Calendar = .current) -> VocalHealthSummary {
        var summary = VocalHealthSummary()
        var reports: [ComfortReport] = []
        for session in sessions {
            guard CheckInRules.isWithin(days: windowDays, date: session.date, now: now, calendar: calendar) else { continue }
            summary.weekMinutes += session.minutes
            if calendar.isDate(session.date, inSameDayAs: now) {
                summary.todayMinutes += session.minutes
            }
            summary.strainWarnings += session.strainWarnings
            if CheckInRules.isWithin(days: 2, date: session.date, now: now, calendar: calendar) {
                summary.recentStrainWarnings += session.strainWarnings
            }
            if let comfort = session.comfort {
                reports.append(ComfortReport(date: session.date, comfort: comfort))
                switch comfort {
                case .fine: summary.fineCount += 1
                case .tired: summary.tiredCount += 1
                case .sore: summary.soreCount += 1
                }
            }
        }
        summary.advice = CheckInRules.advice(for: reports, now: now, calendar: calendar)
        return summary
    }
}
