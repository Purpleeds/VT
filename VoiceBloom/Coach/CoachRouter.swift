import Foundation
import SwiftData

/// An answer and which coach produced it.
nonisolated struct CoachOutcome<Value: Sendable>: Sendable {
    let value: Value
    let engine: CoachEngine
    /// Set when the AI coach failed and the simple tips were used instead.
    let fallbackNote: String?
}

/// Picks the coach from Settings and falls back to `RuleBasedCoach` when the
/// AI fails, so every feature always works.
@MainActor
enum CoachRouter {
    static func hasGeminiKey() -> Bool {
        !(KeychainStore.string(account: KeychainStore.geminiAPIKeyAccount) ?? "").isEmpty
    }

    /// The coach Settings choose right now.
    static func engine(enabled: Bool) -> CoachEngine {
        CoachEngine.choose(
            enabled: enabled,
            provider: AppPreferences.aiProvider,
            onDeviceAvailable: FoundationModelsCoach.isAvailable,
            hasGeminiKey: hasGeminiKey()
        )
    }

    static func service(for engine: CoachEngine) -> any AICoachService {
        switch engine {
        case .onDevice:
            return FoundationModelsCoach()
        case .gemini:
            if let key = KeychainStore.string(account: KeychainStore.geminiAPIKeyAccount), !key.isEmpty {
                return GeminiCoach(apiKey: key)
            }
            return RuleBasedCoach()
        case .rules:
            return RuleBasedCoach()
        }
    }

    /// Runs `work` with the chosen coach; on any error runs it with the
    /// rule-based coach instead.
    static func run<Value: Sendable>(
        enabled: Bool,
        _ work: (any AICoachService) async throws -> Value
    ) async -> CoachOutcome<Value>? {
        let engine = engine(enabled: enabled)
        do {
            let value = try await work(service(for: engine))
            return CoachOutcome(value: value, engine: engine, fallbackNote: nil)
        } catch {
            guard engine != .rules else { return nil }
            do {
                let value = try await work(RuleBasedCoach())
                let reason = (error as? CoachError)?.errorDescription ?? error.localizedDescription
                return CoachOutcome(value: value, engine: .rules, fallbackNote: "\(reason) Showing simple tips instead.")
            } catch {
                return nil
            }
        }
    }

    /// Whether the user has the AI Coach switched on.
    static func isEnabled(context: ModelContext) -> Bool {
        ProfileStore(context: context).profile().aiCoachEnabled
    }
}

/// Builds coach contexts from stored data (plain values only).
@MainActor
enum CoachContextBuilder {
    static func stats(_ session: PracticeSession) -> CoachSessionStats {
        CoachSessionStats(
            minutes: session.duration / 60,
            averagePitch: session.averagePitch,
            percentInTarget: session.percentInTarget,
            resonance: session.resonanceScore,
            weight: session.weightScore,
            intonation: session.intonationScore,
            slipAlerts: session.slipAlertCount,
            strainWarnings: session.strainWarningCount,
            comfort: session.comfortRawValue
        )
    }

    /// Exercises the coach may recommend (one or two per skill).
    static func exerciseOptions() -> [CoachExerciseOption] {
        guard let catalog = LessonLibrary.catalog else { return [] }
        var perSkill: [String: Int] = [:]
        var options: [CoachExerciseOption] = []
        for exercise in catalog.allExercises where exercise.skill != .coolDown {
            let count = perSkill[exercise.skill.rawValue, default: 0]
            guard count < 2 else { continue }
            perSkill[exercise.skill.rawValue] = count + 1
            options.append(CoachExerciseOption(id: exercise.id, title: exercise.title, skill: exercise.skill.rawValue))
        }
        return options
    }

    static func sessionContext(for session: PracticeSession, context: ModelContext) -> CoachSessionContext {
        let start = session.startDate
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.startDate < start && $0.endDate != nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        let recent = ((try? context.fetch(descriptor)) ?? []).map(stats)
        return CoachSessionContext(session: stats(session), recent: recent, target: session.targetZone, exercises: exerciseOptions())
    }

    static func weeklyContext(context: ModelContext, now: Date = Date()) -> WeeklyReviewContext? {
        guard let catalog = LessonLibrary.catalog else { return nil }
        let progress = LessonProgressStore(context: context).values()
        let unlockAll = UserDefaults.standard.bool(forKey: LessonProgressStore.unlockAllKey)
        let current = LessonUnlockRules.currentWeek(progress: progress, totalWeeks: catalog.totalWeeks, unlockAll: unlockAll)
        guard let week = catalog.week(current) else { return nil }
        let profile = ProfileStore(context: context).profile()

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 86_400)
        let descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.startDate >= twoWeeksAgo }
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        let thisWeek = sessions.filter { $0.startDate >= weekAgo }
        let lastWeek = sessions.filter { $0.startDate < weekAgo }

        func averages(_ list: [PracticeSession]) -> [ProgressMetric: Double] {
            var result: [ProgressMetric: Double] = [:]
            for metric in ProgressMetric.allCases {
                let values = list.compactMap { stats($0).value(metric) }
                if !values.isEmpty {
                    result[metric] = values.reduce(0, +) / Double(values.count)
                }
            }
            return result
        }

        let values = progress[current]
        return WeeklyReviewContext(
            week: current,
            weekTitle: week.title,
            sessionsThisWeek: values?.sessionsCompleted ?? 0,
            requiredSessions: LessonUnlockRules.requiredSessions,
            goalMet: values?.goalMet ?? false,
            goalDescription: week.goal.description,
            practiceMinutes: thisWeek.reduce(0) { $0 + $1.duration } / 60,
            dailyGoalMinutes: profile.dailyGoalMinutes,
            averages: averages(thisWeek),
            previousAverages: averages(lastWeek),
            soreCheckIns: thisWeek.filter { $0.comfort == .sore }.count,
            isLastWeek: current >= catalog.totalWeeks
        )
    }
}
