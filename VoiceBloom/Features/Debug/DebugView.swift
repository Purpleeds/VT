import Foundation
import os
import SwiftUI

/// Raw analysis values for tuning on a real device.
struct DebugView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var isShowingCalibration = false

    var body: some View {
        List {
            DebugTestingSection()

            Section {
                LivePitchGraph(showsRawEstimates: true)
                    .frame(height: 200)
                    .padding(.vertical, 8)
                DebugControls()
            } footer: {
                Text("Grey dots are raw YIN estimates (including frames the noise gate rejects). The line is the gated, octave-checked, median-filtered and smoothed pitch.")
            }

            Section("Pitch") {
                LabeledContent("Raw YIN", value: hertz(frame?.rawFrequency, decimals: 1))
                LabeledContent("Median filtered", value: hertz(frame?.filteredFrequency, decimals: 1))
                LabeledContent("Displayed", value: hertz(frame?.displayFrequency, decimals: 1))
                LabeledContent("Note", value: noteDescription)
                LabeledContent("Aperiodicity", value: number(frame?.aperiodicity, decimals: 3))
                LabeledContent("Frame status", value: frame?.status.displayName ?? "—")
            }

            Section {
                LabeledContent("Input level", value: decibels(frame?.levelDb))
                LabeledContent("Noise floor (adaptive)", value: decibels(frame?.noiseFloorDb))
                LabeledContent("Voice gate", value: decibels(frame?.gateThresholdDb))
                if let frame {
                    LevelMeter(
                        levelDb: frame.levelDb,
                        noiseFloorDb: frame.noiseFloorDb,
                        gateDb: frame.gateThresholdDb
                    )
                    .frame(height: 28)
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Level")
            } footer: {
                Text("Frames quieter than the voice gate (noise floor + margin) are ignored. After calibration, the measured room level is the lowest the floor can go.")
            }

            Section {
                LabeledContent("F1", value: formantText(formants?.f1))
                LabeledContent("F2", value: formantText(formants?.f2))
                LabeledContent("F3", value: formantText(formants?.f3))
                LabeledContent("Stable frame", value: frame.map { $0.isStable ? "Yes" : "No" } ?? "—")
                LabeledContent("Analysis rate", value: monitor.spectralSampleRate.map { "\($0.formatted(.number.precision(.fractionLength(0)))) Hz" } ?? "—")
                LabeledContent("Resonance score", value: score(monitor.resonance?.score))
                LabeledContent("Reference", value: referenceText)
            } header: {
                Text("Formants (LPC)")
            } footer: {
                Text("Last stable frame: centre frequency (bandwidth). LPC order 12 after decimating to ~12 kHz, with pre-emphasis and a Hamming window. The score uses the median F2/F3 over the last \(monitor.resonanceMode.averagingWindow.formatted()) s.")
            }

            Section {
                LabeledContent("H1–H2 (raw)", value: decibelText(weightMeasurement?.h1MinusH2, unit: "dB"))
                LabeledContent("H1*–H2* (corrected)", value: decibelText(weightMeasurement?.correctedH1MinusH2, unit: "dB"))
                LabeledContent("Spectral tilt", value: decibelText(weightMeasurement?.spectralTilt, unit: "dB/oct"))
                LabeledContent("Weight score", value: score(monitor.weight?.score))
            } header: {
                Text("Vocal weight")
            } footer: {
                Text("Corrected values remove the boost F1/F2/F3 give nearby harmonics (Iseli–Alwan). Higher H1–H2 and a steeper tilt read as lighter.")
            }

            Section {
                LabeledContent("Variability", value: phrase.map { "±\($0.standardDeviationSemitones.formatted(.number.precision(.fractionLength(2)))) st" } ?? "—")
                LabeledContent("Range", value: phrase.map { "\($0.rangeSemitones.formatted(.number.precision(.fractionLength(1)))) st" } ?? "—")
                LabeledContent("Rises / falls", value: phrase.map { "\($0.rises) / \($0.falls)" } ?? "—")
                LabeledContent("Voiced duration", value: phrase.map { "\($0.voicedDuration.formatted(.number.precision(.fractionLength(1)))) s" } ?? "—")
                LabeledContent("Intonation score", value: score(monitor.intonation?.score))
            } header: {
                Text("Intonation (last phrase)")
            } footer: {
                Text("A phrase ends after a 0.35 s pause and needs at least 0.6 s of voicing. Rises and falls count movements of 2+ semitones.")
            }

            Section {
                LabeledContent("Jitter (last frame)", value: percent(quality?.latest?.jitterPercent))
                LabeledContent("Shimmer (last frame)", value: percent(quality?.latest?.shimmerPercent))
                LabeledContent("HNR (last frame)", value: decibelText(quality?.latest?.harmonicsToNoiseDb, unit: "dB"))
                LabeledContent("Cycles marked", value: quality?.latest.map { "\($0.cycleCount)" } ?? "—")
                LabeledContent("Recent median (20 s)", value: summaryText(quality?.assessment?.recent))
                LabeledContent("Normal", value: summaryText(quality?.assessment?.reference))
                LabeledContent("Normal comes from", value: referenceSource)
                LabeledContent("Roughness vs normal", value: quality?.assessment.map { "×\($0.roughnessRatio.formatted(.number.precision(.fractionLength(2))))" } ?? "—")
                LabeledContent("Session average", value: summaryText(quality?.session))
            } header: {
                Text("Voice quality")
            } footer: {
                Text("Measured on every 4th stable frame. A warning needs roughness ×1.3 or more for 10 s, with 100+ recent measurements. Rough indicators, not a diagnosis.")
            }

            Section {
                LabeledContent("Active slips", value: slipText)
                LabeledContent("Pitch floor", value: "\(monitor.slipConfiguration.pitchFloor.roundedInt) Hz")
                LabeledContent("Resonance threshold", value: "\(Int(monitor.slipConfiguration.resonanceThreshold)) / 100")
                LabeledContent("Delay", value: "\(monitor.slipConfiguration.delay.formatted()) s")
                LabeledContent("Haptics supported", value: monitor.supportsHaptics ? "Yes" : "No")
                Button("Play Pitch Slip Cue") { monitor.preview(.slip([.pitch])) }
                Button("Play Resonance Slip Cue") { monitor.preview(.slip([.resonance])) }
                Button("Play Strain Cue") { monitor.preview(.strain) }
            } header: {
                Text("Slip alerts")
            }

            Section {
                if let calibration = monitor.calibration {
                    LabeledContent("Room noise floor", value: decibels(calibration.noiseFloorDb))
                    LabeledContent("Voice level", value: decibels(calibration.voiceLevelDb))
                    LabeledContent("Voice peak", value: decibels(calibration.voicePeakDb))
                    LabeledContent("Microphone", value: calibration.inputName)
                    LabeledContent("Calibrated", value: calibration.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("In use", value: monitor.isCalibrationInUse ? "Yes" : "No (different mic)")
                    Button("Clear Calibration", role: .destructive) {
                        Task { await monitor.clearCalibration() }
                    }
                } else {
                    Text("Not calibrated. The noise floor adapts automatically.")
                        .foregroundStyle(.secondary)
                }
                Button(monitor.calibration == nil ? "Calibrate Microphone" : "Recalibrate") {
                    isShowingCalibration = true
                }
            } header: {
                Text("Calibration")
            }

            Section("Engine") {
                LabeledContent("Sample rate", value: sampleRateText)
                LabeledContent("Frame / hop", value: frameText)
                LabeledContent("I/O buffer", value: ioBufferText)
                LabeledContent("Input", value: monitor.route?.inputName ?? "—")
                LabeledContent("Output", value: monitor.route?.outputName ?? "—")
                LabeledContent("DSP time per frame", value: processingText)
                LabeledContent("DSP load", value: loadText)
                LabeledContent("Dropped samples", value: "\(monitor.droppedSampleCount)")
            }

            SplitterDebugSection()
        }
        .monospacedDigit()
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingCalibration) {
            MicCalibrationView(monitor: monitor)
        }
    }

    private var frame: VoiceFrame? { monitor.latestFrame }
    private var formants: FormantMeasurement? { monitor.latestFormants }
    private var weightMeasurement: WeightMeasurement? { monitor.latestWeight }
    private var phrase: PhraseIntonation? { monitor.intonation?.phrase }
    private var quality: VoiceQualityStatus? { monitor.voiceQuality }

    private var referenceSource: String {
        guard let quality else { return "—" }
        if let assessment = quality.assessment {
            return assessment.usesStoredNorms ? "Past sessions" : "Start of this session"
        }
        return quality.isLearning ? "Still learning" : "—"
    }

    private var slipText: String {
        let slips = monitor.activeSlips
        if slips.isEmpty { return "None" }
        return slips.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(2))))%"
    }

    private func summaryText(_ summary: VoiceQualitySummary?) -> String {
        guard let summary else { return "—" }
        let jitter = summary.jitterPercent.map { "J \($0.formatted(.number.precision(.fractionLength(2))))%" } ?? "J —"
        let shimmer = summary.shimmerPercent.map { "S \($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "S —"
        let hnr = summary.harmonicsToNoiseDb.map { "H \($0.roundedInt) dB" } ?? "H —"
        return "\(jitter) · \(shimmer) · \(hnr)"
    }

    private var referenceText: String {
        let reference = monitor.resonanceMode.defaultReference
        return "\(monitor.resonanceMode.shortTitle): F2 \(Int(reference.baselineF2))→\(Int(reference.targetF2))"
    }

    private func formantText(_ formant: Formant?) -> String {
        guard let formant else { return "—" }
        return "\(formant.frequency.roundedInt) Hz (\(formant.bandwidth.roundedInt))"
    }

    private func decibelText(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit)"
    }

    private func score(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.roundedInt) / 100"
    }

    private var noteDescription: String {
        guard let frequency = frame?.displayFrequency,
              let name = PitchMath.noteName(for: frequency),
              let cents = PitchMath.centsFromNearestNote(for: frequency)
        else { return "—" }
        let sign = cents >= 0 ? "+" : "−"
        return "\(name) \(sign)\(abs(cents).roundedInt)¢"
    }

    private var sampleRateText: String {
        guard let rate = monitor.captureFormat?.sampleRate else { return "—" }
        return "\(rate.formatted(.number.precision(.fractionLength(0)))) Hz"
    }

    private var frameText: String {
        guard let configuration = monitor.analysisConfiguration else { return "—" }
        let hopMilliseconds = configuration.hopDuration * 1000
        return "\(configuration.frameSize) / \(configuration.hopSize) (\(hopMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms)"
    }

    private var ioBufferText: String {
        guard let duration = monitor.captureFormat?.ioBufferDuration else { return "—" }
        return "\((duration * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private var processingText: String {
        guard monitor.averageProcessingTime > 0 else { return "—" }
        return "\((monitor.averageProcessingTime * 1000).formatted(.number.precision(.fractionLength(3)))) ms"
    }

    private var loadText: String {
        guard monitor.averageProcessingTime > 0,
              let hop = monitor.analysisConfiguration?.hopDuration, hop > 0
        else { return "—" }
        let percent = monitor.averageProcessingTime / hop * 100
        return "\(percent.formatted(.number.precision(.fractionLength(1))))%"
    }

    private func hertz(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(decimals)))) Hz"
    }

    private func number(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    private func decibels(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) dBFS"
    }
}

