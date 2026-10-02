import Foundation
import Testing
@testable import VoiceBloom

@Suite("ProgressAnalytics")
struct ProgressAnalyticsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    /// Midnight UTC, Tuesday 10 March 2026.
    private let march10 = Date(timeIntervalSince1970: 1_773_100_800)

    private func day(_ offset: Int, hour: Double = 12) -> Date {
        march10.addingTimeInterval(Double(offset) * 86_400 + hour * 3_600)
    }

    private var now: Date { day(0, hour: 18) }

    // MARK: Ranges

    @Test("Ranges start at the beginning of the first day")
    func rangeStarts() {
        #expect(ProgressRange.week.startDate(now: now, calendar: calendar) == day(-6, hour: 0))
        #expect(ProgressRange.month.startDate(now: now, calendar: calendar) == day(-29, hour: 0))
        #expect(ProgressRange.quarter.startDate(now: now, calendar: calendar) == day(-89, hour: 0))
        #expect(ProgressRange.all.startDate(now: now, calendar: calendar, earliest: day(-200, hour: 15)) == day(-200, hour: 0))
        #expect(ProgressRange.all.startDate(now: now, calendar: calendar, earliest: nil) == day(-29, hour: 0))
    }

    @Test("Points are filtered to the range and sorted")
    func filtering() {
        let points = [
            SessionPoint(date: day(-2), minutes: 10),
            SessionPoint(date: day(-10), minutes: 5),
            SessionPoint(date: day(-6, hour: 0.5), minutes: 7),
            SessionPoint(date: day(-7, hour: 23), minutes: 3),
        ]
        let week = ProgressAnalytics.points(points, in: .week, now: now, calendar: calendar)
        #expect(week.map(\.minutes) == [7, 10])
        let all = ProgressAnalytics.points(points, in: .all, now: now, calendar: calendar)
        #expect(all.count == 4)
        #expect(all.first?.minutes == 5)
    }

    @Test("Tapping a chart picks the closest session")
    func nearest() {
        let points = [SessionPoint(date: day(-5), minutes: 1), SessionPoint(date: day(-2), minutes: 2)]
        #expect(ProgressAnalytics.nearest(to: day(-3), in: points)?.minutes == 2)
        #expect(ProgressAnalytics.nearest(to: day(-4, hour: 6), in: points)?.minutes == 1)
        #expect(ProgressAnalytics.nearest(to: day(0), in: []) == nil)
    }

    // MARK: Practice time

    @Test("Daily minutes include days without practice")
    func dailyBuckets() {
        let points = [
            SessionPoint(date: day(-2, hour: 9), minutes: 10),
            SessionPoint(date: day(-2, hour: 20), minutes: 5),
            SessionPoint(date: day(0, hour: 8), minutes: 12),
        ]
        let buckets = ProgressAnalytics.dailyMinutes(points, from: day(-3, hour: 0), through: now, calendar: calendar)
        #expect(buckets.map(\.minutes) == [0, 15, 0, 12])
        #expect(buckets.map(\.sessionCount) == [0, 2, 0, 1])
        #expect(buckets.first?.start == day(-3, hour: 0))
    }

    @Test("Weekly minutes group by calendar week")
    func weeklyBuckets() {
        // Monday 9 March starts the current week (first weekday = Monday).
        let points = [
            SessionPoint(date: day(-1), minutes: 10),   // Mon 9 Mar
            SessionPoint(date: day(0), minutes: 5),     // Tue 10 Mar
            SessionPoint(date: day(-2), minutes: 20),   // Sun 8 Mar (previous week)
        ]
        let buckets = ProgressAnalytics.weeklyMinutes(points, from: day(-8, hour: 0), through: now, calendar: calendar)
        #expect(buckets.map(\.minutes) == [20, 15])
        #expect(buckets.last?.start == day(-1, hour: 0))
    }

    // MARK: Heatmap

    @Test("Heatmap levels follow the daily goal")
    func heatmapLevels() {
        #expect(ProgressAnalytics.heatmapLevel(minutes: 0, dailyGoal: 15) == 0)
        #expect(ProgressAnalytics.heatmapLevel(minutes: 5, dailyGoal: 15) == 1)
        #expect(ProgressAnalytics.heatmapLevel(minutes: 10, dailyGoal: 15) == 2)
        #expect(ProgressAnalytics.heatmapLevel(minutes: 15, dailyGoal: 15) == 3)
        #expect(ProgressAnalytics.heatmapLevel(minutes: 25, dailyGoal: 15) == 4)
    }

    @Test("Heatmap is whole weeks ending with the current one")
    func heatmapGrid() throws {
        let points = [
            SessionPoint(date: day(0, hour: 8), minutes: 20),
            SessionPoint(date: day(-8), minutes: 4),
        ]
        let weeks = ProgressAnalytics.heatmap(points, weeks: 3, now: now, dailyGoal: 15, calendar: calendar)
        #expect(weeks.count == 3)
        #expect(weeks.allSatisfy { $0.days.count == 7 })
        // Weeks start on Monday; the current week starts Monday 9 March.
        let lastWeek = try #require(weeks.last)
        #expect(lastWeek.start == day(-1, hour: 0))
        #expect(lastWeek.days[1].minutes == 20)
        #expect(lastWeek.days[1].level == 3)
        #expect(lastWeek.days[2].isFuture)
        #expect(!lastWeek.days[1].isFuture)
        // Monday 2 March (day −8) is the first day of the middle week.
        #expect(weeks[1].days[0].minutes == 4)
        #expect(weeks[1].days[0].level == 1)
    }

    // MARK: Weekly summary

    @Test("Weekly summary: totals, best day, improvement and focus")
    func weeklySummary() throws {
        let points = [
            // Last week
            SessionPoint(date: day(-10), minutes: 10, percentInTarget: 30, resonance: 40, weight: 50, intonation: 45),
            SessionPoint(date: day(-9), minutes: 10, percentInTarget: 34, resonance: 44, weight: 50, intonation: 45),
            // This week
            SessionPoint(date: day(-3, hour: 9), minutes: 10, percentInTarget: 40, resonance: 55, weight: 52, intonation: 30),
            SessionPoint(date: day(-3, hour: 19), minutes: 5, percentInTarget: 70, resonance: 57, weight: 50, intonation: 34),
            SessionPoint(date: day(-1), minutes: 20, percentInTarget: 45, resonance: 56, weight: 51, intonation: 32),
        ]
        let summary = ProgressAnalytics.weeklySummary(points, now: now, calendar: calendar)
        #expect(summary.sessionCount == 3)
        #expect(summary.minutes == 35)
        #expect(summary.activeDays == 2)

        // Day −3: (40·10 + 70·5) / 15 = 50% beats day −1's 45%.
        let best = try #require(summary.bestDay)
        #expect(best.date == day(-3, hour: 0))
        let percent = try #require(best.percentInTarget)
        #expect(abs(percent - 50) < 1e-9)
        #expect(best.minutes == 15)

        // Time in target rose 32 → 51.67 (+19.67), more than resonance (42 → 56).
        let change = try #require(summary.biggestImprovement)
        #expect(change.metric == .inTarget)
        #expect(abs(change.amount - (155.0 / 3 - 32)) < 1e-9)

        // Intonation (average 32) is the lowest this week.
        let focus = try #require(summary.focus)
        #expect(focus.metric == .intonation)
        #expect(abs(focus.average - 32) < 1e-9)
    }

    @Test("Weekly summary without data")
    func emptySummary() {
        let summary = ProgressAnalytics.weeklySummary([SessionPoint(date: day(-20), minutes: 10)], now: now, calendar: calendar)
        #expect(summary.isEmpty)
        #expect(summary.bestDay == nil)
        #expect(summary.biggestImprovement == nil)
        #expect(summary.focus == nil)
    }

    @Test("Without measurements the best day is the longest one")
    func bestDayByMinutes() throws {
        let points = [
            SessionPoint(date: day(-2), minutes: 8),
            SessionPoint(date: day(-1), minutes: 12),
        ]
        let best = try #require(ProgressAnalytics.weeklySummary(points, now: now, calendar: calendar).bestDay)
        #expect(best.minutes == 12)
        #expect(best.percentInTarget == nil)
    }

    // MARK: Radar

    @Test("Radar averages every turn")
    func radar() throws {
        let results: [[ScenarioTurnScore]] = [
            [ScenarioTurnScore(pitch: 60, resonance: 40), ScenarioTurnScore(pitch: 80, resonance: nil, consistency: 50)],
            [ScenarioTurnScore(pitch: 70, resonance: 60, weight: 30)],
            [],
        ]
        let radar = try #require(ProgressAnalytics.radar(results))
        #expect(radar.resultCount == 2)
        #expect(radar.value(.pitch) == 70)
        #expect(radar.value(.resonance) == 50)
        #expect(radar.value(.weight) == 30)
        #expect(radar.value(.consistency) == 50)
        #expect(radar.value(.intonation) == nil)
        #expect(ProgressAnalytics.radar([]) == nil)
        #expect(ProgressAnalytics.radar([[ScenarioTurnScore()]]) == nil)
    }

    // MARK: Then vs Now

    @Test("Then is the first baseline; now is the newest recording")
    func thenAndNow() throws {
        let clip1 = RecordingSummary(date: day(-50), kind: .clip)
        let baseline = RecordingSummary(date: day(-40), kind: .baseline)
        let clip2 = RecordingSummary(date: day(-2), kind: .clip)
        let pair = try #require(ProgressAnalytics.thenAndNow([clip2, baseline, clip1]))
        #expect(pair.then.id == baseline.id)
        #expect(pair.now.id == clip2.id)
    }

    @Test("A later baseline re-recording is preferred for now")
    func reRecordedBaseline() throws {
        let baseline = RecordingSummary(date: day(-100), kind: .baseline)
        let week16 = RecordingSummary(date: day(-5), kind: .baseline)
        let clip = RecordingSummary(date: day(-1), kind: .clip)
        let pair = try #require(ProgressAnalytics.thenAndNow([clip, week16, baseline]))
        #expect(pair.then.id == baseline.id)
        #expect(pair.now.id == week16.id)
    }

    @Test("Without a baseline the first recording is then; one recording isn't enough")
    func fallbacks() throws {
        let first = RecordingSummary(date: day(-9), kind: .clip)
        let second = RecordingSummary(date: day(-1), kind: .journal)
        let pair = try #require(ProgressAnalytics.thenAndNow([second, first]))
        #expect(pair.then.id == first.id)
        #expect(pair.now.id == second.id)
        #expect(ProgressAnalytics.thenAndNow([first]) == nil)
    }
}

