import Foundation
import Observation
import SwiftData
import SwiftUI

/// Analyzes a recording once, then renders and plays shifted versions.
@MainActor
@Observable
final class VoicePreviewModel {
    static let originalID = 1
    static let previewID = 2

    private(set) var source: VoicePreviewSource?
    private(set) var sourceTitle = ""
    private(set) var isAnalyzing = false
    private(set) var isRendering = false
    private(set) var errorMessage: String?
    var pitchSemitones = 0.0
    var resonancePercent = 0.0
    let player = SamplePlayer()

    @ObservationIgnored private var renderedSettings: VoicePreviewSettings?
    @ObservationIgnored private var renderedClip: AudioClip?
    @ObservationIgnored private var loadToken = UUID()

    var settings: VoicePreviewSettings {
        VoicePreviewSettings(pitchSemitones: pitchSemitones, resonancePercent: resonancePercent)
    }

    /// Analyzes a recording in the background and makes it the source.
    func load(_ clip: AudioClip, title: String) async {
        player.stop()
        let token = UUID()
        loadToken = token
        isAnalyzing = true
        errorMessage = nil
        source = nil
        renderedSettings = nil
        renderedClip = nil
        let analyzed = await Task.detached(priority: .userInitiated) {
            VoicePreviewSource.analyze(clip)
        }.value
        guard token == loadToken else { return }
        isAnalyzing = false
        guard analyzed.hasEnoughVoice else {
            errorMessage = "There isn’t enough clear voice in that recording. Try one with at least a second or two of speech."
            return
        }
        source = analyzed
        sourceTitle = title
    }

    func loadFile(_ url: URL, title: String) async {
        do {
            let clip = try await Task.detached(priority: .userInitiated) {
                try RecordingFileStore.readSamples(from: url)
            }.value
            await load(clip, title: title)
        } catch {
            errorMessage = "That recording couldn’t be opened."
        }
    }

    func reportMissingAudio() {
        errorMessage = "The recording didn’t come through. Please try again."
    }

    /// Sets the sliders to move the recording toward the targets.
    func applyTarget(pitch: Double, f2: Double) {
        let suggestion = VoicePreviewSettings.toward(
            sourcePitch: source?.medianPitch,
            targetPitch: pitch,
            sourceF2: source?.f2,
            targetF2: f2
        )
        pitchSemitones = suggestion.pitchSemitones
        resonancePercent = suggestion.resonancePercent
    }

    func resetSliders() {
        pitchSemitones = 0
        resonancePercent = 0
    }

    /// Plays (or stops) the original or the preview. Listening is paused
    /// first so the microphone doesn't hear it.
    func togglePlayback(original: Bool, monitor: LiveVoiceMonitor) async {
        let id = original ? Self.originalID : Self.previewID
        if player.playingID == id {
            player.stop()
            return
        }
        guard let source, !isRendering else { return }
        player.stop()
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }

        let clip: AudioClip
        if original {
            clip = source.clip
        } else if let renderedClip, renderedSettings == settings {
            clip = renderedClip
        } else {
            let current = settings
            let token = loadToken
            isRendering = true
            let made = await Task.detached(priority: .userInitiated) {
                source.render(current)
            }.value
            isRendering = false
            guard token == loadToken else { return }
            renderedSettings = current
            renderedClip = made
            clip = made
        }
        player.play(clip, range: 0...clip.duration, id: id)
    }

    func shutDown() {
        loadToken = UUID()
        player.shutDown()
    }
}

/// Voice Preview (SPEC section 8, advanced): shifts the pitch and resonance
/// of your own recording for a rough idea of where training could lead.
/// Clearly labelled as an approximation; nothing is saved.
struct VoicePreviewView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        VoicePreviewContent(monitor: monitor)
    }
}

private struct VoicePreviewContent: View {
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var recorder: VoiceTakeRecorder
    @State private var model = VoicePreviewModel()
    @State private var isPickingRecording = false

