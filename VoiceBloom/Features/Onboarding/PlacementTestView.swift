import Foundation
import SwiftData
import SwiftUI

/// The 5-minute placement test (SPEC section 1, step 6): pitch matching,
/// a resonance hold and a reading passage. The result can unlock later
/// lesson phases.
struct PlacementTestView: View {
    private enum Step: Equatable {
        case intro
        case pitch(index: Int)
        case resonance
        case reading
        case results
    }

    let profile: UserProfile
    /// Called with the starting week chosen (nil when cancelled).
    let onComplete: (Int?) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: VoiceTakeRecorder
    @State private var tones = TonePlayer()
    @State private var step: Step = .intro
    @State private var result = PlacementResult()
    @State private var pitchResults: [Double?] = []
    @State private var isPlayingTone = false
    @State private var errorMessage: String?

    init(profile: UserProfile, monitor: LiveVoiceMonitor, onComplete: @escaping (Int?) -> Void) {
        self.profile = profile
        self.onComplete = onComplete
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var recommendedWeek: Int { PlacementScoring.recommendedWeek(for: result) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .intro:
                        intro
                    case .pitch(let index):
                        pitchMatch(index: index)
                    case .resonance:
                        resonanceHold
                    case .reading:
                        reading
                    case .results:
                        results
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Placement Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        finish(week: nil)
                    }
                }
            }
            .interactiveDismissDisabled(recorder.isRecording)
        }
    }

    // MARK: Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About 5 minutes, three short parts")
                .font(.title2.weight(.bold))
            partRow(number: 1, title: "Pitch matching", detail: "Listen to 5 tones and hum or sing each one back.")
            partRow(number: 2, title: "Resonance hold", detail: "Hold a bright “ee” for 6 seconds.")
            partRow(number: 3, title: "Reading", detail: "Read a short passage in your practice voice.")
            Text("Use a quiet room. Nothing here should strain: stay comfortable, and skip anything that doesn’t feel right.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                pitchResults = []
                result = PlacementResult()
                step = .pitch(index: 0)
            } label: {
                Text("Begin")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private func partRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Theme.targetZone.opacity(0.2), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pitchMatch(index: Int) -> some View {
        let target = PlacementScoring.tones[index]
        return VStack(alignment: .leading, spacing: 16) {
            StepIndicator(current: index + 1, total: PlacementScoring.tones.count)
            Text("Part 1: match the tone")
                .font(.title2.weight(.bold))
            Text("Tap the button, listen to the tone, then hum or sing it back for 3 seconds when the ring appears.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Tone \(index + 1): \(PitchMath.noteName(for: target) ?? "") · \(target.roundedInt) Hz")
                .font(.headline)

            if pitchResults.count > index {
                let sung = pitchResults[index]
                let matched = PlacementScoring.isMatch(sung: sung, target: target)
                Label(
                    matched ? "Matched! (\(sung.map { "\($0.roundedInt) Hz" } ?? ""))" : (sung.map { "You sang \($0.roundedInt) Hz, \(abs($0 - target).roundedInt) Hz away." } ?? "No voice heard."),
                    systemImage: matched ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(matched ? Theme.targetZone : Theme.warning)
                Button {
                    advanceFromPitch(index: index)
                } label: {
                    Text(index + 1 < PlacementScoring.tones.count ? "Next tone" : "Next part")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else if recorder.isRecording {
                TakeProgressView(recorder: recorder)
            } else {
                Button {
                    Task { await listenAndMatch(index: index) }
                } label: {
                    Label(isPlayingTone ? "Listen…" : "Play tone, then match", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isPlayingTone)
            }
        }
    }

    private var resonanceHold: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Part 2: bright “ee”")
                .font(.title2.weight(.bold))
            Text("Hold a comfortable “ee”, as bright and forward as feels easy, for 6 seconds. Think “small and smiley”, not louder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            takeSection(duration: 6, mode: .ee, startTitle: "Start “ee”") { take in
                result.brightResonancePercent = take.brightResonancePercent ?? 0
                recorder.reset()
                step = .reading
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Part 3: read aloud")
                .font(.title2.weight(.bold))
            Text("Read this in your practice voice. Tap “I’m done” when you finish.")
                .foregroundStyle(.secondary)
            Text(ReadingPassages.placement)
                .font(.title3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .cardStyle()
            takeSection(duration: 30, mode: .speech, startTitle: "Start reading") { take in
                result.readingInTarget = take.percentInTarget
                result.readingResonance = take.resonanceScore
                result.readingWeight = take.weightScore
                result.readingIntonation = take.intonationScore
                recorder.reset()
                Task { await recorder.restoreMicrophone() }
                step = .results
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your results")
                .font(.title2.weight(.bold))
            VStack(spacing: 12) {
                LabeledContent("Pitch matching", value: "\(result.pitchMatches) of \(result.pitchAttempts) tones")
                LabeledContent("Bright “ee”", value: result.brightResonancePercent.map(SessionFormat.percent) ?? "—")
                LabeledContent("Reading in target", value: result.readingInTarget.map(SessionFormat.percent) ?? "—")
                LabeledContent("Reading resonance", value: SessionFormat.score(result.readingResonance))
                LabeledContent("Reading weight", value: SessionFormat.score(result.readingWeight))
                LabeledContent("Reading intonation", value: SessionFormat.score(result.readingIntonation))
            }
            .cardStyle()

            Text("Recommended start: week \(recommendedWeek)")
                .font(.headline)
            Text(PlacementScoring.explanation(forWeek: recommendedWeek))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                finish(week: recommendedWeek)
            } label: {
                Text("Start at week \(recommendedWeek)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if recommendedWeek > 1 {
                Button("Start at Week 1 Instead") {
                    finish(week: 1)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Start button / progress / result for one take.
    @ViewBuilder
    private func takeSection(duration: Double, mode: ResonanceMode, startTitle: String, onDone: @escaping (TakeResult) -> Void) -> some View {
        switch recorder.phase {
        case .idle:
            Button {
                Task { await recorder.start(duration: duration, target: profile.targetZone, resonanceMode: mode, references: profile.personalReferences) }
            } label: {
                Label(startTitle, systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        case .starting, .recording:
            TakeProgressView(recorder: recorder, stopTitle: "I’m done")
        case .finished:
            if let take = recorder.result {
                VStack(alignment: .leading, spacing: 12) {
                    TakeResultSummary(result: take)
                        .cardStyle()
                    HStack(spacing: 12) {
                        Button("Redo") { recorder.reset() }
                            .buttonStyle(.glass)
                        Button {
                            onDone(take)
                        } label: {
                            Text("Continue").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "mic.slash")
                    .foregroundStyle(Theme.warning)
                Button("Try Again") { recorder.reset() }
                    .buttonStyle(.glass)
            }
        }
    }

    // MARK: Actions

    /// Plays the reference tone, then records 3 seconds of the user matching it.
    private func listenAndMatch(index: Int) async {
        errorMessage = nil
        isPlayingTone = true
        let target = PlacementScoring.tones[index]
        guard tones.playNote(target, duration: 1.6, timbre: .warm) else {
            errorMessage = tones.errorMessage ?? "The tone couldn’t play. Please try again."
            isPlayingTone = false
            return
        }
        // Wait for the tone (and the room's echo) to end before listening.
        try? await Task.sleep(for: .milliseconds(1_900))
        isPlayingTone = false
        await recorder.start(duration: 3, target: profile.targetZone, references: profile.personalReferences)
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let take = recorder.result else {
            if case .failed(let message) = recorder.phase {
                errorMessage = message
            }
            recorder.reset()
            return
        }
        pitchResults.append(take.medianPitch)
        result.pitchAttempts += 1
        if PlacementScoring.isMatch(sung: take.medianPitch, target: target) {
            result.pitchMatches += 1
        }
        recorder.reset()
    }

    private func advanceFromPitch(index: Int) {
        if index + 1 < PlacementScoring.tones.count {
            step = .pitch(index: index + 1)
        } else {
            step = .resonance
        }
    }

    private func finish(week: Int?) {
        recorder.cancel()
        tones.stop()
        Task { await recorder.restoreMicrophone() }
        if let week {
            do {
                try PlacementStore.apply(week: week, result: result, context: modelContext)
            } catch {
                errorMessage = "The result couldn’t be saved. Please try again."
                return
            }
        }
        onComplete(week)
        dismiss()
    }
}
