import Foundation
import Testing
@testable import VoiceBloom

private var iso: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}

/// Noon UTC on 2026-03-`n` (2026-03-10 is a Tuesday in ISO week 11).
private func march(_ day: Int, hour: Int = 12) -> Date {
    Date(timeIntervalSince1970: 1_773_144_000 + Double(day - 10) * 86_400 + Double(hour - 12) * 3_600)
}

@Suite("Streaks with weekly freezes")
struct StreakTests {
    @Test("Consecutive days count, including today")
    func consecutive() {
        let status = StreakCalculator.status(practiceDays: [march(9), march(10), march(11), march(12)], now: march(12, hour: 18), calendar: iso)
        #expect(status.days == 4)
        #expect(status.practicedToday)
        #expect(status.frozenDays.isEmpty)
        #expect(status.freezeAvailable)
    }

    @Test("Today doesn't break the streak before it's over")
    func todayPending() {
        let status = StreakCalculator.status(practiceDays: [march(9), march(10), march(11)], now: march(12, hour: 8), calendar: iso)
        #expect(status.days == 3)
        #expect(!status.practicedToday)
    }

    @Test("One missed day a week is covered by a freeze")
    func freeze() {
        let status = StreakCalculator.status(practiceDays: [march(8), march(9), march(11), march(12)], now: march(12), calendar: iso)
        #expect(status.days == 4)
        #expect(status.frozenDays.map { iso.component(.day, from: $0) } == [10])
        #expect(!status.freezeAvailable)
    }

    @Test("A second missed day in the same week ends the streak")
    func secondGap() {
        let status = StreakCalculator.status(practiceDays: [march(10), march(12), march(14)], now: march(14), calendar: iso)
        #expect(status.days == 2)
        #expect(status.frozenDays.map { iso.component(.day, from: $0) } == [13])
    }

    @Test("Each week has its own freeze")
    func freezesInTwoWeeks() {
        let status = StreakCalculator.status(practiceDays: [march(6), march(8), march(9), march(11)], now: march(11), calendar: iso)
        #expect(status.days == 4)
        #expect(status.frozenDays.map { iso.component(.day, from: $0) } == [10, 7])
    }

    @Test("Two missed days in a row break the streak")
    func twoDayGap() {
        let status = StreakCalculator.status(practiceDays: [march(8), march(9)], now: march(12), calendar: iso)
        #expect(status.days == 0)
        #expect(status.frozenDays.isEmpty)
        #expect(status.freezeAvailable)
    }

    @Test("Missing yesterday uses the freeze while today is still open")
    func yesterdayMissed() {
        let status = StreakCalculator.status(practiceDays: [march(9), march(10)], now: march(12, hour: 9), calendar: iso)
        #expect(status.days == 2)
        #expect(status.frozenDays.map { iso.component(.day, from: $0) } == [11])
        #expect(!status.freezeAvailable)
        #expect(StreakCalculator.status(practiceDays: [], now: march(12), calendar: iso) == .none)
    }
}

@Suite("Achievements, challenges and reminders")
struct MotivationRulesTests {
    @Test("Achievements follow their thresholds")
    func achievements() {
        var inputs = AchievementInputs()
        #expect(AchievementKind.earned(inputs).isEmpty)
        inputs.sessionCount = 1
        inputs.streakDays = 7
        inputs.bestInTarget = 62
        inputs.completedLessonWeeks = 1
        inputs.totalMinutes = 299
        inputs.pitchGameBest = 10
        let earned = Set(AchievementKind.earned(inputs))
        #expect(earned == [.firstSession, .streak3, .streak7, .inTarget50, .firstWeek, .pitchGame10])
        inputs.totalMinutes = 300
        #expect(AchievementKind.hours5.isEarned(inputs))
        #expect(Set(AchievementKind.allCases.map(\.title)).count == AchievementKind.allCases.count)
    }

    @Test("The daily challenge is fixed for the day and changes the next day")
    func dailyChallenge() {
        let morning = DailyChallenge.challenge(for: march(10, hour: 1), calendar: iso)
        let evening = DailyChallenge.challenge(for: march(10, hour: 22), calendar: iso)
        let tomorrow = DailyChallenge.challenge(for: march(11), calendar: iso)
        #expect(morning == evening)
        #expect(morning != tomorrow)
        #expect(Set(DailyChallenge.all.map(\.id)).count == DailyChallenge.all.count)
        #expect(ChallengeStore.dayKey(march(10), calendar: iso) == "2026-03-10")
    }

    @Test("Challenge completion is remembered per day")
    func challengeStore() {
        let saved = UserDefaults.standard.stringArray(forKey: ChallengeStore.key)
        defer { UserDefaults.standard.set(saved, forKey: ChallengeStore.key) }
        UserDefaults.standard.removeObject(forKey: ChallengeStore.key)

        #expect(!ChallengeStore.isDone(on: march(10), calendar: iso))
        ChallengeStore.markDone(on: march(10), calendar: iso)
        ChallengeStore.markDone(on: march(10, hour: 20), calendar: iso)
        #expect(ChallengeStore.isDone(on: march(10), calendar: iso))
        #expect(!ChallengeStore.isDone(on: march(11), calendar: iso))
        #expect(ChallengeStore.doneDays().count == 1)
    }

    @Test("The evening nudge only comes if you haven't practiced")
    func nudge() {
        let today = NudgeScheduler.nextNudge(now: march(10, hour: 10), practicedToday: false, calendar: iso)
        #expect(today == march(10, hour: 19))
        let practiced = NudgeScheduler.nextNudge(now: march(10, hour: 10), practicedToday: true, calendar: iso)
        #expect(practiced == march(11, hour: 19))
        let late = NudgeScheduler.nextNudge(now: march(10, hour: 20), practicedToday: false, calendar: iso)
        #expect(late == march(11, hour: 19))
    }
}

