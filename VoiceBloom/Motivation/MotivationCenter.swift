import Foundation
import SwiftData
import UserNotifications
import WidgetKit

/// Streak, achievements, the widgets and the evening nudge, refreshed from
/// the stored practice (SPEC section 12).
@MainActor
enum MotivationCenter {
    static let nudgeKey = "reminders.eveningNudge"
    /// Sessions shorter than this don't count as a practice day.
    static let minimumSessionSeconds = 60.0

    static var isNudgeEnabled: Bool {
        (UserDefaults.standard.object(forKey: nudgeKey) as? Bool) ?? true
    }

    static func practiceDays(context: ModelContext) -> [Date] {
        let minimum = minimumSessionSeconds
        let descriptor = FetchDescriptor<PracticeSession>(predicate: #Predicate<PracticeSession> { $0.duration >= minimum })
        return ((try? context.fetch(descriptor)) ?? []).map(\.startDate)
    }

    static func streak(context: ModelContext, now: Date = Date()) -> StreakStatus {
        StreakCalculator.status(practiceDays: practiceDays(context: context), now: now)
    }

    static func todayMinutes(context: ModelContext, now: Date = Date()) -> Double {
        SessionStore(context: context).minutesPracticed(on: now)
    }

    static func inputs(context: ModelContext, streak: StreakStatus) -> AchievementInputs {
        let sessions = (try? context.fetch(FetchDescriptor<PracticeSession>())) ?? []
        let practiced = sessions.filter { $0.duration >= minimumSessionSeconds }
        let scenarios = (try? context.fetch(FetchDescriptor<ScenarioResult>())) ?? []
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        let progress = LessonProgressStore(context: context).values()
        var inputs = AchievementInputs()
        inputs.sessionCount = practiced.filter(\.isFinished).count
        inputs.totalMinutes = sessions.reduce(0) { $0 + $1.duration } / 60
        inputs.streakDays = streak.days
        inputs.completedLessonWeeks = progress.values.filter { $0.completedDate != nil }.count
        inputs.bestInTarget = sessions.filter { $0.voicedDuration >= 60 }.compactMap(\.percentInTarget).max() ?? 0
        inputs.scenarioCount = scenarios.count
        inputs.hardScenarioCount = scenarios.filter { $0.difficulty == .hard }.count
        inputs.clipCount = recordings.filter { $0.kind == .clip }.count
        inputs.journalEntries = (try? context.fetchCount(FetchDescriptor<DailyJournalEntry>())) ?? 0
        inputs.quickChecks = sessions.filter { $0.kind == .quickCheck }.count
        inputs.targetVoices = (try? context.fetchCount(FetchDescriptor<TargetVoiceProfile>())) ?? 0
        inputs.pitchGameBest = PitchGameScores.best
        inputs.challengesDone = ChallengeStore.doneDays().count
        return inputs
    }

    /// Unlocks new achievements, updates the widgets and reschedules the
    /// nudge. Returns the achievements unlocked just now.
    @discardableResult
    static func refresh(context: ModelContext, now: Date = Date()) -> [AchievementKind] {
        let streak = streak(context: context, now: now)
        let unlocked = unlockAchievements(context: context, inputs: inputs(context: context, streak: streak), now: now)
        let profile = ProfileStore(context: context).profile()
        updateWidgets(streak: streak, todayMinutes: todayMinutes(context: context, now: now), goal: profile.dailyGoalMinutes, now: now)
        Task {
            await scheduleNudge(enabled: profile.reminderTime != nil && isNudgeEnabled, practicedToday: streak.practicedToday, now: now)
        }
        return unlocked
    }

    static func unlockAchievements(context: ModelContext, inputs: AchievementInputs, now: Date = Date()) -> [AchievementKind] {
        let stored = Set(((try? context.fetch(FetchDescriptor<Achievement>())) ?? []).map(\.identifier))
        let new = AchievementKind.earned(inputs).filter { !stored.contains($0.rawValue) }
        guard !new.isEmpty else { return [] }
        for kind in new {
            context.insert(Achievement(identifier: kind.rawValue, unlockedDate: now))
        }
        try? context.save()
        return new
    }

    static func updateWidgets(streak: StreakStatus, todayMinutes: Double, goal: Int, now: Date) {
        let snapshot = WidgetSnapshot(
            streakDays: streak.days,
            practicedToday: streak.practicedToday,
            freezeAvailable: streak.freezeAvailable,
            todayMinutes: todayMinutes,
            goalMinutes: goal,
            challenge: DailyChallenge.challenge(for: now).title,
            updated: now
        )
        guard snapshot != WidgetSnapshot.load() else { return }
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    static let nudgeID = "evening-nudge"

    /// One gentle evening reminder if you haven't practiced yet (never
    /// guilt-tripping, neutral wording).
    static func scheduleNudge(enabled: Bool, practicedToday: Bool, now: Date) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [nudgeID])
        guard enabled,
              await center.notificationSettings().authorizationStatus == .authorized,
              let date = NudgeScheduler.nextNudge(now: now, practicedToday: practicedToday)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for practice"
        content.body = "Even five easy minutes count. Or take a rest day; that’s part of practice too."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: nudgeID,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await center.add(request)
    }
}
