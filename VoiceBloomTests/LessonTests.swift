import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

@Suite("Lesson catalog (Lessons.json)")
struct LessonCatalogTests {
    private func catalog() throws -> LessonCatalog {
        try LessonCatalog.load()
    }

    @Test("All 16 weeks load, in order, in the right phases")
    func weeksAndPhases() throws {
        let catalog = try catalog()
        #expect(catalog.weeks.map(\.week) == Array(1...16))
        #expect(catalog.totalWeeks == 16)
        let phaseOfWeek = Dictionary(uniqueKeysWithValues: catalog.weeks.map { ($0.week, $0.phase) })
        let expected: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 2, 5: 2, 6: 2, 7: 3, 8: 3, 9: 3, 10: 4, 11: 4, 12: 5, 13: 5, 14: 6, 15: 6, 16: 6]
        #expect(phaseOfWeek == expected)
    }

    @Test("Every week has full lesson content")
    func lessonContent() throws {
        for week in try catalog().weeks {
            #expect(!week.title.isEmpty)
            #expect(week.explanation.count > 80, "Week \(week.week) explanation is too short")
            #expect(!week.whyItMatters.isEmpty)
            #expect(week.steps.count >= 2)
            #expect(week.commonMistakes.count >= 2)
            #expect(week.howItShouldFeel.count >= 2)
            #expect(!week.exercises.isEmpty)
            #expect(!week.carryover.isEmpty)
            #expect(!week.goal.description.isEmpty)
        }
    }

    @Test("Goals follow the spec")
    func goals() throws {
        let catalog = try catalog()
        let week1 = try #require(catalog.week(1))
        #expect(week1.goal.kind == .sessions)
        #expect(week1.goal.count == 5)
        let week2 = try #require(catalog.week(2))
        #expect(week2.goal.kind == .pitchMatch)
        #expect(week2.goal.count == 8)
        #expect(week2.goal.total == 10)
        #expect(week2.commonMistakes.contains { $0.localizedCaseInsensitiveContains("volume") })
        let week6 = try #require(catalog.week(6))
        #expect(week6.goal.kind == .brightReading)
        #expect(week6.goal.threshold == 70)
        let week9 = try #require(catalog.week(9))
        #expect(week9.goal.kind == .targetAndBright)
        #expect(week9.goal.threshold == 70)
        #expect(week9.goal.requiresNoStrain == true)
        #expect(week9.commonMistakes.contains { $0.localizedCaseInsensitiveContains("falsetto") })
        let week11 = try #require(catalog.week(11))
        #expect(week11.goal.kind == .lightWeight)
        #expect(week11.goal.threshold == 60)
        let week16 = try #require(catalog.week(16))
        #expect(week16.goal.kind == .baseline)
    }

    @Test("Exercises have what their kind needs")
    func exercises() throws {
        let catalog = try catalog()
        let all = catalog.allExercises
        #expect(all.count >= 60)
        #expect(Set(all.map(\.id)).count == all.count)
        for exercise in all {
            #expect(!exercise.instructions.isEmpty, "\(exercise.id)")
            #expect(exercise.durationSeconds > 0)
            switch exercise.kind {
            case .hold:
                #expect(ResonanceMode(rawValue: exercise.vowel ?? "") != nil, "\(exercise.id)")
            case .reading:
                #expect(!(exercise.text ?? "").isEmpty, "\(exercise.id)")
            case .phrases:
                #expect(!(exercise.items ?? []).isEmpty, "\(exercise.id)")
            case .pitchMatch:
                #expect((exercise.toneCount ?? 0) > 0, "\(exercise.id)")
                #expect(exercise.toneMode != nil, "\(exercise.id)")
            case .timed, .glide, .scenario:
                break
            }
        }
        // Every skill filter has something in it.
        for skill in ExerciseSkill.allCases {
            #expect(all.contains { $0.skill == skill }, "No exercises for \(skill)")
        }
        #expect(all.contains { $0.isQuiet })
    }

    @Test("Maintenance mode has routines and challenges")
    func maintenance() throws {
        let plan = try catalog().maintenance
        #expect(plan.routines.count >= 4)
        #expect(!plan.weeklyChallenges.isEmpty)
        #expect(plan.routine(focus: .resonance, dayOfYear: 1)?.id == "resonance")
        #expect(plan.routine(focus: .weight, dayOfYear: 1)?.id == "weight")
        #expect(plan.routine(focus: nil, dayOfYear: 1) != nil)
        #expect(plan.weeklyChallenge(weekOfYear: 40) != nil)
    }

    @Test("Broken JSON gives a readable error")
    func brokenJSON() {
        #expect(throws: LessonCatalog.LoadError.self) {
            _ = try LessonCatalog.decode(Data("{\"version\": 1}".utf8))
        }
    }
}

