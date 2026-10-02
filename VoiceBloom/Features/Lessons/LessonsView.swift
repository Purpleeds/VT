import Foundation
import SwiftData
import SwiftUI

/// The Lessons tab: the 16-week plan by phase, the current week, and
/// maintenance mode afterwards (SPEC sections 5 and 6).
struct LessonsView: View {
    @Environment(GuidedSessionCoordinator.self) private var coordinator
    @Query private var progressRecords: [LessonProgress]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \ScenarioResult.date) private var scenarioResults: [ScenarioResult]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(LessonProgressStore.unlockAllKey) private var unlockAll = false

    private var progress: [Int: LessonProgressValues] {
        // Read through the query so the view refreshes when progress changes.
        _ = progressRecords.count
        return LessonProgressStore(context: modelContext).values()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = LessonLibrary.catalog {
                    content(catalog)
                } else {
                    ContentUnavailableView(
                        "Lessons unavailable",
                        systemImage: "book.closed",
                        description: Text(LessonLibrary.loadError ?? "The lesson plan couldn’t be loaded.")
                    )
                }
            }
            .background { AppBackground() }
            .navigationTitle("Lessons")
        }
    }

    private func content(_ catalog: LessonCatalog) -> some View {
        let progress = progress
        let current = LessonUnlockRules.currentWeek(progress: progress, totalWeeks: catalog.totalWeeks, unlockAll: unlockAll)
        let maintenanceUnlocked = LessonUnlockRules.isMaintenanceUnlocked(progress: progress, totalWeeks: catalog.totalWeeks, unlockAll: unlockAll)
        let phases = Dictionary(grouping: catalog.weeks, by: \.phase).sorted { $0.key < $1.key }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let week = catalog.week(current) {
                    CurrentWeekCard(week: week, catalog: catalog, progress: progress[week.week], isUnlocked: true)
                }

                if maintenanceUnlocked {
                    NavigationLink {
                        MaintenanceView(catalog: catalog)
                    } label: {
                        MaintenanceCardLabel(plan: catalog.maintenance)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(phases, id: \.key) { phase, weeks in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Phase \(phase): \(weeks.first?.phaseTitle ?? "")")
                            .font(.headline)
                        ForEach(weeks) { week in
                            let isUnlocked = LessonUnlockRules.isUnlocked(week: week.week, progress: progress, unlockAll: unlockAll)
                            NavigationLink {
                                LessonDetailView(week: week, catalog: catalog, isUnlocked: isUnlocked)
                            } label: {
                                WeekRow(week: week, progress: progress[week.week], isUnlocked: isUnlocked, isCurrent: week.week == current)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("A week unlocks after 5 sessions of the week before it and reaching its goal. You can repeat any unlocked week as often as you like. Several short sessions a day work better than one long one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .task(id: scenarioResults.count) {
            // Scenario goals (week 14) are met by practicing scenarios.
            if let week = catalog.week(14) {
                try? LessonProgressStore(context: modelContext).evaluateScenarioGoal(week: week, scenarioDates: scenarioResults.map(\.date))
            }
        }
    }
}

/// Big card for the week in progress, with the session length and Start.
private struct CurrentWeekCard: View {
    let week: LessonWeek
    let catalog: LessonCatalog
    let progress: LessonProgressValues?
    let isUnlocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Week \(week.week) · \(week.phaseTitle)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(week.title)
                .font(.title2.weight(.bold))
            Text(week.summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WeekProgressLine(week: week, progress: progress)
            SessionStartControls(week: week, catalog: catalog, isUnlocked: isUnlocked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// Sessions done this week and whether the goal is met.
struct WeekProgressLine: View {
    let week: LessonWeek
    let progress: LessonProgressValues?

    var body: some View {
        let sessions = progress?.sessionsCompleted ?? 0
        let goalMet = progress?.goalMet ?? false
        HStack(spacing: 16) {
            Label("\(min(sessions, LessonUnlockRules.requiredSessions)) of \(LessonUnlockRules.requiredSessions) sessions", systemImage: sessions >= LessonUnlockRules.requiredSessions ? "checkmark.circle.fill" : "circle.dashed")
            Label(goalMet ? "Goal met" : "Goal not yet", systemImage: goalMet ? "star.fill" : "star")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Session length picker and Start button.
struct SessionStartControls: View {
    let week: LessonWeek
    let catalog: LessonCatalog
    let isUnlocked: Bool
    @Environment(GuidedSessionCoordinator.self) private var coordinator
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var selectedLength: SessionLength = .standard
    @State private var didLoadDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Session length", selection: $selectedLength) {
                ForEach(SessionLength.allCases) { option in
                    Text("\(option.title) \(option.minutes) min").tag(option)
                }
            }
            .pickerStyle(.segmented)

            Button {
                coordinator.request(GuidedSessionPlan(
                    title: "Week \(week.week): \(week.title)",
                    source: .lesson(week: week.week),
                    steps: SessionPlanner.plan(week: week, length: selectedLength, catalog: catalog),
                    goal: week.goal
                ))
            } label: {
                Label(isUnlocked ? "Start \(selectedLength.minutes)-minute session" : "Locked", systemImage: isUnlocked ? "play.fill" : "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!isUnlocked)
        }
        .onAppear {
            guard !didLoadDefault else { return }
            didLoadDefault = true
            selectedLength = profiles.first?.defaultSessionLength ?? .standard
        }
    }
}

private struct WeekRow: View {
    let week: LessonWeek
    let progress: LessonProgressValues?
    let isUnlocked: Bool
    let isCurrent: Bool

    private var isComplete: Bool { LessonUnlockRules.isComplete(progress) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isComplete ? Theme.targetZone : (isCurrent ? Theme.targetZone.opacity(0.2) : Color.secondary.opacity(0.12)))
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else if !isUnlocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(week.week)")
                        .font(.caption.weight(.bold))
                }
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Week \(week.week): \(week.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isUnlocked ? Color.primary : Color.secondary)
                Text(statusText)
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
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? Theme.targetZone : Color.clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Week \(week.week), \(week.title)")
        .accessibilityValue(statusText)
    }

    private var statusText: String {
        if isComplete { return "Complete" }
        if !isUnlocked { return "Locked" }
        let sessions = progress?.sessionsCompleted ?? 0
        let goal = (progress?.goalMet ?? false) ? "goal met" : "goal not yet"
        return "\(isCurrent ? "Current · " : "")\(sessions) of \(LessonUnlockRules.requiredSessions) sessions, \(goal)"
    }
}

private struct MaintenanceCardLabel: View {
    let plan: MaintenancePlan

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "infinity.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title)
                    .font(.headline)
                Text("Daily \(plan.dailyMinutes)-minute routines and weekly challenges.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }
}
