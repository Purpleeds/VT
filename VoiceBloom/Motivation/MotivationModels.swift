import Foundation

// MARK: - Streaks

/// A practice streak (SPEC section 12) with one "streak freeze" per week, so
/// a rest day for vocal health doesn't break it.
nonisolated struct StreakStatus: Sendable, Equatable {
    /// Days practiced in the current run (frozen days don't add to it).
    let days: Int
    let practicedToday: Bool
    /// Missed days covered by a freeze, newest first.
    let frozenDays: [Date]
    /// True when this week's freeze is still unused.
    let freezeAvailable: Bool

    static let none = StreakStatus(days: 0, practicedToday: false, frozenDays: [], freezeAvailable: true)
}

nonisolated enum StreakCalculator {
    /// - Parameter practiceDays: Days with practice (any time in the day).
    static func status(practiceDays: [Date], now: Date = Date(), calendar: Calendar = .current) -> StreakStatus {
        let days = Set(practiceDays.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        let practicedToday = days.contains(today)
        guard let earliest = days.min() else {
            return StreakStatus(days: 0, practicedToday: false, frozenDays: [], freezeAvailable: true)
        }

        var count = 0
        var frozen: [Date] = []
        var frozenWeeks = Set<WeekKey>()
        // Today doesn't break the streak until it's over.
        guard var day = practicedToday ? today : calendar.date(byAdding: .day, value: -1, to: today) else {
            return .none
        }
        while day >= earliest {
            if days.contains(day) {
                count += 1
            } else {
                let week = WeekKey(day, calendar: calendar)
                // A freeze only bridges a gap between practice days.
                guard !frozenWeeks.contains(week), count > 0 || frozen.isEmpty,
                      let previous = calendar.date(byAdding: .day, value: -1, to: day), days.contains(previous)
                else { break }
                frozenWeeks.insert(week)
                frozen.append(day)
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        if count == 0 {
            frozen = []
        }
        let thisWeek = WeekKey(today, calendar: calendar)
        return StreakStatus(
            days: count,
            practicedToday: practicedToday,
            frozenDays: frozen,
            freezeAvailable: !frozen.contains { WeekKey($0, calendar: calendar) == thisWeek }
        )
    }

    nonisolated struct WeekKey: Hashable, Sendable {
        let year: Int
        let week: Int

        init(_ date: Date, calendar: Calendar) {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            year = components.yearForWeekOfYear ?? 0
            week = components.weekOfYear ?? 0
        }
    }
}

// MARK: - Achievements

/// Everything achievements are judged on (plain values).
nonisolated struct AchievementInputs: Sendable, Equatable {
    var sessionCount = 0
    var totalMinutes = 0.0
    var streakDays = 0
    var completedLessonWeeks = 0
    /// Best % in target in a session with at least a minute of voice.
    var bestInTarget = 0.0
    var scenarioCount = 0
    var hardScenarioCount = 0
    var clipCount = 0
    var journalEntries = 0
    var quickChecks = 0
    var targetVoices = 0
    var pitchGameBest = 0
    var challengesDone = 0
    var maintenanceUnlocked = false
}

nonisolated enum AchievementKind: String, CaseIterable, Identifiable, Sendable {
    case firstSession
    case streak3
    case streak7
    case streak30
    case firstWeek
    case halfway
    case allWeeks
    case inTarget50
    case inTarget80
    case firstScenario
    case hardScenario
    case firstClip
    case journal7
    case firstQuickCheck
    case targetVoice
    case hours5
    case pitchGame10
    case challenges7

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstSession: "First steps"
        case .streak3: "Three in a row"
        case .streak7: "One-week streak"
        case .streak30: "Thirty-day streak"
        case .firstWeek: "Week one done"
        case .halfway: "Halfway there"
        case .allWeeks: "All sixteen weeks"
        case .inTarget50: "Half in target"
        case .inTarget80: "In the zone"
        case .firstScenario: "Real-world ready"
        case .hardScenario: "Up for a challenge"
        case .firstClip: "Recorded"
        case .journal7: "Seven-day journal"
        case .firstQuickCheck: "Checked in"
        case .targetVoice: "Found a guide"
        case .hours5: "Five hours"
        case .pitchGame10: "High flyer"
        case .challenges7: "Challenge accepted"
        }
    }

    var detail: String {
        switch self {
        case .firstSession: "Finish your first practice session."
        case .streak3: "Practice three days in a row."
        case .streak7: "Practice seven days in a row."
        case .streak30: "Practice thirty days in a row."
        case .firstWeek: "Complete week 1 of the lessons."
        case .halfway: "Complete eight lesson weeks."
        case .allWeeks: "Complete all sixteen lesson weeks."
        case .inTarget50: "Spend 50% of a session in your target."
        case .inTarget80: "Spend 80% of a session in your target."
        case .firstScenario: "Finish your first scenario."
        case .hardScenario: "Finish a scenario on Hard."
        case .firstClip: "Save your first clip."
        case .journal7: "Record seven journal entries."
        case .firstQuickCheck: "Do your first Quick Check."
        case .targetVoice: "Save a target voice."
        case .hours5: "Practice for five hours in total."
        case .pitchGame10: "Fly through 10 gaps in the balloon game."
        case .challenges7: "Complete seven daily challenges."
        }
    }

    var systemImage: String {
        switch self {
        case .firstSession: "sparkles"
        case .streak3, .streak7, .streak30: "flame.fill"
        case .firstWeek, .halfway, .allWeeks: "book.fill"
        case .inTarget50, .inTarget80: "scope"
        case .firstScenario, .hardScenario: "theatermasks.fill"
        case .firstClip: "record.circle"
        case .journal7: "book.pages.fill"
        case .firstQuickCheck: "stopwatch.fill"
        case .targetVoice: "person.wave.2.fill"
        case .hours5: "clock.fill"
        case .pitchGame10: "balloon.fill"
        case .challenges7: "checkmark.seal.fill"
        }
    }

    func isEarned(_ inputs: AchievementInputs) -> Bool {
        switch self {
        case .firstSession: inputs.sessionCount >= 1
        case .streak3: inputs.streakDays >= 3
        case .streak7: inputs.streakDays >= 7
        case .streak30: inputs.streakDays >= 30
        case .firstWeek: inputs.completedLessonWeeks >= 1
        case .halfway: inputs.completedLessonWeeks >= 8
        case .allWeeks: inputs.completedLessonWeeks >= 16 || inputs.maintenanceUnlocked
        case .inTarget50: inputs.bestInTarget >= 50
        case .inTarget80: inputs.bestInTarget >= 80
        case .firstScenario: inputs.scenarioCount >= 1
        case .hardScenario: inputs.hardScenarioCount >= 1
        case .firstClip: inputs.clipCount >= 1
        case .journal7: inputs.journalEntries >= 7
        case .firstQuickCheck: inputs.quickChecks >= 1
        case .targetVoice: inputs.targetVoices >= 1
        case .hours5: inputs.totalMinutes >= 300
        case .pitchGame10: inputs.pitchGameBest >= 10
        case .challenges7: inputs.challengesDone >= 7
        }
    }

    static func earned(_ inputs: AchievementInputs) -> [AchievementKind] {
        allCases.filter { $0.isEarned(inputs) }
    }
}

// MARK: - Daily challenge

/// Where a daily challenge sends you.
nonisolated enum ChallengeDestination: String, Sendable, Equatable {
    case practice
    case quickCheck
    case journal
    case scenarios
    case pitchGame
    case toneGenerator
    case exercise
}

nonisolated struct DailyChallenge: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let destination: ChallengeDestination
    var exerciseID: String?

    /// One short, varied task a day (SPEC section 12), the same all day.
    static func challenge(for date: Date, calendar: Calendar = .current) -> DailyChallenge {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return all[((day % all.count) + all.count) % all.count]
    }

    static let all: [DailyChallenge] = [
        DailyChallenge(id: "order-out-loud", title: "Order out loud", detail: "Practice ordering your usual drink three times in your target voice.", destination: .scenarios),
        DailyChallenge(id: "quick-check", title: "Snapshot", detail: "Do a Quick Check and compare it with last time.", destination: .quickCheck),
        DailyChallenge(id: "journal", title: "Today’s sentence", detail: "Record today’s journal sentence.", destination: .journal),
        DailyChallenge(id: "balloon", title: "Balloon flight", detail: "Fly the balloon through at least 5 gaps.", destination: .pitchGame),
        DailyChallenge(id: "five-minutes", title: "Five easy minutes", detail: "Practice freely for five minutes, keeping it light.", destination: .practice),
        DailyChallenge(id: "match-three", title: "Match three notes", detail: "Play three notes in your target on the piano and hum each one back.", destination: .toneGenerator),
        DailyChallenge(id: "bright-ee", title: "Bright vowels", detail: "Hold a bright “ee” three times for five seconds each.", destination: .exercise, exerciseID: "hold-ee"),
        DailyChallenge(id: "name", title: "Your name, ten ways", detail: "Say “Hi, I’m …” ten times: happy, curious, tired, excited…", destination: .practice),
        DailyChallenge(id: "question-melody", title: "Question melody", detail: "Ask five questions aloud and let each one rise at the end.", destination: .practice),
        DailyChallenge(id: "phone-voice", title: "Phone voice", detail: "Try the phone call scenario on Easy.", destination: .scenarios),
        DailyChallenge(id: "laugh", title: "Light laugh", detail: "Practice three light, bright laughs in your target voice.", destination: .practice),
        DailyChallenge(id: "read-aloud", title: "Read a page", detail: "Read a page of anything aloud and watch the resonance meter.", destination: .practice),
    ]
}

/// Which days' challenges are done (kept in UserDefaults).
nonisolated enum ChallengeStore {
    static let key = "motivation.challengesDone"

    static func doneDays() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func isDone(on date: Date, calendar: Calendar = .current) -> Bool {
        doneDays().contains(dayKey(date, calendar: calendar))
    }

    static func markDone(on date: Date = Date(), calendar: Calendar = .current) {
        var days = doneDays()
        let key = dayKey(date, calendar: calendar)
        guard !days.contains(key) else { return }
        days.append(key)
        UserDefaults.standard.set(Array(days.suffix(400)), forKey: Self.key)
    }
}

// MARK: - Reminders

/// When to send the gentle evening nudge (SPEC section 12: only if you
/// haven't practiced by evening).
nonisolated enum NudgeScheduler {
    static let defaultHour = 19

    static func nextNudge(now: Date, practicedToday: Bool, hour: Int = defaultHour, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let todayNudge = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) else { return nil }
        if !practicedToday, now < todayNudge {
            return todayNudge
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)
    }
}