@Suite("SessionPlanner")
struct SessionPlannerTests {
    private func week() throws -> (LessonWeek, LessonCatalog) {
        let catalog = try LessonCatalog.load()
        return (try #require(catalog.week(4)), catalog)
    }

    @Test("Quick, Standard and Deep add up to 5, 15 and 25 minutes", arguments: [SessionLength.quick, .standard, .deep])
    func lengths(length: SessionLength) throws {
        let (week, catalog) = try week()
        let steps = SessionPlanner.plan(week: week, length: length, catalog: catalog)
        #expect(steps.reduce(0) { $0 + $1.seconds } == length.minutes * 60)
        #expect(steps.allSatisfy { $0.seconds >= SessionPlanner.minimumStepSeconds })
        #expect(steps.map(\.id) == Array(0..<steps.count))
        // Phases come in order: warm-up, main, carryover, cool-down.
        let phases = steps.map(\.phase)
        let order: [SessionPhase] = [.warmUp, .main, .carryover, .coolDown]
        #expect(phases == phases.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) })
        #expect(Set(phases) == Set(order))
    }

    @Test("Standard follows the template: warm-up 2–3, main 8–15, carryover 2–3, cool-down 1–2 minutes")
    func standardTemplate() {
        let seconds = Dictionary(uniqueKeysWithValues: SessionPlanner.phaseSeconds(for: .standard))
        #expect((120...180).contains(seconds[.warmUp] ?? 0))
        #expect((480...900).contains(seconds[.main] ?? 0))
        #expect((120...180).contains(seconds[.carryover] ?? 0))
        #expect((60...120).contains(seconds[.coolDown] ?? 0))
    }

    @Test("Main practice uses the week’s exercises")
    func mainExercises() throws {
        let (week, catalog) = try week()
        let steps = SessionPlanner.plan(week: week, length: .standard, catalog: catalog)
        let mainIDs = Set(steps.filter { $0.phase == .main }.map(\.exercise.id))
        #expect(mainIDs.isSubset(of: Set(week.exercises.map(\.id))))
        #expect(!mainIDs.isEmpty)
    }

    @Test("Maintenance and single-exercise plans")
    func otherPlans() throws {
        let catalog = try LessonCatalog.load()
        let routine = try #require(catalog.maintenance.routines.first)
        let steps = SessionPlanner.plan(routine: routine, catalog: catalog, minutes: 8)
        #expect(steps.reduce(0) { $0 + $1.seconds } == 480)
        let single = SessionPlanner.single(routine.exercises[0])
        #expect(single.count == 1)
    }

    @Test("Pitch-match tones")
    func tones() throws {
        let target = PitchTargetZone(lowerBound: 180, upperBound: 220)
        let comfortable = SessionPlanner.tones(mode: .comfortable, count: 10, baseline: 120, target: target)
        #expect(comfortable.count == 10)
        let low = try #require(comfortable.min())
        let high = try #require(comfortable.max())
        #expect(abs(low - 120) < 1e-9)
        #expect(abs(high - target.center) < 1e-9)
        #expect(comfortable != comfortable.sorted())

        let stepUp = SessionPlanner.tones(mode: .stepUp, count: 6, baseline: 150, target: target)
        #expect(stepUp == [160, 165, 170, 160, 165, 170])

        let inTarget = SessionPlanner.tones(mode: .target, count: 5, baseline: nil, target: target)
        #expect(inTarget.allSatisfy { $0 >= 180 - 1e-9 && $0 <= 220 + 1e-9 })

        // No baseline: assume a typical starting point.
        let noBaseline = SessionPlanner.tones(mode: .stepUp, count: 1, baseline: nil, target: target)
        #expect(noBaseline == [140])
        #expect(SessionPlanner.tones(mode: .target, count: 0, baseline: nil, target: target).isEmpty)
    }
}

@Suite("Lesson unlock rules")
struct LessonUnlockRulesTests {
    private func progress(_ week: Int, sessions: Int = 0, goal: Bool = false, unlocked: Date? = nil) -> LessonProgressValues {
        LessonProgressValues(week: week, sessionsCompleted: sessions, goalMet: goal, unlockedDate: unlocked)
    }