@Suite("Balloon game")
struct PitchGameEngineTests {
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

    private func gate(_ id: Int, x: Double, center: Double = 0.5) -> PitchGameEngine.Gate {
        PitchGameEngine.Gate(id: id, x: x, gapCenter: center, gapHeight: 0.3)
    }

    @Test("Pitch maps to height in semitones, with the target in the middle")
    func heights() {
        let engine = PitchGameEngine(target: target)
        #expect(abs(engine.height(for: 180 * pow(2, -5.0 / 12)) - 0.05) < 1e-9)
        #expect(abs(engine.height(for: 220 * pow(2, 5.0 / 12)) - 0.95) < 1e-9)
        #expect(engine.height(for: 60) == 0)
        #expect(engine.height(for: 900) == 1)
        #expect(abs(engine.height(for: engine.pitch(forHeight: 0.5)) - 0.5) < 1e-9)
        #expect(abs(engine.targetBand.lowerBound - 0.384) < 0.001)
        #expect(abs(engine.targetBand.upperBound - 0.616) < 0.001)
    }

    @Test("Holding the gap's pitch passes it; bright resonance adds a bonus")
    func pass() {
        var engine = PitchGameEngine(target: target, gates: [gate(1, x: 0.3)])
        let middle = engine.pitch(forHeight: 0.5)
        engine.step(dt: 0.5, pitch: middle, resonance: 50)
        #expect(engine.score == 1)
        #expect(engine.lives == 3)
        #expect(engine.gates.count == 2)

        var bright = PitchGameEngine(target: target, gates: [gate(1, x: 0.3)])
        bright.step(dt: 0.5, pitch: middle, resonance: 80)
        #expect(bright.score == 2)
        #expect(bright.brightBonuses == 1)
    }

    @Test("Missing a gap costs a life, and three misses end the game")
    func misses() {
        var engine = PitchGameEngine(target: target, gates: [gate(1, x: 0.3)])
        let high = engine.pitch(forHeight: 0.95)
        engine.step(dt: 0.5, pitch: high, resonance: nil)
        #expect(engine.score == 0)
        #expect(engine.lives == 2)

        var over = PitchGameEngine(target: target, gates: [gate(1, x: 0.26, center: 0.1), gate(2, x: 0.27, center: 0.1), gate(3, x: 0.28, center: 0.1)])
        over.step(dt: 0.5, pitch: over.pitch(forHeight: 0.5), resonance: nil)
        #expect(over.lives == 0)
        #expect(over.isOver)
        let elapsed = over.elapsed
        over.step(dt: 0.5, pitch: nil, resonance: nil)
        #expect(over.elapsed == elapsed)
    }

    @Test("The balloon sinks in silence")
    func silence() {
        var engine = PitchGameEngine(target: target, gates: [gate(1, x: 0.9)])
        engine.step(dt: 1, pitch: nil, resonance: nil)
        #expect(abs(engine.balloonY - 0.35) < 1e-9)
        #expect(!engine.isHeard)
    }

    @Test("New gaps open around the target band")
    func spawning() throws {
        let engine = PitchGameEngine(target: target, seed: 42)
        let first = try #require(engine.gates.first)
        #expect(first.x == 1.1)
        #expect(first.gapCenter >= 0.33 && first.gapCenter <= 0.67)
        #expect(first.gapHeight == 0.32)
    }

    @Test("Scores keep the best")
    func scores() {
        let saved = UserDefaults.standard.data(forKey: PitchGameScores.key)
        defer { UserDefaults.standard.set(saved, forKey: PitchGameScores.key) }
        UserDefaults.standard.removeObject(forKey: PitchGameScores.key)

        #expect(PitchGameScores.save(5))
        #expect(!PitchGameScores.save(3))
        #expect(PitchGameScores.save(9))
        #expect(PitchGameScores.best == 9)
        #expect(PitchGameScores.all().map(\.score) == [5, 3, 9])
    }
}

@Suite("Widget snapshot and launch actions")
struct WidgetSnapshotTests {
    private func snapshot(updated: Date, practicedToday: Bool) -> WidgetSnapshot {
        WidgetSnapshot(streakDays: 6, practicedToday: practicedToday, freezeAvailable: true, todayMinutes: 9, goalMinutes: 15, challenge: nil, updated: updated)
    }

    @Test("Minutes reset at midnight; the streak waits a day")
    func dayChanges() {
        let practiced = snapshot(updated: march(10, hour: 9), practicedToday: true)
        #expect(practiced.minutes(on: march(10, hour: 20), calendar: iso) == 9)
        #expect(practiced.minutes(on: march(11), calendar: iso) == 0)
        #expect(abs(practiced.goalProgress(on: march(10), calendar: iso) - 0.6) < 1e-9)
        #expect(practiced.streak(on: march(10), calendar: iso) == 6)
        #expect(practiced.streak(on: march(11), calendar: iso) == 6)
        #expect(practiced.streak(on: march(12), calendar: iso) == 0)
        #expect(snapshot(updated: march(10), practicedToday: false).streak(on: march(11), calendar: iso) == 0)
    }

    @Test("A launch action is read once")
    func launchActions() {
        _ = LaunchActionStore.take()
        LaunchActionStore.request(.quickCheck)
        #expect(LaunchActionStore.take() == .quickCheck)
        #expect(LaunchActionStore.take() == nil)
    }
}
