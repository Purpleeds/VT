import Foundation
import SwiftUI

/// Mic calibration sheet: room noise, then voice level, then results.
/// Reused by onboarding in a later stage.
struct MicCalibrationView: View {
    @State private var model: MicCalibrationModel
    @Environment(\.dismiss) private var dismiss

    init(monitor: LiveVoiceMonitor) {
        _model = State(initialValue: MicCalibrationModel(monitor: monitor))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch model.step {
                    case .intro:
                        introContent
                    case .measuringNoise:
                        MeasuringStepView(
                            systemImage: "ear",
                            title: "Stay quiet…",
                            message: "Measuring the background noise of the room for 5 seconds.",
                            progress: model.progress,
                            levelDb: model.currentLevelDb
                        )
                    case .measuringVoice:
                        MeasuringStepView(
                            systemImage: "waveform",
                            title: "Now say “aah”",
                            message: "Hold a comfortable “aah” at your normal speaking volume until the bar fills.",
                            progress: model.progress,
                            levelDb: model.currentLevelDb
                        )
                    case .finished:
                        resultsContent
                    case .failed(let message):
                        failedContent(message)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background { AppBackground() }
            .navigationTitle("Mic Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isSaved ? "Done" : "Cancel") {
                        Task {
                            await model.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(model.isMeasuring)
        }
        .onChange(of: model.monitorStatus) { _, newStatus in
            model.monitorStatusChanged(newStatus)
        }
        .onDisappear {
            Task { await model.cancel() }
        }
    }

    // MARK: Steps

    private var introContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.and.signal.meter")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Calibrate your microphone")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("This takes about 15 seconds and makes the meters more accurate in your room.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                Label("Hold your iPhone the way you will while practicing, about an arm’s length away.", systemImage: "iphone")
                Label("First, stay quiet for 5 seconds while the room is measured.", systemImage: "1.circle")
                Label("Then say a comfortable “aah” for a few seconds.", systemImage: "2.circle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            Button {
                Task { await model.begin() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var resultsContent: some View {
        VStack(spacing: 20) {
            Image(systemName: model.isSaved ? "checkmark.seal.fill" : "list.bullet.clipboard")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(model.isSaved ? "Calibration saved" : "Results")
                .font(.title2.bold())

            if let noise = model.noise {
                CalibrationResultRow(
                    title: "Room noise",
                    verdict: noiseVerdictText(noise),
                    systemImage: noiseIcon(noise.verdict),
                    isGood: noise.verdict != .tooNoisy,
                    detail: "\(decibels(noise.floorDb)). \(noiseAdvice(noise))"
                )
            }
            if let voice = model.voice {
                CalibrationResultRow(
                    title: "Your voice",
                    verdict: voiceVerdictText(voice.verdict),
                    systemImage: voice.verdict == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    isGood: voice.verdict == .good,
                    detail: "\(decibels(voice.levelDb)), \(voice.signalToNoiseDb.roundedInt) dB above the room. \(voiceAdvice(voice.verdict))"
                )
            }

            if model.isSaved {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                Button {
                    Task { await model.save() }
                } label: {
                    Label("Save Calibration", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    Task { await model.begin() }
                } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 20) {
            NoticeBanner(title: "Calibration didn’t finish", message: message, systemImage: "exclamationmark.triangle.fill")
            Button {
                Task { await model.begin() }
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    // MARK: Wording

    private func decibels(_ value: Double) -> String {
        "\(value.roundedInt) dBFS"
    }

    private func noiseVerdictText(_ noise: NoiseAssessment) -> String {
        switch noise.verdict {
        case .quiet: "Quiet"
        case .acceptable: "Some background noise"
        case .tooNoisy: "Too noisy"
        }
    }

    private func noiseIcon(_ verdict: NoiseVerdict) -> String {
        switch verdict {
        case .quiet: "checkmark.circle.fill"
        case .acceptable: "exclamationmark.circle.fill"
        case .tooNoisy: "exclamationmark.triangle.fill"
        }
    }

    private func noiseAdvice(_ noise: NoiseAssessment) -> String {
        var advice: String
        switch noise.verdict {
        case .quiet:
            advice = "Great for practice."
        case .acceptable:
            advice = "Readings should still be fine."
        case .tooNoisy:
            advice = "Background noise will make resonance and weight readings unreliable. A quieter room will help."
        }
        if noise.isUnsteady {
            advice += " The noise changed while measuring; if something was briefly loud, try again."
        }
        return advice
    }

    private func voiceVerdictText(_ verdict: VoiceLevelVerdict) -> String {
        switch verdict {
        case .good: "Good level"
        case .tooQuiet: "Too quiet"
        case .tooLoud: "Too loud"
        }
    }

    private func voiceAdvice(_ verdict: VoiceLevelVerdict) -> String {
        switch verdict {
        case .good:
            "Your voice is clearly above the room noise."
        case .tooQuiet:
            "Hold the phone a little closer or speak a bit louder. Never strain to be louder."
        case .tooLoud:
            "The mic is close to distorting. Hold the phone a little farther away."
        }
    }
}

/// Live step with a progress bar and an input level meter.
private struct MeasuringStepView: View {
    let systemImage: String
    let title: String
    let message: String
    let progress: Double
    let levelDb: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Progress")
                .accessibilityValue("\((progress * 100).roundedInt) percent")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Input level")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(levelDb.map { "\($0.roundedInt) dBFS" } ?? "—")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                MeterBar(fraction: levelFraction)
                    .frame(height: 10)
            }
            .cardStyle()
            .accessibilityElement(children: .combine)
        }
    }

    private var levelFraction: Double {
        guard let levelDb else { return 0 }
        return (min(max(levelDb, -90), 0) + 90) / 90
    }
}

/// One line of the results summary (icon + verdict + explanation).
private struct CalibrationResultRow: View {
    let title: String
    let verdict: String
    let systemImage: String
    let isGood: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(isGood ? Theme.targetZone : Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(verdict)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}
