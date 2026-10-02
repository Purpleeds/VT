import Foundation

/// One session's values for the Progress charts, copied out of SwiftData
/// so all the analysis below works on plain values (and is easy to test).
nonisolated struct SessionPoint: Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    /// Practice time in minutes (pauses excluded).
    let minutes: Double
    let averagePitch: Double?
    let minimumPitch: Double?
    let maximumPitch: Double?
    let percentInTarget: Double?
    let resonance: Double?
    let weight: Double?
    let intonation: Double?
    let comfort: ComfortRating?
    let naturalness: Int?

    init(
        id: UUID = UUID(),
        date: Date,
        minutes: Double,
        averagePitch: Double? = nil,
        minimumPitch: Double? = nil,
        maximumPitch: Double? = nil,
        percentInTarget: Double? = nil,
        resonance: Double? = nil,
        weight: Double? = nil,
        intonation: Double? = nil,
        comfort: ComfortRating? = nil,
        naturalness: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.minutes = minutes
        self.averagePitch = averagePitch
        self.minimumPitch = minimumPitch
        self.maximumPitch = maximumPitch
        self.percentInTarget = percentInTarget
        self.resonance = resonance
        self.weight = weight
        self.intonation = intonation
        self.comfort = comfort
        self.naturalness = naturalness
    }

    init(_ session: PracticeSession) {
        self.init(
            id: session.id,
            date: session.startDate,
            minutes: session.duration / 60,
            averagePitch: session.averagePitch,
            minimumPitch: session.minimumPitch,
            maximumPitch: session.maximumPitch,
            percentInTarget: session.percentInTarget,
            resonance: session.resonanceScore,
            weight: session.weightScore,
            intonation: session.intonationScore,
            comfort: session.comfort,
            naturalness: session.naturalnessRating
        )
    }

    func value(of metric: ProgressMetric) -> Double? {
        switch metric {
        case .inTarget: percentInTarget
        case .resonance: resonance
        case .weight: weight
        case .intonation: intonation
        }
    }
}

/// The 0–100 measures compared in summaries and charts.
nonisolated enum ProgressMetric: String, CaseIterable, Identifiable, Sendable {
    case inTarget
    case resonance
    case weight
    case intonation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inTarget: "Time in target"
        case .resonance: "Resonance"
        case .weight: "Vocal weight"
        case .intonation: "Intonation"
        }
    }

    /// Suffix after a value, e.g. "62%" vs "62".
    var unit: String {
        self == .inTarget ? "%" : ""
    }
}

/// Time ranges for the Progress tab.
nonisolated enum ProgressRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case quarter
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .all: "All"
        }
    }

    var spokenTitle: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        case .all: "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    /// Weeks shown in the calendar heatmap for this range.
    var heatmapWeeks: Int {
        switch self {
        case .week: 5
        case .month: 6
        case .quarter: 14
        case .all: 27
        }
    }

    /// Start of the first day in the range. "All" starts at the first
    /// session (or 30 days ago when there are none).
    func startDate(now: Date, calendar: Calendar, earliest: Date? = nil) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let days else {
            let fallback = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return earliest.map { min(calendar.startOfDay(for: $0), today) } ?? fallback
        }
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

/// Minutes practiced in one day or week.
nonisolated struct PracticeBucket: Identifiable, Sendable, Equatable {
    let start: Date
    let minutes: Double
    let sessionCount: Int

    var id: Date { start }
}

/// One square of the calendar heatmap.
nonisolated struct HeatmapDay: Identifiable, Sendable, Equatable {
    let date: Date
    let minutes: Double
    /// 0 = no practice … 4 = well past the daily goal.
    let level: Int
    let isFuture: Bool

    var id: Date { date }
}

/// One column (a calendar week) of the heatmap.
nonisolated struct HeatmapWeek: Identifiable, Sendable, Equatable {
    let start: Date
    let days: [HeatmapDay]

    var id: Date { start }
}

