import Foundation
import SwiftUI

/// Progress ring, seconds left and live pitch while a take records.
struct TakeProgressView: View {
    let recorder: VoiceTakeRecorder
    var stopTitle = "Done"
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 150
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var secondsLeft: Int {
        max(0, Int((recorder.plannedDuration - recorder.elapsed).rounded(.up)))
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: recorder.progress)
                    .stroke(Theme.targetZone, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: recorder.progress)
                VStack(spacing: 2) {
                    if recorder.phase == .starting {
                        ProgressView()
                    } else {
                        Text("\(secondsLeft)")
                            .font(.system(size: ringSize * 0.32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: ringSize, height: ringSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue("\(secondsLeft) seconds left")

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text(recorder.livePitch.map { "\(Int($0.rounded())) Hz" } ?? "Listening…")
                    .monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(recorder.livePitch == nil ? Color.secondary : Theme.pitchLine)

            MeterBar(fraction: recorder.liveLevel, tint: Theme.pitchLine)
                .frame(width: ringSize, height: 6)

            if recorder.phase == .recording {
                Button(stopTitle) {
                    recorder.finish()
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Key numbers from a finished take.
struct TakeResultSummary: View {
    let result: TakeResult
    var showsTarget = true

    var body: some View {
        if !result.hasVoice {
            Label("No voice was detected. Try again a little closer to the phone.", systemImage: "mic.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatTile(title: "Average pitch", value: result.medianPitch.map(SessionFormat.hertz) ?? "—")
                    StatTile(title: "Range", value: SessionFormat.range(low: result.lowPitch, high: result.highPitch))
                    if showsTarget {
                        StatTile(title: "In target", value: result.percentInTarget.map(SessionFormat.percent) ?? "—")
                    }
                }
                HStack(spacing: 12) {
                    StatTile(title: "Resonance", value: SessionFormat.score(result.resonanceScore))
                    StatTile(title: "Weight", value: SessionFormat.score(result.weightScore))
                    StatTile(title: "Intonation", value: SessionFormat.score(result.intonationScore))
                }
            }
        }
    }
}

/// A numbered step indicator ("Step 3 of 9").
struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(current) of \(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...max(total, 1), id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Theme.targetZone : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}
