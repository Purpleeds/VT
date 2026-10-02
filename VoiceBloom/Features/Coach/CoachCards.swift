import Foundation
import SwiftData
import SwiftUI

/// "Coach" label with the engine that wrote the advice.
struct CoachEngineLabel: View {
    let engine: CoachEngine

    var body: some View {
        Label(engine.isAI ? engine.title : "Simple tips", systemImage: engine.isAI ? "sparkles" : "lightbulb")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Post-session feedback (SPEC section 10): 2–3 tips and one exercise,
/// from the session's stats and the trend over the last 5 sessions.
struct CoachFeedbackCard: View {
    let session: PracticeSession
    /// Generate as soon as the card appears (the check-in sheet).
    var generatesAutomatically = false
    /// Show a link to the recommended exercise (not inside sheets).
    var linksToExercise = true

    @Environment(\.modelContext) private var modelContext
    @State private var isLoading = false
    @State private var note: String?

    private var feedback: CoachFeedback? { CoachFeedback.decode(session.aiFeedback) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coach", systemImage: "figure.mind.and.body")
                    .font(.headline)
                Spacer()
                if let feedback, let engine = CoachEngine(rawValue: feedback.engine) {
                    CoachEngineLabel(engine: engine)
                }
            }

            if let feedback {
                Text(feedback.summary)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(feedback.tips.enumerated()), id: \.offset) { _, tip in
                    Label {
                        Text(tip)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.targetZone)
                    }
                    .font(.subheadline)
                }
                if let id = feedback.exerciseID, let title = feedback.exerciseTitle {
                    if linksToExercise, let exercise = LessonLibrary.catalog?.allExercises.first(where: { $0.id == id }) {
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            Label("Try next: \(title)", systemImage: "arrow.right.circle")
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        Label("Try next: \(title)", systemImage: "arrow.right.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                if !generatesAutomatically {
                    Button("Refresh") {
                        Task { await generate() }
                    }
                    .font(.footnote)
                    .disabled(isLoading)
                }
            } else if isLoading {
                ProgressView("Thinking about your session…")
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await generate() }
                } label: {
                    Label("Get Coach Feedback", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task {
            if generatesAutomatically, feedback == nil {
                await generate()
            }
        }
    }

    private func generate() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let coachContext = CoachContextBuilder.sessionContext(for: session, context: modelContext)
        let enabled = CoachRouter.isEnabled(context: modelContext)
        guard let outcome = await CoachRouter.run(enabled: enabled, { service in
            try await service.sessionFeedback(coachContext)
        }) else { return }
        session.aiFeedback = outcome.value.encoded()
        try? modelContext.save()
        note = outcome.fallbackNote
    }
}

/// Weekly review (SPEC section 10): move on, repeat the week, practice a
/// weak skill, or rest.
struct WeeklyReviewCard: View {
    @Environment(\.modelContext) private var modelContext
    @State private var review: WeeklyReview? = WeeklyReviewStore.recent()
    @State private var isLoading = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Weekly review", systemImage: "calendar.badge.checkmark")
                    .font(.headline)
                Spacer()
                if let review, let engine = CoachEngine(rawValue: review.engine) {
                    CoachEngineLabel(engine: engine)
                }
            }
            if let review {
                Label(review.recommendation.title, systemImage: review.recommendation.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(review.recommendation == .rest ? Theme.warning : Theme.targetZone)
                Text(review.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let focus = review.focusMetric {
                    Text("Focus: \(focus.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button("Review Again") {
                    Task { await generate() }
                }
                .font(.footnote)
                .disabled(isLoading)
            } else if isLoading {
                ProgressView("Looking at your week…")
                    .frame(maxWidth: .infinity)
            } else {
                Text("Get a suggestion for what to do next, based on this week’s practice.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await generate() }
                } label: {
                    Label("Review My Week", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func generate() async {
        guard !isLoading, let weekly = CoachContextBuilder.weeklyContext(context: modelContext) else { return }
        isLoading = true
        defer { isLoading = false }
        let enabled = CoachRouter.isEnabled(context: modelContext)
        guard let outcome = await CoachRouter.run(enabled: enabled, { service in
            try await service.weeklyReview(weekly)
        }) else { return }
        review = outcome.value
        note = outcome.fallbackNote
        WeeklyReviewStore.save(outcome.value)
    }
}

/// The last weekly review, kept for a few days in UserDefaults.
nonisolated enum WeeklyReviewStore {
    static let key = "coach.weeklyReview"
    static let dateKey = "coach.weeklyReviewDate"
    /// A review stays on screen for this long.
    static let lifetime: TimeInterval = 3 * 86_400

    static func recent(now: Date = Date()) -> WeeklyReview? {
        guard let date = UserDefaults.standard.object(forKey: dateKey) as? Date,
              now.timeIntervalSince(date) < lifetime,
              let data = UserDefaults.standard.data(forKey: key)
        else { return nil }
        return try? JSONDecoder().decode(WeeklyReview.self, from: data)
    }

    static func save(_ review: WeeklyReview, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(review) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(now, forKey: dateKey)
    }
}
