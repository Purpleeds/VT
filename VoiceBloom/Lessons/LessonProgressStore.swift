import Foundation
import SwiftData

/// Reads and updates `LessonProgress` (sessions completed, goal met, unlocks).
@MainActor
struct LessonProgressStore {
    let context: ModelContext

    /// Debug: every week (and maintenance) available.
    static let unlockAllKey = "lessons.unlockAll"

    static var unlockAll: Bool {
        get { UserDefaults.standard.bool(forKey: unlockAllKey) }
        set { UserDefaults.standard.set(newValue, forKey: unlockAllKey) }
    }

    func progress(week: Int) -> LessonProgress {
        let descriptor = FetchDescriptor<LessonProgress>(predicate: #Predicate<LessonProgress> { $0.week == week })
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        let created = LessonProgress(week: week)
        context.insert(created)
        return created
    }

    /// Progress for every week, as plain values.
    func values() -> [Int: LessonProgressValues] {
        let all = (try? context.fetch(FetchDescriptor<LessonProgress>())) ?? []
        var result: [Int: LessonProgressValues] = [:]
        for progress in all {
            // Merge duplicates (shouldn't happen) by taking the most progress.
            var value = result[progress.week] ?? LessonProgressValues(week: progress.week)
            value.sessionsCompleted = max(value.sessionsCompleted, progress.sessionsCompleted)
            value.goalMet = value.goalMet || progress.goalMet
            value.unlockedDate = value.unlockedDate ?? progress.unlockedDate
            value.completedDate = value.completedDate ?? progress.completedDate
            result[progress.week] = value
        }
        return result
    }

    /// Counts a finished guided session for a week.
    func recordSession(week: LessonWeek, now: Date = Date()) throws {
        let progress = progress(week: week.week)
        progress.sessionsCompleted += 1
        progress.lastPracticedDate = now
        if week.goal.kind == .sessions, progress.sessionsCompleted >= (week.goal.count ?? LessonUnlockRules.requiredSessions) {
            progress.goalMet = true
        }
        markCompletionIfNeeded(progress, week: week.week, now: now)
        try context.save()
    }

    /// Records that the week's goal was reached.
    func markGoalMet(week: Int, now: Date = Date()) throws {
        let progress = progress(week: week)
        guard !progress.goalMet else { return }
        progress.goalMet = true
        progress.lastPracticedDate = now
        markCompletionIfNeeded(progress, week: week, now: now)
        try context.save()
    }

    /// Scenario goals: met once enough scenarios were practiced since the
    /// week became available.
    func evaluateScenarioGoal(week: LessonWeek, scenarioDates: [Date], now: Date = Date()) throws {
        guard week.goal.kind == .scenarios else { return }
        let progress = progress(week: week.week)
        guard !progress.goalMet else { return }
        let since = progress.unlockedDate ?? .distantPast
        if scenarioDates.filter({ $0 >= since }).count >= (week.goal.count ?? 3) {
            try markGoalMet(week: week.week, now: now)
        }
    }

    /// When a week is complete, the next one unlocks.
    private func markCompletionIfNeeded(_ progress: LessonProgress, week: Int, now: Date) {
        guard progress.completedDate == nil,
              progress.goalMet,
              progress.sessionsCompleted >= LessonUnlockRules.requiredSessions
        else { return }
        progress.completedDate = now
        let next = self.progress(week: week + 1)
        if next.unlockedDate == nil {
            next.unlockedDate = now
        }
    }
}
