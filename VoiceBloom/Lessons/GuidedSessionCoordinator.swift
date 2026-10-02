import Foundation
import Observation
import SwiftData

/// The lesson plan, loaded once.
@MainActor
enum LessonLibrary {
    static let result: Result<LessonCatalog, Error> = Result { try LessonCatalog.load() }

    static var catalog: LessonCatalog? {
        try? result.get()
    }

    static var loadError: String? {
        if case .failure(let error) = result {
            return error.localizedDescription
        }
        return nil
    }
}

/// Starts and ends guided sessions from anywhere in the app (lessons,
/// maintenance, single exercises), and presents the player full screen.
@MainActor
@Observable
final class GuidedSessionCoordinator {
    /// The session being played.
    private(set) var active: GuidedSessionModel?
    /// Drives the full-screen player.
    var isPresenting = false
    /// A session waiting for confirmation because today's practice is over
    /// the 45-minute soft cap.
    var softCapPlan: GuidedSessionPlan?
    var isShowingSoftCapAlert = false

    let controller: PracticeSessionController
    private let context: ModelContext

    init(controller: PracticeSessionController, container: ModelContainer) {
        self.controller = controller
        context = container.mainContext
    }

    /// Starts a session, first checking the daily soft cap.
    func request(_ plan: GuidedSessionPlan) {
        guard active == nil else { return }
        if controller.minutesPracticedToday() >= PracticeSessionController.dailySoftCapMinutes {
            softCapPlan = plan
            isShowingSoftCapAlert = true
        } else {
            Task { await start(plan) }
        }
    }

    func confirmSoftCap() {
        guard let plan = softCapPlan else { return }
        softCapPlan = nil
        Task { await start(plan) }
    }

    private func start(_ plan: GuidedSessionPlan) async {
        let kind: PracticeSessionKind
        switch plan.source {
        case .lesson, .maintenance: kind = .lesson
        case .exercise: kind = .freePractice
        }
        await controller.beginGuidedSession(kind: kind, lessonID: plan.source.lessonID)

        let profile = ProfileStore(context: context).profile()
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let soreReports = ((try? SessionStore(context: context).comfortReports(since: weekAgo)) ?? []).filter { $0.comfort == .sore }.count

        let goalWeek: Int?
        if case .lesson(let week) = plan.source {
            goalWeek = week
        } else {
            goalWeek = nil
        }
        let context = context
        active = GuidedSessionModel(
            plan: plan,
            monitor: controller.monitor,
            target: profile.targetZone,
            references: profile.personalReferences,
            baselinePitch: profile.baselinePitch,
            recentSoreReports: soreReports,
            onGoalMet: {
                guard let goalWeek else { return }
                try? LessonProgressStore(context: context).markGoalMet(week: goalWeek)
            }
        )
        isPresenting = true
    }

    /// Called when the player closes: counts the session toward its week
    /// and saves it (which brings up the check-in).
    func didDismiss() async {
        guard let model = active else { return }
        active = nil
        model.finish()
        if case .lesson(let weekNumber) = model.plan.source,
           model.countsAsCompleted,
           let week = LessonLibrary.catalog?.week(weekNumber) {
            try? LessonProgressStore(context: context).recordSession(week: week)
        }
        await controller.endGuidedSession()
    }
}
