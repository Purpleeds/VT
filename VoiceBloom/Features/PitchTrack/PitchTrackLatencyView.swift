import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Runs the tap-along latency calibration (SPEC section 22.2).
@MainActor
@Observable
final class LatencyCalibrationModel {
    nonisolated enum Phase: Equatable {
        case idle
        case running
        case measured(milliseconds: Double)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var beatsHeard = 0
    @ObservationIgnored private let player = TrackAudioPlayer()
    @ObservationIgnored private var beatTimes: [Double] = []
    @ObservationIgnored private var taps: [Double] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    func start(monitor: LiveVoiceMonitor) async {
        guard phase != .running else { return }
        // The microphone isn't needed, and shouldn't analyze the clicks.
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
        let interval = LatencyCalibration.beatInterval
        let count = LatencyCalibration.beatCount
        let clicks = GuideToneRenderer.clicks(count: count, interval: interval)
        player.prepare(StereoBuffer(mono: clicks), sampleRate: GuideToneRenderer.sampleRate, pitchShift: 0, speed: 1)
        let startHost = HostClock.now() + 0.6
        guard player.start(atHost: startHost, loops: false) else {
            phase = .failed(player.errorMessage ?? "The beat can’t play right now.")
            return
        }
        beatTimes = (0..<count).map { startHost + Double($0) * interval }
        taps = []
        beatsHeard = 0
        phase = .running
        task?.cancel()
        task = Task { [weak self] in
            let end = startHost + Double(count) * interval + 0.4
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let now = HostClock.now()
                let heard = self.beatTimes.filter { $0 <= now }.count
                if heard != self.beatsHeard {
                    self.beatsHeard = heard
                }
                if now >= end {
                    self.finish()
                    return
                }
            }
        }
    }

    /// Called the moment a finger touches the tap pad.
    func tap() {
        guard phase == .running else { return }
        taps.append(HostClock.now())
    }

    func cancel() {
        task?.cancel()
        player.shutDown()
        if phase == .running {
            phase = .idle
        }
    }

    private func finish() {
        player.stop()
        if let offset = LatencyCalibration.offset(beats: beatTimes, taps: taps) {
            phase = .measured(milliseconds: offset * 1000)
        } else {
            phase = .failed("Not enough taps landed near the beats. Tap right as you hear each click, then try again.")
        }
    }
}

/// Settings › Pitch Track timing: the latency offset applied to scoring.
struct PitchTrackLatencyView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var latency = PitchTrackLatency.load()
    @State private var isCustom = PitchTrackLatency.load().customMilliseconds != nil
    @State private var customMilliseconds = PitchTrackLatency.load().customMilliseconds ?? 0
    @State private var calibration = LatencyCalibrationModel()
    @State private var isTouching = false
    @State private var automaticMilliseconds = 0.0
    @State private var outputName = ""

    var body: some View {
        List {
            Section {
                Picker("Offset", selection: $isCustom) {
                    Text("Automatic").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented)
                if isCustom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(customMilliseconds.roundedInt) ms")
                            .font(.headline)
                            .monospacedDigit()
                        Slider(value: $customMilliseconds, in: PitchTrackLatency.range, step: 10) {
                            Text("Latency offset")
                        } minimumValueLabel: {
                            Text("\(PitchTrackLatency.range.lowerBound.roundedInt)")
                                .font(.caption)
                        } maximumValueLabel: {
                            Text("\(PitchTrackLatency.range.upperBound.roundedInt)")
                                .font(.caption)
                        }
                        .accessibilityValue("\(customMilliseconds.roundedInt) milliseconds")
                    }
                } else {
                    LabeledContent("Now", value: "\(automaticMilliseconds.roundedInt) ms")
                }
                if let date = latency.calibratedAt, isCustom {
                    Text("Calibrated \(date.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Latency offset")
            } footer: {
                Text("How late your voice reaches Chirp compared with what you see and hear. Automatic uses the delay your headphones report (\(outputName)). If notes you sing on time score as late, calibrate or raise the offset.")
            }

            Section {
                calibrationContent
            } header: {
                Text("Tap-along calibration")
            } footer: {
                Text("Use the headphones you play with. Bluetooth headphones often add 150–250 ms.")
            }
        }
        .navigationTitle("Timing & Latency")
        .task {
            refreshAutomatic()
        }
        .onChange(of: isCustom) { _, _ in
            save()
        }
        .onChange(of: customMilliseconds) { _, _ in
            save()
        }
        .onChange(of: calibration.phase) { _, phase in
            if case .measured(let milliseconds) = phase {
                customMilliseconds = min(max((milliseconds / 10).rounded() * 10, PitchTrackLatency.range.lowerBound), PitchTrackLatency.range.upperBound)
                isCustom = true
                latency.calibratedAt = Date()
                save()
            }
        }
        .onDisappear {
            calibration.cancel()
        }
    }

    @ViewBuilder
    private var calibrationContent: some View {
        switch calibration.phase {
        case .idle, .measured, .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("You’ll hear \(LatencyCalibration.beatCount) clicks. Tap the pad exactly when you hear each one.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if case .measured(let milliseconds) = calibration.phase {
                    Label("Measured \(milliseconds.roundedInt) ms. Saved as your offset.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.targetZone)
                }
                if case .failed(let message) = calibration.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await calibration.start(monitor: monitor) }
                } label: {
                    Label("Start Calibration", systemImage: "metronome")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        case .running:
            VStack(spacing: 12) {
                Text("Beat \(min(calibration.beatsHeard, LatencyCalibration.beatCount)) of \(LatencyCalibration.beatCount)")
                    .font(.headline)
                    .monospacedDigit()
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isTouching ? Theme.pitchLine.opacity(0.45) : Theme.pitchLine.opacity(0.2))
                    .frame(height: 160)
                    .overlay {
                        Text("Tap here on each click")
                            .font(.title3.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                    // Touch-down, not touch-up, so the tap is timed precisely.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !isTouching {
                                    isTouching = true
                                    calibration.tap()
                                }
                            }
                            .onEnded { _ in
                                isTouching = false
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Tap pad")
                    .accessibilityHint("Double-tap when you hear each click.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        calibration.tap()
                    }
                Button("Cancel") {
                    calibration.cancel()
                }
            }
        }
    }

    private func refreshAutomatic() {
        let session = AVAudioSession.sharedInstance()
        automaticMilliseconds = PitchTrackLatency.automaticSeconds(outputLatency: session.outputLatency, playsSound: true) * 1000
        outputName = session.currentRoute.outputs.first?.portName ?? "the speaker"
    }

    private func save() {
        latency.customMilliseconds = isCustom ? customMilliseconds : nil
        latency.save()
    }
}