    @Test("Week 1 is always open; the next needs 5 sessions and the goal")
    func unlocking() {
        #expect(LessonUnlockRules.isUnlocked(week: 1, progress: [:]))
        #expect(!LessonUnlockRules.isUnlocked(week: 2, progress: [:]))
        #expect(!LessonUnlockRules.isUnlocked(week: 2, progress: [1: progress(1, sessions: 5)]))
        #expect(!LessonUnlockRules.isUnlocked(week: 2, progress: [1: progress(1, sessions: 4, goal: true)]))
        #expect(LessonUnlockRules.isUnlocked(week: 2, progress: [1: progress(1, sessions: 5, goal: true)]))
        #expect(!LessonUnlockRules.isUnlocked(week: 3, progress: [1: progress(1, sessions: 5, goal: true)]))
    }

    @Test("Placement and debug unlocks")
    func explicitUnlocks() {
        let placed = [7: progress(7, unlocked: Date())]
        #expect(LessonUnlockRules.isUnlocked(week: 7, progress: placed))
        #expect(LessonUnlockRules.isUnlocked(week: 12, progress: [:], unlockAll: true))
    }

    @Test("The current week is the first unfinished one from the starting week")
    func currentWeek() {
        #expect(LessonUnlockRules.currentWeek(progress: [:], totalWeeks: 16) == 1)
        let afterWeek1 = [1: progress(1, sessions: 6, goal: true)]
        #expect(LessonUnlockRules.currentWeek(progress: afterWeek1, totalWeeks: 16) == 2)
        var placement: [Int: LessonProgressValues] = [:]
        for week in 1...7 {
            placement[week] = progress(week, unlocked: Date())
        }
        #expect(LessonUnlockRules.currentWeek(progress: placement, totalWeeks: 16) == 7)
        placement[7] = progress(7, sessions: 5, goal: true, unlocked: Date())
        #expect(LessonUnlockRules.currentWeek(progress: placement, totalWeeks: 16) == 8)
    }

    @Test("Maintenance opens after week 16")
    func maintenance() {
        #expect(!LessonUnlockRules.isMaintenanceUnlocked(progress: [:], totalWeeks: 16))
        #expect(LessonUnlockRules.isMaintenanceUnlocked(progress: [16: progress(16, sessions: 5, goal: true)], totalWeeks: 16))
        #expect(LessonUnlockRules.isMaintenanceUnlocked(progress: [:], totalWeeks: 16, unlockAll: true))
    }
}

@Suite("Lesson goals")
struct LessonGoalEvaluatorTests {
    private func take(
        median: Double? = 190,
        inTarget: Double? = 75,
        bright: Double? = 72,
        light: Double? = 65,
        intonation: Double? = 62
    ) -> TakeResult {
        TakeResult(
            duration: 30, voicedDuration: 20, averagePitch: median, medianPitch: median, lowPitch: 170, highPitch: 230,
            percentInTarget: inTarget, f1: 600, f2: 1_900, f3: 2_900, resonanceScore: 70, brightResonancePercent: bright,
            h1MinusH2: 10, spectralTilt: -7, weightScore: 66, lightWeightPercent: light, intonationSD: 3.4,
            intonationScore: intonation, phraseCount: 3, contour: [], pitchHistogram: []
        )
    }