@Suite("ProgressCSV")
struct ProgressCSVTests {
    @Test("Fields with commas, quotes or line breaks are quoted")
    func escaping() {
        #expect(ProgressCSV.escape("plain") == "plain")
        #expect(ProgressCSV.escape("a,b") == "\"a,b\"")
        #expect(ProgressCSV.escape("say \"ee\"") == "\"say \"\"ee\"\"\"")
        #expect(ProgressCSV.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test("Numbers use a dot and empty cells for missing values")
    func numbers() {
        #expect(ProgressCSV.number(192.345, decimals: 1) == "192.3")
        #expect(ProgressCSV.number(nil, decimals: 1) == "")
        #expect(ProgressCSV.number(.nan, decimals: 1) == "")
        #expect(ProgressCSV.number(0.5, decimals: 2) == "0.50")
    }

    @Test("One header line and one line per session, oldest first")
    func rows() {
        var later = SessionExportRow(date: Date(timeIntervalSince1970: 1_773_100_800 + 7_200), kind: "Free practice", durationSeconds: 600)
        later.averagePitch = 190
        later.comfort = "A bit tired"
        later.naturalness = 4
        let earlier = SessionExportRow(date: Date(timeIntervalSince1970: 1_773_100_800), kind: "Lesson, week 2", durationSeconds: 90)

        let csv = ProgressCSV.make(rows: [later, earlier], timeZone: .gmt)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0] == ProgressCSV.header.joined(separator: ","))
        #expect(lines[1].hasPrefix("2026-03-10 00:00,\"Lesson, week 2\",1.5,0.0,"))
        #expect(lines[2].hasPrefix("2026-03-10 02:00,Free practice,10.0,0.0,190.0,"))
        #expect(lines[2].hasSuffix(",0,0,A bit tired,4,0"))
        #expect(lines[1].split(separator: ",", omittingEmptySubsequences: false).count == ProgressCSV.header.count + 1) // the quoted comma
        #expect(lines[2].split(separator: ",", omittingEmptySubsequences: false).count == ProgressCSV.header.count)
    }
}

