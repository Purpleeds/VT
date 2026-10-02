import Foundation
import SwiftUI

/// Raw analysis values for tuning on a real device.
struct DebugView: View {
    @Environment(LivePitchMonitor.self) private var monitor

    var body: some View {
        List {
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
                Text("Frames quieter than the voice gate (noise floor + margin) are ignored. Mic calibration in a later stage will replace the adaptive noise floor.")
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
        }
        .monospacedDigit()
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var frame: PitchFrame? { monitor.latestFrame }

    private var noteDescription: String {
        guard let frequency = frame?.displayFrequency,
              let name = PitchMath.noteName(for: frequency),
              let cents = PitchMath.centsFromNearestNote(for: frequency)
        else { return "—" }
        let sign = cents >= 0 ? "+" : "−"
        return "\(name) \(sign)\(Int(abs(cents).rounded()))¢"
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
    @Environment(LivePitchMonitor.self) private var monitor

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
            Button("Reset", systemImage: "arrow.counterclockwise") {
                monitor.resetSession()
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