/// The weekly summary card: last 7 days compared with the 7 before.
nonisolated struct WeeklySummary: Sendable, Equatable {
    nonisolated struct BestDay: Sendable, Equatable {
        let date: Date
        let minutes: Double
        let percentInTarget: Double?
    }

    nonisolated struct Change: Sendable, Equatable {
        let metric: ProgressMetric
        /// This week's average minus last week's.
        let amount: Double
    }

    nonisolated struct Focus: Sendable, Equatable {
        let metric: ProgressMetric
        let average: Double
    }

    let minutes: Double
    let sessionCount: Int
    let activeDays: Int
    let bestDay: BestDay?
    let biggestImprovement: Change?
    let focus: Focus?

    var isEmpty: Bool { sessionCount == 0 }
}

/// Average scenario scores per skill, for the radar chart.
nonisolated struct RadarValues: Sendable, Equatable {
    nonisolated enum Axis: String, CaseIterable, Identifiable, Sendable {
        case pitch
        case resonance
        case weight
        case intonation
        case consistency

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pitch: "Pitch"
            case .resonance: "Resonance"
            case .weight: "Weight"
            case .intonation: "Intonation"
            case .consistency: "Consistency"
            }
        }

        func value(in score: ScenarioTurnScore) -> Double? {
            switch self {
            case .pitch: score.pitch
            case .resonance: score.resonance
            case .weight: score.weight
            case .intonation: score.intonation
            case .consistency: score.consistency
            }
        }
    }

    /// 0–100 per axis (missing when no turn measured it).
    let values: [Axis: Double]
    let resultCount: Int

    func value(_ axis: Axis) -> Double? { values[axis] }
}

/// A recording's values for "Then vs Now".
nonisolated struct RecordingSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let kind: RecordingKind
    let duration: Double
    let averagePitch: Double?
    let percentInTarget: Double?
    let resonance: Double?
    let weight: Double?
    let intonation: Double?

    init(
        id: UUID = UUID(),
        date: Date,
        kind: RecordingKind,
        duration: Double = 10,
        averagePitch: Double? = nil,
        percentInTarget: Double? = nil,
        resonance: Double? = nil,
        weight: Double? = nil,
        intonation: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.duration = duration
        self.averagePitch = averagePitch
        self.percentInTarget = percentInTarget
        self.resonance = resonance
        self.weight = weight
        self.intonation = intonation
    }

    init(_ recording: Recording) {
        self.init(
            id: recording.id,
            date: recording.createdAt,
            kind: recording.kind,
            duration: recording.duration,
            averagePitch: recording.averagePitch,
            percentInTarget: recording.percentInTarget,
            resonance: recording.resonanceScore,
            weight: recording.weightScore,
            intonation: recording.intonationScore
        )
    }
}

