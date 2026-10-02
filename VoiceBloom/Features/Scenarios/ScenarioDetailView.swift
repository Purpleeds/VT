import Foundation
import SwiftData
import SwiftUI

/// One scenario: pick a difficulty, read the setting and tips, start, and
/// see past results.
struct ScenarioDetailView: View {
    let scenario: Scenario

    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query private var results: [ScenarioResult]
    @AppStorage(PartnerVoice.enabledKey) private var speaksPartner = true

    @State private var difficulty: ScenarioDifficulty = .easy
    @State private var activeModel: ScenarioSessionModel?
    @State private var isShowingSoftCap = false

    init(scenario: Scenario) {
        self.scenario = scenario
        let id = scenario.id
        _results = Query(
            filter: #Predicate<ScenarioResult> { $0.scenarioID == id },
            sort: \ScenarioResult.date,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(scenario.title, systemImage: scenario.systemImage)
                        .font(.title2.weight(.bold))
                    Text(scenario.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(scenario.focus, systemImage: "lightbulb")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Difficulty", selection: $difficulty) {
                    ForEach(ScenarioDifficulty.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if let level = scenario.level(difficulty) {
                    levelCard(level)
                }

                Toggle(isOn: $speaksPartner) {
                    Label("Read the other person’s lines aloud", systemImage: "speaker.wave.2")
                }
                .font(.subheadline)

                Button {
                    requestStart()
                } label: {
                    Label("Start \(difficulty.title)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(scenario.level(difficulty) == nil)

                if !results.isEmpty {
                    history
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeModel, onDismiss: {
            // Saves the practice session (and asks for the check-in).
            Task { _ = await sessionController.endGuidedSession() }
        }) { model in
            ScenarioSessionView(model: model)
        }
        .alert("You’ve practiced 45 minutes today", isPresented: $isShowingSoftCap) {
            Button("Rest instead", role: .cancel) {}
            Button("Practice anyway") {
                Task { await start() }
            }
        } message: {
            Text("Your voice does better with breaks. Consider resting now and coming back later or tomorrow.")
        }
    }

    private func levelCard(_ level: ScenarioLevel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(difficulty.detail)
                .font(.subheadline.weight(.semibold))
            LabeledContent("Setting") {
                Text(level.setting)
                    .multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
            LabeledContent("You’re talking to", value: level.partner)
                .font(.subheadline)
            LabeledContent("Length", value: "\(level.turns.count) turns · about \(level.estimatedMinutes) min")
                .font(.subheadline)
            Text(level.goal)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(level.tips, id: \.self) { tip in
                    Label(tip, systemImage: "sparkle")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your results")
                .font(.headline)
            ForEach(results.prefix(10)) { result in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                        Text("\(result.difficulty.title) · \(result.turnScores.count) turns")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(result.overallScore.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Actions

    private func requestStart() {
        if sessionController.minutesPracticedToday() >= PracticeSessionController.dailySoftCapMinutes {
            isShowingSoftCap = true
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        guard let level = scenario.level(difficulty) else { return }
        let profile = profiles.first
        await sessionController.beginGuidedSession(kind: .scenario, lessonID: scenario.id)
        activeModel = ScenarioSessionModel(
            scenario: scenario,
            difficulty: difficulty,
            level: level,
            monitor: monitor,
            target: profile?.targetZone ?? monitor.targetZone,
            references: profile?.personalReferences ?? .none,
            speaksPartner: speaksPartner
        )
    }
}