    private func goal(_ kind: LessonGoal.Kind, _ threshold: Double? = nil, secondary: Double? = nil, count: Int? = nil, total: Int? = nil, noStrain: Bool? = nil) -> LessonGoal {
        LessonGoal(kind: kind, description: "", threshold: threshold, secondaryThreshold: secondary, count: count, total: total, requiresNoStrain: noStrain)
    }

    private func isMet(_ goal: LessonGoal, _ outcome: ExerciseOutcome, baseline: Double? = 150, sore: Int = 0) -> Bool {
        LessonGoalEvaluator.isMet(goal, by: outcome, baselinePitch: baseline, recentSoreReports: sore)
    }

    @Test("Pitch matching needs enough matches out of the full set")
    func pitchMatch() {
        let weekGoal = goal(.pitchMatch, count: 8, total: 10)
        #expect(isMet(weekGoal, ExerciseOutcome(kind: .pitchMatch, pitchMatches: 8, pitchAttempts: 10)))
        #expect(!isMet(weekGoal, ExerciseOutcome(kind: .pitchMatch, pitchMatches: 7, pitchAttempts: 10)))
        #expect(!isMet(weekGoal, ExerciseOutcome(kind: .pitchMatch, pitchMatches: 6, pitchAttempts: 6)))
    }

    @Test("Resonance goals use the right kind of exercise")
    func resonance() {
        #expect(isMet(goal(.brightHold, 60), ExerciseOutcome(kind: .hold, take: take(bright: 61))))
        #expect(!isMet(goal(.brightHold, 60), ExerciseOutcome(kind: .reading, take: take(bright: 90))))
        #expect(isMet(goal(.brightReading, 70), ExerciseOutcome(kind: .reading, take: take(bright: 72))))
        #expect(!isMet(goal(.brightReading, 70), ExerciseOutcome(kind: .reading, take: take(bright: 69))))
    }

    @Test("Pitch raise is measured from the baseline")
    func pitchRaise() {
        #expect(isMet(goal(.pitchRaise, 15), ExerciseOutcome(kind: .reading, take: take(median: 166)), baseline: 150))
        #expect(!isMet(goal(.pitchRaise, 15), ExerciseOutcome(kind: .reading, take: take(median: 160)), baseline: 150))
    }

    @Test("Stability needs time in target, bright resonance and no strain")
    func stability() {
        let weekGoal = goal(.targetAndBright, 70, secondary: 60, noStrain: true)
        #expect(isMet(weekGoal, ExerciseOutcome(kind: .reading, take: take(inTarget: 75, bright: 65))))
        #expect(!isMet(weekGoal, ExerciseOutcome(kind: .reading, take: take(inTarget: 75, bright: 65)), sore: 1))
        #expect(!isMet(weekGoal, ExerciseOutcome(kind: .reading, take: take(inTarget: 65, bright: 65))))
        #expect(!isMet(weekGoal, ExerciseOutcome(kind: .reading, take: take(inTarget: 75, bright: 55))))
    }

    @Test("Weight and intonation goals")
    func weightAndIntonation() {
        #expect(isMet(goal(.lightWeight, 60), ExerciseOutcome(kind: .reading, take: take(light: 60))))
        #expect(!isMet(goal(.lightWeight, 60), ExerciseOutcome(kind: .reading, take: take(light: nil))))
        #expect(isMet(goal(.intonation, 60), ExerciseOutcome(kind: .phrases, take: take(intonation: 61))))
        #expect(!isMet(goal(.intonation, 60), ExerciseOutcome(kind: .phrases, take: take(intonation: 59))))
    }

    @Test("Session, scenario and baseline goals aren't met by a single exercise")
    func countedGoals() {
        let outcome = ExerciseOutcome(kind: .reading, take: take())
        #expect(!isMet(goal(.sessions, count: 5), outcome))
        #expect(!isMet(goal(.scenarios, count: 3), outcome))
        #expect(!isMet(goal(.baseline), outcome))
    }