/// Calculations behind the Progress tab (SPEC section 11).
nonisolated enum ProgressAnalytics {
    // MARK: Ranges

    /// Sessions in the range, oldest first.
    static func points(
        _ points: [SessionPoint],
        in range: ProgressRange,
        now: Date,
        calendar: Calendar
    ) -> [SessionPoint] {
        let earliest = points.map(\.date).min()
        let start = range.startDate(now: now, calendar: calendar, earliest: earliest)
        return points
            .filter { $0.date >= start && $0.date <= now }
            .sorted { $0.date < $1.date }
    }

    /// The session closest in time to `date` (used when a chart is tapped).
    static func nearest(to date: Date, in points: [SessionPoint]) -> SessionPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: Practice time

    /// Minutes per day from `start` through `end`, including days without practice.
    static func dailyMinutes(
        _ points: [SessionPoint],
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> [PracticeBucket] {
        buckets(points, from: start, through: end, component: .day, calendar: calendar)
    }

    /// Minutes per calendar week (weeks start on the calendar's first weekday).
    static func weeklyMinutes(
        _ points: [SessionPoint],
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> [PracticeBucket] {
        buckets(points, from: start, through: end, component: .weekOfYear, calendar: calendar)
    }

    private static func buckets(
        _ points: [SessionPoint],
        from start: Date,
        through end: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> [PracticeBucket] {
        guard start <= end else { return [] }
        var totals: [Date: (minutes: Double, count: Int)] = [:]
        for point in points where point.date >= start && point.date <= end {
            guard let bucketStart = periodStart(of: point.date, component: component, calendar: calendar) else { continue }
            let current = totals[bucketStart] ?? (0, 0)
            totals[bucketStart] = (current.minutes + point.minutes, current.count + 1)
        }

        var result: [PracticeBucket] = []
        guard var cursor = periodStart(of: start, component: component, calendar: calendar) else { return [] }
        // A generous cap keeps a bad date from looping forever.
        while cursor <= end, result.count < 5_000 {
            let total = totals[cursor] ?? (0, 0)
            result.append(PracticeBucket(start: cursor, minutes: total.minutes, sessionCount: total.count))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private static func periodStart(of date: Date, component: Calendar.Component, calendar: Calendar) -> Date? {
        if component == .day {
            return calendar.startOfDay(for: date)
        }
        return calendar.dateInterval(of: component, for: date)?.start
    }

    // MARK: Calendar heatmap

    /// How strongly a day is shaded: 0 none, 1 under half the goal,
    /// 2 under the goal, 3 goal met, 4 at least 1.5× the goal.
    static func heatmapLevel(minutes: Double, dailyGoal: Double) -> Int {
        guard minutes > 0 else { return 0 }
        let goal = max(dailyGoal, 1)
        switch minutes / goal {
        case ..<0.5: return 1
        case ..<1: return 2
        case ..<1.5: return 3
        default: return 4
        }
    }

    /// `weeks` columns of 7 days, oldest first; the last column contains today.
    static func heatmap(
        _ points: [SessionPoint],
        weeks: Int,
        now: Date,
        dailyGoal: Double,
        calendar: Calendar
    ) -> [HeatmapWeek] {
        guard weeks > 0, let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeek)
        else { return [] }

        var minutesByDay: [Date: Double] = [:]
        for point in points {
            minutesByDay[calendar.startOfDay(for: point.date), default: 0] += point.minutes
        }
        let today = calendar.startOfDay(for: now)

        return (0..<weeks).compactMap { weekIndex -> HeatmapWeek? in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: firstWeek) else { return nil }
            let days = (0..<7).compactMap { dayIndex -> HeatmapDay? in
                guard let date = calendar.date(byAdding: .day, value: dayIndex, to: weekStart) else { return nil }
                let day = calendar.startOfDay(for: date)
                let minutes = minutesByDay[day] ?? 0
                return HeatmapDay(
                    date: day,
                    minutes: minutes,
                    level: heatmapLevel(minutes: minutes, dailyGoal: dailyGoal),
                    isFuture: day > today
                )
            }
            return HeatmapWeek(start: weekStart, days: days)
        }
    }

    // MARK: Weekly summary

    static func weeklySummary(_ points: [SessionPoint], now: Date, calendar: Calendar) -> WeeklySummary {
        let today = calendar.startOfDay(for: now)
        let thisWeekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let lastWeekStart = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let thisWeek = points.filter { $0.date >= thisWeekStart && $0.date <= now }
        let lastWeek = points.filter { $0.date >= lastWeekStart && $0.date < thisWeekStart }

        let activeDays = Set(thisWeek.map { calendar.startOfDay(for: $0.date) })

        return WeeklySummary(
            minutes: thisWeek.reduce(0) { $0 + $1.minutes },
            sessionCount: thisWeek.count,
            activeDays: activeDays.count,
            bestDay: bestDay(in: thisWeek, calendar: calendar),
            biggestImprovement: biggestImprovement(from: lastWeek, to: thisWeek),
            focus: focusArea(in: thisWeek)
        )
    }

    /// The day with the highest time in target (weighted by minutes), or the
    /// longest practice day when nothing was measured.
    private static func bestDay(in points: [SessionPoint], calendar: Calendar) -> WeeklySummary.BestDay? {
        let byDay = Dictionary(grouping: points) { calendar.startOfDay(for: $0.date) }
        let days = byDay.map { day, sessions -> WeeklySummary.BestDay in
            let minutes = sessions.reduce(0) { $0 + $1.minutes }
            let measured = sessions.filter { $0.percentInTarget != nil }
            let weight = measured.reduce(0) { $0 + max($1.minutes, 0.01) }
            let percent = measured.isEmpty ? nil : measured.reduce(0) { $0 + ($1.percentInTarget ?? 0) * max($1.minutes, 0.01) } / weight
            return WeeklySummary.BestDay(date: day, minutes: minutes, percentInTarget: percent)
        }
        let measuredDays = days.filter { $0.percentInTarget != nil }
        if let best = measuredDays.max(by: { ($0.percentInTarget ?? 0, $0.minutes) < ($1.percentInTarget ?? 0, $1.minutes) }) {
            return best
        }
        return days.max { $0.minutes < $1.minutes }
    }

    private static func average(_ metric: ProgressMetric, in points: [SessionPoint]) -> Double? {
        let values = points.compactMap { $0.value(of: metric) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The measure that rose the most since last week (at least 1 point).
    private static func biggestImprovement(from lastWeek: [SessionPoint], to thisWeek: [SessionPoint]) -> WeeklySummary.Change? {
        let changes = ProgressMetric.allCases.compactMap { metric -> WeeklySummary.Change? in
            guard let before = average(metric, in: lastWeek), let after = average(metric, in: thisWeek) else { return nil }
            return WeeklySummary.Change(metric: metric, amount: after - before)
        }
        return changes.filter { $0.amount >= 1 }.max { $0.amount < $1.amount }
    }

    /// The lowest-scoring measure this week.
    private static func focusArea(in points: [SessionPoint]) -> WeeklySummary.Focus? {
        ProgressMetric.allCases
            .compactMap { metric in average(metric, in: points).map { WeeklySummary.Focus(metric: metric, average: $0) } }
            .min { $0.average < $1.average }
    }

    // MARK: Scenario radar

    /// Averages every scored turn of the given scenario results.
    /// - Parameter results: The turn scores of each scenario result.
    static func radar(_ results: [[ScenarioTurnScore]]) -> RadarValues? {
        let nonEmpty = results.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let turns = nonEmpty.flatMap { $0 }
        var values: [RadarValues.Axis: Double] = [:]
        for axis in RadarValues.Axis.allCases {
            let scores = turns.compactMap { axis.value(in: $0) }
            if !scores.isEmpty {
                values[axis] = min(max(scores.reduce(0, +) / Double(scores.count), 0), 100)
            }
        }
        guard !values.isEmpty else { return nil }
        return RadarValues(values: values, resultCount: nonEmpty.count)
    }

    // MARK: Then vs Now

    /// The baseline ("then") and the most recent comparable recording ("now").
    ///
    /// "Then" is the earliest baseline recording (or the earliest recording of
    /// any kind). "Now" is a later baseline re-recording if there is one,
    /// otherwise the newest recording.
    static func thenAndNow(_ recordings: [RecordingSummary]) -> (then: RecordingSummary, now: RecordingSummary)? {
        let sorted = recordings.sorted { $0.date < $1.date }
        let baselines = sorted.filter { $0.kind == .baseline }
        guard let then = baselines.first ?? sorted.first else { return nil }
        let later = sorted.filter { $0.id != then.id && $0.date >= then.date }
        let laterBaseline = later.last { $0.kind == .baseline }
        guard let now = laterBaseline ?? later.last else { return nil }
        return (then, now)
    }
}
