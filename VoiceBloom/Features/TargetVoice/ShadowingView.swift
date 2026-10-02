import Charts
import Foundation
import SwiftData
import SwiftUI

/// Shadowing (SPEC section 9): hear a short phrase of the target, repeat
/// it, and see both pitch contours on top of each other.
struct ShadowingView: View {
    let target: TargetVoiceProfile
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        ShadowingContent(target: target, monitor: monitor)
    }
}

private enum ShadowingLoadState {
    case loading
    case ready(ShadowingMaterial)
    case failed(String)
}

private enum ShadowingStage: Equatable {
    case ready
    case listening
    case repeating
}

/// One try at a phrase.
private struct ShadowingAttempt {
    let segmentIndex: Int
    let target: [PitchContourPoint]
    let user: [PitchContourPoint]
    let comparison: ContourComparison
    let audio: AudioClip?
}

private struct ShadowingContent: View {
    let target: TargetVoiceProfile
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var recorder: VoiceTakeRecorder
    @State private var player = SamplePlayer()
    @State private var loadState: ShadowingLoadState = .loading
    @State private var selectedIndex = 0
    @State private var stage: ShadowingStage = .ready
    @State private var attempt: ShadowingAttempt?
    @State private var errorMessage: String?

    init(target: TargetVoiceProfile, monitor: LiveVoiceMonitor) {
        self.target = target
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var monitor: LiveVoiceMonitor { recorder.monitor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Listen to a phrase, then say it back the same way. Follow the melody (the rises and falls) more than the exact pitch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch loadState {
                case .loading:
                    ProgressView("Finding phrases in the clip…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .failed(let message):
                    ContentUnavailableView("Shadowing unavailable", systemImage: "waveform.slash", description: Text(message))
                case .ready(let material):
                    practice(material)
                }

                TargetGuideNote()
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Shadowing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .onDisappear {
            stage = .ready
            player.shutDown()
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    // MARK: Practice

    @ViewBuilder
    private func practice(_ material: ShadowingMaterial) -> some View {
        let segments = material.segments
        let index = min(selectedIndex, max(segments.count - 1, 0))

        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(segments) { segment in
                    FilterChip(
                        title: "Phrase \(segment.index + 1) · \(Int(segment.duration.rounded())) s",
                        systemImage: "text.bubble",
                        isSelected: segment.index == index
                    ) {
                        select(segment.index)
                    }
                    .disabled(stage != .ready)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)

        if segments.indices.contains(index) {
            let segment = segments[index]
            VStack(alignment: .leading, spacing: 14) {
                switch stage {
                case .ready:
                    HStack(spacing: 10) {
                        Button {
                            Task { await listen(segment, material: material) }
                        } label: {
                            Label("Listen", systemImage: "ear")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        Button {
                            Task { await listenThenRepeat(segment, material: material) }
                        } label: {
                            Label("Listen, then repeat", systemImage: "repeat")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                case .listening:
                    Label("Listen…", systemImage: "ear")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                case .repeating:
                    Text("Your turn")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    TakeProgressView(recorder: recorder)
                }

                if let message = player.errorMessage ?? errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }

                if let attempt, attempt.segmentIndex == segment.index, stage == .ready {
                    AttemptResult(attempt: attempt)
                    HStack(spacing: 10) {
                        if let audio = attempt.audio {
                            Button {
                                Task { await playAttempt(audio) }
                            } label: {
                                Label("Hear yourself", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        if segment.index + 1 < segments.count {
                            Button {
                                select(segment.index + 1)
                            } label: {
                                Label("Next phrase", systemImage: "forward.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .controlSize(.large)
                }
            }
            .cardStyle()
        }
    }

    // MARK: Actions

    private func load() async {
        guard case .loading = loadState else { return }
        guard let url = target.clipFileURL else {
            loadState = .failed("This target voice has no saved clip.")
            return
        }
        let zone = profiles.first?.targetZone ?? monitor.targetZone
        do {
            let material = try await Task.detached(priority: .userInitiated) {
                try ShadowingMaterial.load(url: url, target: zone)
            }.value
            loadState = material.segments.isEmpty
                ? .failed("No clear phrases were found in this clip. Try a clip with more continuous speech.")
                : .ready(material)
        } catch {
            loadState = .failed("The clip couldn’t be loaded.")
        }
    }

    private func select(_ index: Int) {
        player.stop()
        attempt = nil
        errorMessage = nil
        selectedIndex = index
    }

    /// Listening pauses so the microphone doesn't count the clip as practice.
    private func pauseListening() async {
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
    }

    private func listen(_ segment: ShadowingSegment, material: ShadowingMaterial) async {
        await pauseListening()
        stage = .listening
        if player.play(material.clip, range: segment.start...segment.end, id: segment.index) {
            try? await Task.sleep(for: .seconds(segment.duration + 0.2))
        }
        if stage == .listening {
            stage = .ready
        }
    }

    private func listenThenRepeat(_ segment: ShadowingSegment, material: ShadowingMaterial) async {
        attempt = nil
        errorMessage = nil
        await pauseListening()
        stage = .listening
        guard player.play(material.clip, range: segment.start...segment.end, id: segment.index) else {
            stage = .ready
            return
        }
        // Let the phrase (and the room's echo) finish before listening.
        try? await Task.sleep(for: .seconds(segment.duration + 0.4))
        guard stage == .listening, selectedIndex == segment.index else { return }

        stage = .repeating
        let profile = profiles.first
        await recorder.start(
            duration: min(segment.duration + 1.5, 10),
            target: profile?.targetZone ?? monitor.targetZone,
            references: profile?.personalReferences ?? .none
        )
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard stage == .repeating, selectedIndex == segment.index else { return }

        if let result = recorder.result {
            let targetContour = material.contour(for: segment)
            attempt = ShadowingAttempt(
                segmentIndex: segment.index,
                target: targetContour,
                user: result.contour,
                comparison: ContourComparison.compare(target: targetContour, user: result.contour),
                audio: recorder.audio
            )
        } else if case .failed(let message) = recorder.phase {
            errorMessage = message
        }
        recorder.reset()
        stage = .ready
    }

    private func playAttempt(_ audio: AudioClip) async {
        await pauseListening()
        player.play(audio, range: 0...audio.duration, id: 10_000)
    }
}

private struct ContourPoint: Identifiable {
    let id: Int
    let voice: String
    let time: Double
    let frequency: Double
}

/// Both contours on one chart, plus the melody match.
private struct AttemptResult: View {
    let attempt: ShadowingAttempt

    private var points: [ContourPoint] {
        var result: [ContourPoint] = []
        let targetStart = attempt.target.first?.time ?? 0
        let userStart = attempt.user.first?.time ?? 0
        for (index, point) in attempt.target.enumerated() {
            result.append(ContourPoint(id: index, voice: "Target", time: point.time - targetStart, frequency: point.frequency))
        }
        let offset = attempt.target.count
        for (index, point) in attempt.user.enumerated() {
            result.append(ContourPoint(id: offset + index, voice: "You", time: point.time - userStart, frequency: point.frequency))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if attempt.user.isEmpty {
                Label("No voice was detected. Try again a little closer to the phone.", systemImage: "mic.slash")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    if let shape = attempt.comparison.shapeMatch {
                        Text("\(Int(shape.rounded()))%")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("melody match")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Say the whole phrase to see the melody match.")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                if let level = attempt.comparison.levelDifference {
                    Text(levelText(level))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Chart(points) { point in
                    PointMark(
                        x: .value("Time", point.time),
                        y: .value("Pitch", point.frequency)
                    )
                    .symbolSize(10)
                    .foregroundStyle(by: .value("Voice", point.voice))
                }
                .chartForegroundStyleScale(domain: ["Target", "You"], range: [Theme.resonanceSeries, Theme.pitchLine])
                .chartXAxisLabel("Seconds")
                .chartYAxisLabel("Hz")
                .frame(height: 180)
                .accessibilityLabel("Pitch contours of the target and your attempt")
            }
        }
    }

    private func levelText(_ semitones: Double) -> String {
        let amount = abs(semitones)
        if amount < 1 {
            return "You were right at the target’s pitch level."
        }
        let rounded = amount.formatted(.number.precision(.fractionLength(1)))
        let direction = semitones < 0 ? "lower" : "higher"
        return "You were \(rounded) semitones \(direction) than the target. That’s fine: match the shape first, then move toward your own target range."
    }
}