    @Test("Feedback text")
    func feedback() {
        let target = PitchTargetZone(lowerBound: 180, upperBound: 220)
        #expect(LessonGoalEvaluator.summary(of: ExerciseOutcome(kind: .pitchMatch, pitchMatches: 7, pitchAttempts: 10), target: target) == "Matched 7 of 10 tones.")
        #expect(LessonGoalEvaluator.summary(of: ExerciseOutcome(kind: .reading, take: take()), target: target).contains("75% in target"))
        #expect(LessonGoalEvaluator.summary(of: ExerciseOutcome(kind: .hold, take: take(bright: 80)), target: target).contains("Bright 80%"))
    }
}

/// Lesson progress and lesson sessions in an in-memory store.
@MainActor
@Suite("Lesson progress storage", .serialized)
struct LessonProgressStoreTests {
    let container: ModelContainer
    let catalog: LessonCatalog

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
        catalog = try LessonCatalog.load()
    }

    private var store: LessonProgressStore { LessonProgressStore(context: container.mainContext) }

    @Test("Five week-1 sessions meet the goal and unlock week 2")
    func weekOneCompletes() throws {
        let week1 = try #require(catalog.week(1))
        for _ in 0..<4 {
            try store.recordSession(week: week1)
        }
        let before = store.values()
        #expect(before[1]?.sessionsCompleted == 4)
        #expect(before[1]?.goalMet == false)
        #expect(!LessonUnlockRules.isUnlocked(week: 2, progress: before))

        try store.recordSession(week: week1)
        let after = store.values()
        #expect(after[1]?.goalMet == true)
        #expect(after[1]?.completedDate != nil)
        #expect(after[2]?.unlockedDate != nil)
        #expect(LessonUnlockRules.isUnlocked(week: 2, progress: after))
    }

    @Test("A measured goal plus five sessions completes the week")
    func measuredGoal() throws {
        let week2 = try #require(catalog.week(2))
        try store.markGoalMet(week: 2)
        #expect(store.values()[2]?.completedDate == nil)
        for _ in 0..<5 {
            try store.recordSession(week: week2)
        }
        let values = store.values()
        #expect(values[2]?.completedDate != nil)
        #expect(values[3]?.unlockedDate != nil)
    }

    @Test("Scenario practice meets the week 14 goal")
    func scenarioGoal() throws {
        let week14 = try #require(catalog.week(14))
        let unlocked = Date(timeIntervalSince1970: 1_773_100_800)
        store.progress(week: 14).unlockedDate = unlocked
        try store.evaluateScenarioGoal(week: week14, scenarioDates: [unlocked.addingTimeInterval(-60), unlocked.addingTimeInterval(60)])
        #expect(store.values()[14]?.goalMet == false)
        try store.evaluateScenarioGoal(week: week14, scenarioDates: (1...3).map { unlocked.addingTimeInterval(Double($0) * 3_600) })
        #expect(store.values()[14]?.goalMet == true)
    }

    @Test("Lesson sessions are saved with their kind and week")
    func lessonSessionKind() throws {
        var stats = VoiceSessionStats()
        for index in 0..<400 {
            stats.pitch.add(FrameFixture.frame(time: Double(index) * 0.01, frequency: 200), target: .feminine)
        }
        let snapshot = SessionSnapshot(
            id: UUID(), startDate: Date(), activeDuration: 300, frameInterval: 0.01, stats: stats,
            voiceQuality: nil, target: .feminine, resonanceMode: .speech, slipAlertCount: 0, strainWarningCount: 0
        )
        let sessions = SessionStore(context: container.mainContext)
        let savedSession = try sessions.save(snapshot, finished: true, kind: .lesson, lessonID: "week-3")
        let saved = try #require(savedSession)
        #expect(saved.kind == .lesson)
        #expect(saved.lessonID == "week-3")
        let minutes = sessions.minutesPracticed(on: Date())
        #expect(abs(minutes - 5) < 1e-9)
    }
}