private struct DebugControls: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        HStack {
            if monitor.status.isRunning {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await monitor.pause() }
                }
            } else {
                Button("Listen", systemImage: "mic.fill") {
                    Task { await monitor.start() }
                }
                .disabled(monitor.status == .starting)
            }
            Spacer()
            Button("Clear Graph", systemImage: "arrow.counterclockwise") {
                monitor.clearLiveReadings()
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Horizontal level bar from −90 to 0 dBFS with noise-floor and gate markers.
private struct LevelMeter: View {
    let levelDb: Double
    let noiseFloorDb: Double
    let gateDb: Double

    private static let range = -90.0...0.0

    var body: some View {
        let isAboveGate = levelDb >= gateDb
        let barColor = isAboveGate ? Theme.targetZone : Color.secondary
        let level = Self.fraction(levelDb)
        let floor = Self.fraction(noiseFloorDb)
        let gate = Self.fraction(gateDb)

        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
            context.fill(track, with: .color(.secondary.opacity(0.15)))

            let filled = CGRect(x: 0, y: 0, width: size.width * level, height: size.height)
            context.fill(Path(roundedRect: filled, cornerRadius: 6), with: .color(barColor))

            var floorMarker = Path()
            floorMarker.move(to: CGPoint(x: size.width * floor, y: 0))
            floorMarker.addLine(to: CGPoint(x: size.width * floor, y: size.height))
            context.stroke(floorMarker, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))

            var gateMarker = Path()
            gateMarker.move(to: CGPoint(x: size.width * gate, y: 0))
            gateMarker.addLine(to: CGPoint(x: size.width * gate, y: size.height))
            context.stroke(gateMarker, with: .color(.primary), lineWidth: 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Input level meter")
        .accessibilityValue(isAboveGate ? "Above the voice gate" : "Below the voice gate")
    }

    private static func fraction(_ decibels: Double) -> CGFloat {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// Vocal splitter timing per chunk and memory (SPEC section 23.6).
private struct SplitterDebugSection: View {
    @State private var availableMemory = os_proc_available_memory()

    var body: some View {
        Section {
            LabeledContent("Memory available to Chirp", value: StorageFormat.text(Int64(availableMemory)))
            if let run = SeparationDiagnostics.lastRun {
                LabeledContent("Last split engine", value: run.engine.title)
                if let factor = run.averageRealTimeFactor {
                    LabeledContent("Speed", value: "\((factor * 100).roundedInt)% of real time")
                }
                if let memory = run.availableMemoryBytes {
                    LabeledContent("Memory free after split", value: StorageFormat.text(Int64(memory)))
                }
                ForEach(run.chunks, id: \.index) { chunk in
                    LabeledContent("Chunk \(chunk.index + 1)", value: "\((chunk.processingSeconds * 1000).roundedInt) ms for \(chunk.audioSeconds.roundedInt) s")
                }
            } else {
                Text("Split a song in More › Tools › Vocal Splitter to see timing here.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Vocal splitter")
        } footer: {
            Text("Processing time per chunk (10 s of audio each, 1 s overlap). Below 100 % of real time means faster than the song plays.")
        }
        .task {
            while !Task.isCancelled {
                availableMemory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