    /// Seconds recorded for a new take.
    private static let takeDuration = 8.0

    init(monitor: LiveVoiceMonitor) {
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var profile: UserProfile? { profiles.first }
    private var targetZone: PitchTargetZone { profile?.targetZone ?? recorder.monitor.targetZone }
    private var targetF2: Double {
        (profile?.personalReferences ?? .none).resonance(for: .speech).targetF2
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NoticeBanner(
                    title: "A rough approximation",
                    message: "Voice Preview shifts the pitch and resonance of a recording with simple signal processing. Training changes much more (vocal weight, intonation, the way you shape sounds), so your real voice will sound different, and usually more natural. Treat this as a curiosity, not a goal to copy.",
                    systemImage: "wand.and.stars",
                    tint: Theme.pitchLine
                )

                sourceCard

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let source = model.source {
                    adjustCard(source)
                    listenCard(source)
                }

                Label("Made on this iPhone and never saved or sent anywhere.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Voice Preview")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPickingRecording) {
            VoicePreviewRecordingPicker { url, title in
                isPickingRecording = false
                Task { await model.loadFile(url, title: title) }
            }
        }
        .onChange(of: recorder.phase) { _, phase in
            guard phase == .finished else { return }
            Task {
                await recorder.restoreMicrophone()
                if let audio = recorder.audio {
                    await model.load(audio, title: "New recording")
                } else {
                    model.reportMissingAudio()
                }
            }
        }
        .onDisappear {
            recorder.cancel()
            model.shutDown()
            Task { await recorder.restoreMicrophone() }
        }
    }

