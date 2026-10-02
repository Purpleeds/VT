import Foundation
import SwiftData
import SwiftUI

/// Scenario practice (SPEC section 7): real-life situations at Easy, Medium
/// and Hard, with pre-written scripts.
struct ScenarioListView: View {
    @Query(sort: \ScenarioResult.date, order: .reverse) private var results: [ScenarioResult]

    var body: some View {
        Group {
            if let catalog = ScenarioLibrary.catalog {
                list(catalog)
            } else {
                ContentUnavailableView(
                    "Scenarios unavailable",
                    systemImage: "theatermasks",
                    description: Text(ScenarioLibrary.loadError ?? "The scenarios couldn’t be loaded.")
                )
            }
        }
        .navigationTitle("Scenarios")
    }

    private func list(_ catalog: ScenarioCatalog) -> some View {
        let best = ScenarioBest.table(results.map { (scenarioID: $0.scenarioID, difficulty: $0.difficulty, overall: $0.overallScore) })
        return List {
            Section {
                Text("Practice everyday situations. The other person’s lines are on screen (and can be read aloud); each of your turns is scored for pitch, resonance, weight, intonation and consistency.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(catalog.scenarios) { scenario in
                    NavigationLink {
                        ScenarioDetailView(scenario: scenario)
                    } label: {
                        ScenarioRow(scenario: scenario, best: best[scenario.id])
                    }
                }
            } footer: {
                Text("Your scenario scores fill in the skills radar on the Progress tab.")
            }
        }
    }
}

private struct ScenarioRow: View {
    let scenario: Scenario
    let best: ScenarioBest?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: scenario.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.title)
                    .font(.headline)
                Text(scenario.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(ScenarioDifficulty.allCases) { difficulty in
                        DifficultyBadge(difficulty: difficulty, score: best?.scores[difficulty])
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "Easy 72" when practiced, "Easy" (dimmed) when not yet.
struct DifficultyBadge: View {
    let difficulty: ScenarioDifficulty
    let score: Double?

    var body: some View {
        Text(score.map { "\(difficulty.title) \(Int($0.rounded()))" } ?? difficulty.title)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(score == nil ? Color.secondary.opacity(0.12) : Theme.targetZone.opacity(0.22), in: Capsule())
            .foregroundStyle(score == nil ? Color.secondary : Color.primary)
            .accessibilityLabel(score.map { "\(difficulty.title), best score \(Int($0.rounded()))" } ?? "\(difficulty.title), not practiced yet")
    }
}
