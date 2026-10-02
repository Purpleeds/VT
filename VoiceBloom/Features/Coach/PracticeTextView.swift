import Foundation
import SwiftData
import SwiftUI

/// Practice text generator (SPEC section 10): fresh reading passages that
/// target specific sounds, then read one aloud and see the scores.
struct PracticeTextView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        PracticeTextContent(monitor: monitor)
    }
}

private struct PracticeTextContent: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var recorder: VoiceTakeRecorder
    @State private var focus: PracticeFocus = .brightVowels
    @State private var length: PracticeLength = .medium
    @State private var passage: PracticeText?
    @State private var variation = 0
    @State private var isLoading = false
    @State private var note: String?

    init(monitor: LiveVoiceMonitor) {
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var profile: UserProfile? { profiles.first }
    private var engine: CoachEngine { CoachRouter.engine(enabled: profile?.aiCoachEnabled ?? false) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Practice", selection: $focus) {
                        ForEach(PracticeFocus.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Length", selection: $length) {
                        ForEach(PracticeLength.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button {
                        Task { await generate() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(passage == nil ? "Write a passage" : "Another one", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(isLoading || recorder.isRecording)
                    CoachEngineLabel(engine: engine)
                    if engine.sendsTextOffDevice {
                        Text("Only the request (focus and length) is sent to Gemini as text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .cardStyle()

                if let passage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(passage.title)
                            .font(.headline)
                        Text(passage.text)
                            .font(.title3)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                    readingControls
                }

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Practice Texts")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focus) { _, _ in variation = 0 }
        .onDisappear {
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    @ViewBuilder
    private var readingControls: some View {
        switch recorder.phase {
        case .idle:
            readButton
        case .starting, .recording:
            TakeProgressView(recorder: recorder)
        case .finished:
            if let result = recorder.result {
                TakeResultSummary(result: result)
                    .cardStyle()
            }
            Button("Read it again") {
                recorder.reset()
            }
            .buttonStyle(.glass)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.warning)
            readButton
        }
    }

    private var readButton: some View {
        Button {
            Task {
                let seconds = Double(length.sentenceCount) * 6 + 4
                await recorder.start(
                    duration: seconds,
                    target: profile?.targetZone ?? recorder.monitor.targetZone,
                    references: profile?.personalReferences ?? .none
                )
            }
        } label: {
            Label("Read it aloud", systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func generate() async {
        isLoading = true
        defer { isLoading = false }
        recorder.reset()
        let request = PracticeTextRequest(focus: focus, length: length, variation: variation)
        variation += 1
        let enabled = profile?.aiCoachEnabled ?? false
        guard let outcome = await CoachRouter.run(enabled: enabled, { service in
            try await service.practiceText(request)
        }) else { return }
        passage = outcome.value
        note = outcome.fallbackNote
    }
}
