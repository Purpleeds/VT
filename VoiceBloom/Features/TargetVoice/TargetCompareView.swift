import Charts
import Foundation
import SwiftData
import SwiftUI

/// Compare to Target (SPEC section 9): record a short reading, then overlay
/// your pitch histogram and formants on the target's, with a % match for
/// each category.
struct TargetCompareView: View {
    let target: TargetVoiceProfile
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        TargetCompareContent(target: target, monitor: monitor)
    }
}

private struct TargetCompareContent: View {
    let target: TargetVoiceProfile
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var recorder: VoiceTakeRecorder

    static let duration = 15.0

    init(target: TargetVoiceProfile, monitor: LiveVoiceMonitor) {
        self.target = target
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Read this in your practice voice. We’ll compare it with \(target.name).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReadingPassages.compare)
                    .font(.title3)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                controls

                if recorder.phase == .finished, let result = recorder.result {
                    if result.hasVoice {
                        CompareResults(user: VoiceSnapshot(take: result), target: target)
                    } else {
                        Label("No voice was detected. Try again a little closer to the phone.", systemImage: "mic.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                TargetGuideNote()
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Compare to Target")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .idle:
            startButton("Start Recording")
        case .starting, .recording:
            TakeProgressView(recorder: recorder)
        case .finished:
            Button {
                recorder.reset()
            } label: {
                Label("Record Again", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.warning)
            startButton("Try Again")
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            Task {
                let profile = profiles.first
                await recorder.start(
                    duration: TargetCompareContent.duration,
                    target: profile?.targetZone ?? recorder.monitor.targetZone,
                    references: profile?.personalReferences ?? .none
                )
            }
        } label: {
            Label(title, systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

/// The % match per category, the pitch histograms and the formants.
private struct CompareResults: View {
    let user: VoiceSnapshot
    let target: TargetVoiceProfile

    var body: some View {
        let targetSnapshot = target.snapshot
        let matches = TargetComparison.matches(user: user, target: targetSnapshot)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                if let overall = TargetComparison.overall(matches) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(overall.roundedInt)%")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        Text("overall match")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(matches) { match in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(match.category.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(match.percent.roundedInt)%")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        MeterBar(fraction: match.percent / 100, tint: Theme.targetZone)
                            .frame(height: 8)
                        Text(match.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(match.category.title)
                    .accessibilityValue("\(match.percent.roundedInt) percent match. \(match.detail)")
                }
                Text("A partial match is normal: everyone’s voice and vocal tract are different. Small steps in the right direction count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 8) {
                Text("Pitch")
                    .font(.headline)
                PitchHistogramChart(series: [
                    HistogramSeries(name: "You", histogram: user.pitchHistogram, color: Theme.pitchLine),
                    HistogramSeries(name: "Target", histogram: targetSnapshot.pitchHistogram, color: Theme.resonanceSeries),
                ])
                .frame(height: 180)
            }
            .cardStyle()

            if !formantBars(targetSnapshot).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Formants")
                        .font(.headline)
                    Chart(formantBars(targetSnapshot)) { bar in
                        BarMark(
                            x: .value("Formant", bar.formant),
                            y: .value("Frequency", bar.frequency)
                        )
                        .foregroundStyle(by: .value("Voice", bar.voice))
                        .position(by: .value("Voice", bar.voice))
                        .accessibilityLabel("\(bar.voice) \(bar.formant)")
                        .accessibilityValue("\(bar.frequency.roundedInt) hertz")
                    }
                    .chartForegroundStyleScale(domain: ["You", "Target"], range: [Theme.pitchLine, Theme.resonanceSeries])
                    .chartYAxisLabel("Hz")
                    .frame(height: 180)
                    Text("Higher F2 and F3 sound brighter (resonance). F1 mostly follows the vowel and how open your mouth is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cardStyle()
            }
        }
    }

    private func formantBars(_ target: VoiceSnapshot) -> [FormantBar] {
        let pairs: [(String, Double?, Double?)] = [
            ("F1", user.f1, target.f1),
            ("F2", user.f2, target.f2),
            ("F3", user.f3, target.f3),
        ]
        var bars: [FormantBar] = []
        for (formant, mine, theirs) in pairs {
            guard let mine, let theirs else { continue }
            bars.append(FormantBar(formant: formant, voice: "You", frequency: mine))
            bars.append(FormantBar(formant: formant, voice: "Target", frequency: theirs))
        }
        return bars
    }
}

private struct FormantBar: Identifiable {
    let formant: String
    let voice: String
    let frequency: Double

    var id: String { "\(formant)-\(voice)" }
}
