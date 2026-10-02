import Foundation
import SwiftData
import SwiftUI

/// Full-screen player for a guided session: warm-up, main practice,
/// carryover and cool-down, one exercise at a time with live meters.
struct GuidedSessionView: View {
    @State private var model: GuidedSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingEnd = false

    init(model: GuidedSessionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let step = model.step {
                        exerciseCard(step)
                        activity(step)
                    }
                    if monitor.status.isRunning {
                        liveReadout
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .safeAreaInset(edge: .bottom) {
                controls
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            .navigationTitle(model.plan.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End") {
                        isConfirmingEnd = true
                    }
                }
            }
            .confirmationDialog("End this session?", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
                Button("End and save") {
                    model.finish()
                    dismiss()
                }
                Button("Keep practicing", role: .cancel) {}
            } message: {
                Text(model.countsAsCompleted ? "It counts toward this week." : "Sessions count toward the week once you’ve done at least half.")
            }
            .onChange(of: model.isFinished) { _, finished in
                if finished {
                    dismiss()
                }
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.progress)
                .tint(Theme.targetZone)
                .accessibilityLabel("Session progress")
            if let step = model.step {
                HStack {
                    Label(step.phase.title, systemImage: phaseSymbol(step.phase))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.index + 1) of \(model.plan.steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.goalMet {
                Label("Week goal reached!", systemImage: "star.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.targetZone)
            }
        }
    }

    private func phaseSymbol(_ phase: SessionPhase) -> String {
        switch phase {
        case .warmUp: "flame"
        case .main: "figure.mind.and.body"
        case .carryover: "bubble.left.and.bubble.right"
        case .coolDown: "moon"
        }
    }

    private func exerciseCard(_ step: PlannedStep) -> some View {
        let exercise = step.exercise
        return VStack(alignment: .leading, spacing: 12) {
            Text(exercise.title)
                .font(.title2.weight(.bold))
            Text(exercise.summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { number, instruction in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(number + 1).")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(instruction)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Label(exercise.howItShouldFeel, systemImage: "hand.raised")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let mistake = exercise.commonMistake {
                Label(mistake, systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private func activity(_ step: PlannedStep) -> some View {
        let exercise = step.exercise
        VStack(alignment: .leading, spacing: 14) {
            switch exercise.kind {
            case .timed, .glide, .scenario:
                timer
                if exercise.kind == .glide {
                    LivePitchGraph()
                        .frame(height: 160)
                        .cardStyle()
                }
                if exercise.kind == .scenario {
                    Text("Practice a scenario from Tools › Scenarios, or talk through an everyday situation of your own for this step.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .reading:
                if let text = exercise.text {
                    Text(text)
                        .font(.title3)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardStyle()
                }
                measuredControls
            case .phrases:
                if let item = model.currentItem {
                    Text(item)
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .cardStyle()
                        .id(item)
                        .transition(reduceMotion ? .opacity : .push(from: .trailing))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: item)
                }
                measuredControls
            case .hold:
                Text("Hold “\(exercise.vowel ?? "ee")”")
                    .font(.largeTitle.weight(.semibold))
                    .frame(maxWidth: .infinity)
                measuredControls
            case .pitchMatch:
                pitchMatch
            }

            if let feedback = model.feedback {
                Label(feedback, systemImage: model.goalMet ? "star.fill" : "chart.bar")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .cardStyle()
            }
        }
    }

    private var timer: some View {
        HStack {
            Image(systemName: "timer")
                .accessibilityHidden(true)
            Text(Duration.seconds(Int(model.remaining.rounded(.up))).formatted(.time(pattern: .minuteSecond)))
                .font(.title.weight(.semibold))
                .monospacedDigit()
            if model.isPaused {
                Text("Paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var measuredControls: some View {
        switch model.stage {
        case .ready:
            Button {
                model.startStep()
            } label: {
                Label("Start", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        case .recording:
            TakeProgressView(recorder: model.recorder, stopTitle: "Done")
        case .done:
            Button("Try again") {
                model.startStep()
            }
            .buttonStyle(.glass)
        case .running, .playingTone:
            EmptyView()
        }
    }

    private var pitchMatch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(model.matchTones.enumerated()), id: \.offset) { index, tone in
                    let done = index < model.matchResults.count
                    VStack(spacing: 2) {
                        Image(systemName: done ? (model.isMatch(at: index) ? "checkmark.circle.fill" : "xmark.circle") : (index == model.matchIndex ? "circle.dotted" : "circle"))
                            .foregroundStyle(done ? (model.isMatch(at: index) ? Theme.targetZone : Theme.warning) : Color.secondary)
                        Text("\(Int(tone.rounded()))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tone \(index + 1), \(Int(tone.rounded())) hertz")
                    .accessibilityValue(done ? (model.isMatch(at: index) ? "Matched" : "Missed") : "Not yet")
                }
            }
            switch model.stage {
            case .ready:
                Button {
                    model.startStep()
                } label: {
                    Label(model.matchIndex == 0 ? "Play the first tone" : "Play the next tone", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            case .playingTone:
                Label("Listen…", systemImage: "ear")
                    .font(.headline)
            case .recording:
                TakeProgressView(recorder: model.recorder)
            case .done, .running:
                EmptyView()
            }
            if let message = model.tones.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var liveReadout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monitor.readoutFrequency.map { "\(Int($0.rounded())) Hz" } ?? "—")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let frequency = monitor.readoutFrequency, let note = PitchMath.noteName(for: frequency) {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Target \(monitor.targetZone.formatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VoiceMetersCard()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.previous()
            } label: {
                Label("Back", systemImage: "backward.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .disabled(model.index == 0)
            .accessibilityLabel("Previous exercise")

            Button {
                model.togglePause()
            } label: {
                Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(model.stage != .running)

            Button {
                model.next()
            } label: {
                Label(model.isLastStep ? "Finish" : "Next", systemImage: model.isLastStep ? "checkmark" : "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
        .controlSize(.large)
    }
}