    // MARK: Cards

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Your recording")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if recorder.isRecording {
                Text(ReadingPassages.quickCheck)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                TakeProgressView(recorder: recorder)
            } else {
                Text("Record about \(Int(Self.takeDuration)) seconds in your current, comfortable voice (you’ll see a sentence to read), or use a recording you saved before.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = recorder.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        recordButton
                        pickButton
                    }
                    VStack(spacing: 10) {
                        recordButton
                        pickButton
                    }
                }
                .disabled(model.isAnalyzing)
            }

            if model.isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Analyzing your recording…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            } else if let source = model.source {
                VoicePreviewSourceSummary(title: model.sourceTitle, source: source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var recordButton: some View {
        Button {
            Task {
                model.player.stop()
                await recorder.start(duration: Self.takeDuration, target: targetZone)
            }
        } label: {
            Label("Record", systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var pickButton: some View {
        Button {
            model.player.stop()
            isPickingRecording = true
        } label: {
            Label("Saved recording", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func adjustCard(_ source: VoicePreviewSource) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Text("2. Adjust")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text(VoicePreviewFormat.pitch(model.pitchSemitones, from: source.medianPitch))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Slider(value: $model.pitchSemitones, in: VoicePreviewSettings.pitchRange, step: 0.5) {
                    Text("Pitch")
                }
                .accessibilityValue(VoicePreviewFormat.spokenPitch(model.pitchSemitones))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Resonance")
                    Spacer()
                    Text(VoicePreviewFormat.resonance(model.resonancePercent))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Slider(value: $model.resonancePercent, in: VoicePreviewSettings.resonanceRange, step: 1) {
                    Text("Resonance")
                }
                .accessibilityValue(VoicePreviewFormat.spokenResonance(model.resonancePercent))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    targetButton
                    resetButton
                }
                VStack(spacing: 10) {
                    targetButton
                    resetButton
                }
            }

            Text("Your targets: \(targetZone.formatted), resonance (F2) about \(Int(targetF2.rounded())) Hz. Bigger shifts sound more processed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var targetButton: some View {
        Button {
            model.applyTarget(pitch: targetZone.center, f2: targetF2)
        } label: {
            Label("Toward my target", systemImage: "scope")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
    }

    private var resetButton: some View {
        Button {
            model.resetSliders()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .disabled(model.settings.isUnchanged)
    }

    private func listenCard(_ source: VoicePreviewSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Listen")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                playButton(original: true, title: "Original")
                playButton(original: false, title: "Preview")
            }
            .controlSize(.large)
            if let message = model.player.errorMessage {
                Label(message, systemImage: "headphones")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Listen with headphones for the clearest comparison.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private func playButton(original: Bool, title: String) -> some View {
        if original {
            playButtonBase(original: true, title: title)
                .buttonStyle(.glass)
        } else {
            playButtonBase(original: false, title: title)
                .buttonStyle(.glassProminent)
        }
    }

    private func playButtonBase(original: Bool, title: String) -> some View {
        let id = original ? VoicePreviewModel.originalID : VoicePreviewModel.previewID
        let isPlaying = model.player.playingID == id
        let isWorking = !original && model.isRendering
        return Button {
            Task { await model.togglePlayback(original: original, monitor: recorder.monitor) }
        } label: {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .accessibilityHidden(true)
                }
                Text(isPlaying ? "Stop" : title)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(model.isRendering)
        .accessibilityLabel(isPlaying ? "Stop \(title.lowercased())" : "Play \(title.lowercased())")
    }
}

/// What was measured in the source recording.
private struct VoicePreviewSourceSummary: View {
    let title: String
    let source: VoicePreviewSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.targetZone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [SessionFormat.duration(source.clip.duration)]
        if let pitch = source.medianPitch {
            parts.append("pitch \(SessionFormat.hertz(pitch))")
        }
        if let f2 = source.f2 {
            parts.append("F2 \(Int(f2.rounded())) Hz")
        }
        return parts.joined(separator: " · ")
    }
}

/// Lists saved recordings to preview.
private struct VoicePreviewRecordingPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    let onPick: (URL, String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Save a clip while practicing, record your journal sentence, or tap Record on the previous screen.")
                    )
                } else {
                    List(recordings) { recording in
                        Button {
                            if let url = recording.fileURL {
                                onPick(url, "\(recording.kind.title), \(recording.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recording.kind.title)
                                    .font(.headline)
                                Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(SessionFormat.duration(recording.duration))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let transcript = recording.transcript, !transcript.isEmpty {
                                    Text(transcript)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Choose a recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Labels for the Voice Preview sliders.
nonisolated enum VoicePreviewFormat {
    static func pitch(_ semitones: Double, from pitch: Double?) -> String {
        let change = signed(semitones, digits: 1) + " st"
        guard let pitch, pitch > 0 else { return change }
        let shifted = pitch * pow(2, semitones / 12)
        return "\(change) (\(Int(pitch.rounded())) → \(Int(shifted.rounded())) Hz)"
    }

    static func resonance(_ percent: Double) -> String {
        let change = signed(percent, digits: 0) + " %"
        if percent > 0.5 {
            return change + " brighter"
        } else if percent < -0.5 {
            return change + " darker"
        }
        return change
    }

    static func spokenPitch(_ semitones: Double) -> String {
        abs(semitones) < 0.01 ? "No change" : "\(semitones > 0 ? "Up" : "Down") \(abs(semitones).formatted(.number.precision(.fractionLength(0...1)))) semitones"
    }

    static func spokenResonance(_ percent: Double) -> String {
        abs(percent) < 0.5 ? "No change" : "\(Int(abs(percent).rounded())) percent \(percent > 0 ? "brighter" : "darker")"
    }

    /// "+4.5", "−3", "0".
    static func signed(_ value: Double, digits: Int) -> String {
        let rounded = digits > 0 ? (value * 10).rounded() / 10 : value.rounded()
        guard abs(rounded) > 0.0001 else { return "0" }
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(0...max(0, digits))))
        return (rounded > 0 ? "+" : "−") + magnitude
    }
}
