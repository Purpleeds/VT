import Foundation
import SwiftData
import SwiftUI

/// Records the baseline: a short passage read aloud, then 30 seconds of free
/// speech (SPEC section 1, step 8). Saved as the "Day 1" recordings; in
/// week 16 the same flow re-records it for "Then vs Now".
struct BaselineRecordingView: View {
    enum Purpose {
        case dayOne
        case reRecord
    }

    private enum Step: Equatable {
        case reading
        case speech
        case saving
    }

    let purpose: Purpose
    let profile: UserProfile
    /// Called with true once saved (false when skipped).
    let onComplete: (Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var recorder: VoiceTakeRecorder
    @State private var step: Step = .reading
    @State private var readingTake: BaselineStore.Take?
    @State private var prompt = ReadingPassages.freeSpeechPrompts.first ?? "Tell me about your day."
    @State private var errorMessage: String?

    static let readingDuration = 30.0
    static let speechDuration = 30.0

    init(purpose: Purpose, profile: UserProfile, monitor: LiveVoiceMonitor, onComplete: @escaping (Bool) -> Void) {
        self.purpose = purpose
        self.profile = profile
        self.onComplete = onComplete
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .reading:
                header(
                    title: purpose == .dayOne ? "Record your Day 1 voice" : "Re-record your baseline",
                    detail: "Read this passage in your everyday voice, not your practice voice. This is your starting point: there’s no right or wrong."
                )
                passageCard(ReadingPassages.baseline)
                takeControls(duration: Self.readingDuration, startTitle: "Start reading") {
                    readingTake = BaselineStore.Take(result: $0, audio: recorder.audio, transcript: nil)
                    recorder.reset()
                    prompt = ReadingPassages.freeSpeechPrompts.randomElement() ?? prompt
                    step = .speech
                }
            case .speech:
                header(
                    title: "Now just talk",
                    detail: "Speak freely for about 30 seconds. Here’s an idea, but anything is fine:"
                )
                passageCard(prompt)
                takeControls(duration: Self.speechDuration, startTitle: "Start talking") { result in
                    let speechTake = BaselineStore.Take(result: result, audio: recorder.audio, transcript: nil)
                    Task { await save(speech: speechTake) }
                }
            case .saving:
                ProgressView("Saving your baseline…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
            }
        }
        .onDisappear {
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    private func header(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func passageCard(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    /// Start button, progress while recording, and the result with Redo/Next.
    @ViewBuilder
    private func takeControls(duration: Double, startTitle: String, onAccept: @escaping (TakeResult) -> Void) -> some View {
        switch recorder.phase {
        case .idle:
            Button {
                Task {
                    errorMessage = nil
                    await recorder.start(duration: duration, target: profile.targetZone, references: .none)
                }
            } label: {
                Label(startTitle, systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        case .starting, .recording:
            TakeProgressView(recorder: recorder, stopTitle: "I’m done")
        case .finished:
            if let result = recorder.result {
                VStack(alignment: .leading, spacing: 14) {
                    TakeResultSummary(result: result, showsTarget: false)
                        .cardStyle()
                    HStack(spacing: 12) {
                        Button("Redo") {
                            recorder.reset()
                        }
                        .buttonStyle(.glass)
                        Button {
                            onAccept(result)
                        } label: {
                            Text("Keep this")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!result.hasVoice)
                    }
                    .controlSize(.large)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "mic.slash")
                    .foregroundStyle(Theme.warning)
                Button("Try Again") {
                    recorder.reset()
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func save(speech: BaselineStore.Take) async {
        step = .saving
        do {
            try await BaselineStore.save(
                reading: readingTake,
                speech: speech,
                target: profile.targetZone,
                profile: profile,
                updatesProfile: purpose == .dayOne,
                context: modelContext
            )
            monitor.applyReferences(profile.personalReferences)
            await recorder.restoreMicrophone()
            onComplete(true)
        } catch {
            errorMessage = "Your baseline couldn’t be saved. Please try again."
            step = .reading
            recorder.reset()
        }
    }
}
