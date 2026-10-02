import Foundation
import SwiftData
import SwiftUI

/// One week of the plan: explanation, steps, goal, mistakes, how it should
/// feel, its exercises, and Start.
struct LessonDetailView: View {
    let week: LessonWeek
    let catalog: LessonCatalog
    let isUnlocked: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query private var progressRecords: [LessonProgress]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var isShowingBaseline = false

    private var progress: LessonProgressValues? {
        _ = progressRecords.count
        return LessonProgressStore(context: modelContext).values()[week.week]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Week \(week.week) · Phase \(week.phase): \(week.phaseTitle)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(week.title)
                        .font(.largeTitle.weight(.bold))
                    WeekProgressLine(week: week, progress: progress)
                }

                if !isUnlocked {
                    NoticeBanner(
                        title: "Not unlocked yet",
                        message: "Finish 5 sessions of week \(week.week - 1) and reach its goal to unlock this week. You can read ahead in the meantime.",
                        systemImage: "lock.fill",
                        tint: Color.secondary
                    )
                }

                section("What you’ll do", text: week.explanation)
                section("Why it matters", text: week.whyItMatters)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Step by step")
                        .font(.headline)
                    ForEach(Array(week.steps.enumerated()), id: \.offset) { number, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(number + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Theme.targetZone.opacity(0.2), in: Circle())
                                .accessibilityHidden(true)
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Label("This week’s goal", systemImage: (progress?.goalMet ?? false) ? "star.fill" : "star")
                        .font(.headline)
                    Text(week.goal.description)
                        .fixedSize(horizontal: false, vertical: true)
                    if week.goal.kind == .baseline {
                        Button {
                            isShowingBaseline = true
                        } label: {
                            Label("Re-record your baseline", systemImage: "mic.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(!isUnlocked)
                    }
                    if week.goal.kind == .scenarios {
                        Text("Practice scenarios in Tools › Scenarios; each one counts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                bulletList("Common mistakes", items: week.commonMistakes, symbol: "exclamationmark.triangle", tint: Theme.warning)
                bulletList("How it should feel", items: week.howItShouldFeel, symbol: "hand.raised", tint: Theme.targetZone)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Exercises")
                        .font(.headline)
                    ForEach(week.exercises + week.carryover) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            ExerciseRow(exercise: exercise)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Guided session")
                        .font(.headline)
                    Text("Warm-up, this week’s exercises, real-speech carryover and a cool-down.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SessionStartControls(week: week, catalog: catalog, isUnlocked: isUnlocked)
                }
                .cardStyle()
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Week \(week.week)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingBaseline) {
            if let profile = profiles.first {
                NavigationStack {
                    ScrollView {
                        BaselineRecordingView(purpose: .reRecord, profile: profile, monitor: monitor) { saved in
                            isShowingBaseline = false
                            if saved {
                                try? LessonProgressStore(context: modelContext).markGoalMet(week: week.week)
                            }
                        }
                        .padding()
                    }
                    .background { AppBackground() }
                    .navigationTitle("Re-record baseline")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isShowingBaseline = false }
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletList(_ title: String, items: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// A compact exercise row with its skill and length.
struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: exercise.skill.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(exercise.skill.title) · \(SessionFormat.duration(Double(exercise.durationSeconds)))\(exercise.kind.isMeasured ? " · scored" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One exercise, playable on its own (also used by the exercise library).
struct ExerciseDetailView: View {
    let exercise: Exercise
    @Environment(GuidedSessionCoordinator.self) private var coordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(exercise.skill.title, systemImage: exercise.skill.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(exercise.title)
                        .font(.largeTitle.weight(.bold))
                    Text(exercise.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("About \(SessionFormat.spokenDuration(Double(exercise.durationSeconds)))\(exercise.isQuiet ? " · quiet" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("How to do it")
                        .font(.headline)
                    ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { number, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(number + 1).")
                                .font(.subheadline.weight(.semibold))
                            Text(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                Label(exercise.howItShouldFeel, systemImage: "hand.raised")
                    .fixedSize(horizontal: false, vertical: true)
                if let mistake = exercise.commonMistake {
                    Label(mistake, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text = exercise.text {
                    Text(text)
                        .font(.body)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .cardStyle()
                }
                if let items = exercise.items {
                    Text(items.joined(separator: " · "))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardStyle()
                }

                Button {
                    coordinator.request(GuidedSessionPlan(
                        title: exercise.title,
                        source: .exercise(id: exercise.id),
                        steps: SessionPlanner.single(exercise),
                        goal: nil
                    ))
                } label: {
                    Label("Practice this exercise", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(exercise.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// After week 16: daily routines that mix every skill, a weekly challenge,
/// and a focus area picked from this week's weakest measure.
struct MaintenanceView: View {
    let catalog: LessonCatalog
    @Environment(GuidedSessionCoordinator.self) private var coordinator
    @Environment(\.calendar) private var calendar
    @Query(sort: \PracticeSession.startDate) private var sessions: [PracticeSession]

    var body: some View {
        let now = Date()
        let summary = ProgressAnalytics.weeklySummary(sessions.map(SessionPoint.init), now: now, calendar: calendar)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let routine = catalog.maintenance.routine(focus: summary.focus?.metric, dayOfYear: dayOfYear)
        let challenge = catalog.maintenance.weeklyChallenge(weekOfYear: calendar.component(.weekOfYear, from: now))

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(catalog.maintenance.explanation)
                    .fixedSize(horizontal: false, vertical: true)

                if let routine {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Today’s routine")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(routine.title)
                            .font(.title2.weight(.bold))
                        Text(routine.summary)
                            .foregroundStyle(.secondary)
                        if let focus = summary.focus {
                            Label("Focus this week: \(focus.metric.title) (your lowest average, \(Int(focus.average.rounded())))", systemImage: "scope")
                                .font(.subheadline)
                        }
                        Button {
                            coordinator.request(GuidedSessionPlan(
                                title: routine.title,
                                source: .maintenance(routineID: routine.id),
                                steps: SessionPlanner.plan(routine: routine, catalog: catalog, minutes: catalog.maintenance.dailyMinutes),
                                goal: nil
                            ))
                        } label: {
                            Label("Start \(catalog.maintenance.dailyMinutes)-minute routine", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    .cardStyle()
                }

                if let challenge {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("This week’s challenge", systemImage: "flag.checkered")
                            .font(.headline)
                        Text(challenge)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }

                Text("Other routines")
                    .font(.headline)
                ForEach(catalog.maintenance.routines) { other in
                    Button {
                        coordinator.request(GuidedSessionPlan(
                            title: other.title,
                            source: .maintenance(routineID: other.id),
                            steps: SessionPlanner.plan(routine: other, catalog: catalog, minutes: catalog.maintenance.dailyMinutes),
                            goal: nil
                        ))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(other.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .font(.title2)
                        }
                        .padding(12)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(catalog.maintenance.title)
    }
}
