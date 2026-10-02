import Foundation
import SwiftData
import SwiftUI

/// Full-screen scenario practice: the other person's line, your turn, its
/// scores, and a summary that is saved for the Progress radar.
struct ScenarioSessionView: View {
    @State private var model: ScenarioSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingEnd = false
    @State private var saveError: String?

    init(model: ScenarioSessionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if model.stage == .summary {
                        summaryView
                    } else if let turn = model.turn {
                        turnContent(turn)
                    }
                }
                .padding()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.stage)
            }
            .background { AppBackground() }
            .navigationTitle(model.scenario.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.stage == .summary ? "Close" : "End") {
                        if model.stage == .summary {
                            close()
                        } else {
                            isConfirmingEnd = true
                        }
                    }
                }
            }
            .confirmationDialog("End this scenario?", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
                Button("See results so far") {
                    model.endEarly()
                }
                Button("End without saving", role: .destructive) {
                    model.stopAudio()
                    dismiss()
                }
                Button("Keep going", role: .cancel) {}
            }
            .interactiveDismissDisabled()
            .task {
                await model.presentTurn()
            }
            .onDisappear {
                model.stopAudio()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.progress)
                .tint(Theme.targetZone)
                .accessibilityLabel("Scenario progress")
            HStack {
                Text("\(model.difficulty.title) · \(model.level.partner)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.stage != .summary {
                    Text("Turn \(model.index + 1) of \(model.level.turns.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.index == 0, model.stage != .summary {
                Text(model.level.setting)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Turn

    @ViewBuilder
    private func turnContent(_ turn: ScenarioTurn) -> some View {
        if let line = turn.partner {
            PartnerBubble(name: model.level.partner, line: line, isSpeaking: model.partnerVoice.isSpeaking) {
                Task { await model.replayPartner() }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your turn")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cue = turn.cue {
                    Text(cue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.intonationSeries.opacity(0.2), in: Capsule())
                        .accessibilityLabel("Say it: \(cue)")
                }
            }
            Text(turn.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = turn.suggestion {
                Text(suggestion)
                    .font(.title3)
                    .italic()
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.pitchLine.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Say: \(suggestion)")
            }
            Text("Up to \(turn.seconds) seconds")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()

        controls(turn)

        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Theme.warning)
        }
    }

    @ViewBuilder
    private func controls(_ turn: ScenarioTurn) -> some View {
        switch model.stage {
        case .partner:
            HStack {
                Label("Listen…", systemImage: "ear")
                    .font(.headline)
                Spacer()
                Button("Skip") {
                    model.skipPartner()
                }
                .buttonStyle(.glass)
            }
        case .ready:
            startButton("Start speaking")
        case .recording:
            TakeProgressView(recorder: model.recorder, stopTitle: "Done")
        case .scored:
            VStack(alignment: .leading, spacing: 12) {
                if let score = model.currentScore {
                    TurnScoreCard(score: score)
                } else if !model.lastTurnHadVoice {
                    Label("No voice was detected. Try again a little closer to the phone.", systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.startTurn() }
                    } label: {
                        Label("Try again", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        Task { await model.next() }
                    } label: {
                        Label(model.isLastTurn ? "See results" : "Next turn", systemImage: model.isLastTurn ? "flag.checkered" : "forward.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
            }
        case .summary:
            EmptyView()
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            Task { await model.startTurn() }
        } label: {
            Label(title, systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    // MARK: Summary

    private var summaryView: some View {
        let summary = model.summary
        return VStack(alignment: .leading, spacing: 16) {
            if summary.turnCount == 0 {
                ContentUnavailableView(
                    "No turns scored",
                    systemImage: "mic.slash",
                    description: Text("Nothing was saved. Try the scenario again when you’re ready.")
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.overall.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("overall · \(summary.turnCount) of \(model.level.turns.count) turns")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    ForEach(RadarValues.Axis.allCases) { axis in
                        ScoreBarRow(title: axis.title, value: summary.averages[axis])
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    if let strongest = summary.strongest {
                        Label("Strongest: \(strongest.title.lowercased()). Nice work!", systemImage: "star.fill")
                            .foregroundStyle(Theme.targetZone)
                    }
                    if let weakest = summary.weakest {
                        Label {
                            Text("Next time: \(weakest.scenarioTip)")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "arrow.up.right.circle")
                        }
                    }
                }
                .font(.subheadline)
                .cardStyle()

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }

            Button {
                close()
            } label: {
                Label(summary.turnCount == 0 ? "Close" : "Save and finish", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            Text("Results appear on the Progress tab’s skills radar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func close() {
        do {
            try model.save(context: modelContext)
            dismiss()
        } catch {
            saveError = "The result couldn’t be saved. Please try again."
        }
    }
}

/// The other person's line in a speech bubble.
private struct PartnerBubble: View {
    let name: String
    let line: String
    let isSpeaking: Bool
    let onReplay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(line)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button(action: onReplay) {
                Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Read \(name)’s line aloud")
        }
        .accessibilityElement(children: .contain)
    }
}

/// The five scores of one turn.
private struct TurnScoreCard: View {
    let score: ScenarioTurnScore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This turn")
                    .font(.headline)
                Spacer()
                if let overall = ScenarioScoring.overall(score) {
                    Text("\(Int(overall.rounded()))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityLabel("Overall \(Int(overall.rounded()))")
                }
            }
            ForEach(RadarValues.Axis.allCases) { axis in
                ScoreBarRow(title: axis.title, value: axis.value(in: score))
            }
        }
        .cardStyle()
    }
}

/// A labelled 0–100 bar.
struct ScoreBarRow: View {
    let title: String
    let value: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .frame(width: 100, alignment: .leading)
            MeterBar(fraction: (value ?? 0) / 100, tint: Theme.targetZone)
                .frame(height: 8)
                .opacity(value == nil ? 0.3 : 1)
            Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\(Int($0.rounded())) out of 100" } ?? "Not measured")
    }
}