@Suite("Sample data")
struct SampleDataPlannerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    @Test("Sample history spans the requested days and improves over time")
    func sessionsImprove() throws {
        let now = Date(timeIntervalSince1970: 1_773_100_800 + 20 * 3_600)
        let plans = SampleDataPlanner.sessions(days: 90, now: now, calendar: calendar)
        #expect(plans.count > 50)
        #expect(plans.allSatisfy { $0.date <= now })
        let first = try #require(plans.first)
        let result1 = now.timeIntervalSince(first.date)
        #expect(result1 < 90 * 86_400)
        #expect(plans == plans.sorted { $0.date < $1.date })

        let early = plans.prefix(15)
        let late = plans.suffix(15)
        let earlyPitch = early.map(\.averagePitch).reduce(0, +) / Double(early.count)
        let latePitch = late.map(\.averagePitch).reduce(0, +) / Double(late.count)
        #expect(latePitch > earlyPitch + 30)
        #expect(plans.allSatisfy { (0...100).contains($0.percentInTarget) && (0...100).contains($0.resonance) })
        // Deterministic.
        #expect(plans == SampleDataPlanner.sessions(days: 90, now: now, calendar: calendar))
    }

    @Test("Sample scenario scores stay in 0–100")
    func scenarioScores() {
        let results = SampleDataPlanner.scenarioScores(count: 10)
        #expect(results.count == 10)
        #expect(results.allSatisfy { (4...6).contains($0.count) })
        let values = results.flatMap { $0 }.flatMap { [$0.pitch, $0.resonance, $0.weight, $0.intonation, $0.consistency].compactMap { $0 } }
        #expect(values.allSatisfy { (0...100).contains($0) })
    }

    @Test("Synthetic voice has the requested pitch")
    func syntheticVoicePitch() throws {
        let samples = SampleDataPlanner.syntheticVoice(fundamental: 200, formants: [800, 1_400, 2_800], seconds: 1)
        #expect(samples.count == 48_000)
        #expect(samples.allSatisfy { abs($0) <= 1 })
        // At 0.25 s the slow melody crosses its starting pitch, so a frame
        // centred there should read about 200 Hz.
        let configuration = AnalysisConfiguration()
        let start = 12_000 - configuration.frameSize / 2
        let estimate = PitchAnalyzer(configuration: configuration).estimate(Array(samples[start..<start + configuration.frameSize]))
        let frequency = try #require(estimate.frequency)
        #expect(abs(frequency - 200) < 8)
    }
}
