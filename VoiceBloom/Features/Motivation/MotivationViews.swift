import Foundation
import SwiftData
import SwiftUI

/// Streak (with this week's freeze), today's minutes and the daily challenge.
struct TodayCard: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query private var sessions: [PracticeSession]
    @State private var challengeDone = ChallengeStore.isDone(on: Date())

    private var challenge: DailyChallenge { DailyChallenge.challenge(for: Date()) }

    var body: some View {
        // Read through the query so the card refreshes when sessions change.
        _ = sessions.count
        let streak = MotivationCenter.streak(context: modelContext)
        let minutes = MotivationCenter.todayMinutes(context: modelContext)
        let goal = profiles.first?.dailyGoalMinutes ?? 15
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(streak.days)-day streak", systemImage: "flame.fill")
                        .font(.headline)
                        .foregroundStyle(streak.days > 0 ? Theme.intonationSeries : Color.secondary)
                    Text(streakDetail(streak))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(minutes.rounded())) of \(goal) min")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    MeterBar(fraction: goal > 0 ? minutes / Double(goal) : 0, tint: Theme.targetZone)
                        .frame(width: 110, height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today")
                .accessibilityValue("\(Int(minutes.rounded())) of \(goal) minutes")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Today’s challenge", systemImage: "star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(challenge.title)
                    .font(.subheadline.weight(.semibold))
                Text(challenge.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ChallengeLink(challenge: challenge)
                    Button {
                        ChallengeStore.markDone()
                        challengeDone = true
                        MotivationCenter.refresh(context: modelContext)
                    } label: {
                        Label(challengeDone ? "Done" : "Mark done", systemImage: challengeDone ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.glass)
                    .disabled(challengeDone)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func streakDetail(_ streak: StreakStatus) -> String {
        var parts: [String] = []
        if streak.days == 0 {
            parts.append("Practice today to start a streak.")
        } else if !streak.practicedToday {
            parts.append("Practice today to keep it going.")
        }
        if !streak.frozenDays.isEmpty {
            parts.append("A rest day was covered by a streak freeze.")
        } else if streak.freezeAvailable {
            parts.append("1 streak freeze this week: one rest day won’t break it.")
        }
        return parts.joined(separator: " ")
    }
}

/// Opens where the daily challenge happens.
private struct ChallengeLink: View {
    let challenge: DailyChallenge

    var body: some View {
        switch challenge.destination {
        case .practice:
            Button("Go") {
                LaunchActionStore.request(.practice)
            }
            .buttonStyle(.glassProminent)
        case .quickCheck:
            Button("Go") {
                LaunchActionStore.request(.quickCheck)
            }
            .buttonStyle(.glassProminent)
        case .journal:
            link { JournalView() }
        case .scenarios:
            link { ScenarioListView() }
        case .pitchGame:
            link { PitchGameView() }
        case .toneGenerator:
            link { ToneGeneratorView() }
        case .exercise:
            if let id = challenge.exerciseID, let exercise = LessonLibrary.catalog?.allExercises.first(where: { $0.id == id }) {
                link { ExerciseDetailView(exercise: exercise) }
            }
        }
    }

    private func link<Destination: View>(@ViewBuilder _ destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            Text("Go")
        }
        .buttonStyle(.glassProminent)
    }
}

/// Achievements (SPEC section 12): earned ones first, then the rest.
struct AchievementsView: View {
    @Query(sort: \Achievement.unlockedDate, order: .reverse) private var unlocked: [Achievement]

    var body: some View {
        let earned = Dictionary(unlocked.map { ($0.identifier, $0.unlockedDate) }, uniquingKeysWith: { first, _ in first })
        List {
            Section {
                Text("\(earned.count) of \(AchievementKind.allCases.count) earned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Earned") {
                ForEach(AchievementKind.allCases.filter { earned[$0.rawValue] != nil }) { kind in
                    AchievementRow(kind: kind, date: earned[kind.rawValue])
                }
            }
            Section("Still to come") {
                ForEach(AchievementKind.allCases.filter { earned[$0.rawValue] == nil }) { kind in
                    AchievementRow(kind: kind, date: nil)
                }
            }
        }
        .navigationTitle("Achievements")
    }
}

struct AchievementRow: View {
    let kind: AchievementKind
    let date: Date?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: date == nil ? "lock.fill" : kind.systemImage)
                .font(.title2)
                .foregroundStyle(date == nil ? Color.secondary : Theme.intonationSeries)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.headline)
                    .foregroundStyle(date == nil ? Color.secondary : Color.primary)
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date {
                    Text("Earned \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(date == nil ? "Not earned yet" : "Earned")
    }
}

/// A small card on the Progress tab linking to all achievements.
struct AchievementsSummaryCard: View {
    @Query(sort: \Achievement.unlockedDate, order: .reverse) private var unlocked: [Achievement]

    var body: some View {
        NavigationLink {
            AchievementsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rosette")
                    .font(.title)
                    .foregroundStyle(Theme.intonationSeries)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Achievements")
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let latest = unlocked.first.flatMap { AchievementKind(rawValue: $0.identifier) }
        let count = "\(Set(unlocked.map(\.identifier)).count) of \(AchievementKind.allCases.count) earned"
        return latest.map { "\(count) · latest: \($0.title)" } ?? count
    }
}
