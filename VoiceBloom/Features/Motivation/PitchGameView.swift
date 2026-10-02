import Foundation
import Observation
import SwiftData
import SwiftUI

/// Runs the balloon game from the live voice.
@MainActor
@Observable
final class PitchGameModel {
    nonisolated enum Phase: Equatable, Sendable {
        case ready
        case playing
        case over(score: Int, isBest: Bool)
    }

    private(set) var engine: PitchGameEngine
    private(set) var phase: Phase = .ready
    let monitor: LiveVoiceMonitor
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wasListening = false
    @ObservationIgnored private var seed: UInt64 = 1

    init(monitor: LiveVoiceMonitor, target: PitchTargetZone, speedFactor: Double) {
        self.monitor = monitor
        engine = PitchGameEngine(target: target, speedFactor: speedFactor)
    }

    func start(target: PitchTargetZone, speedFactor: Double) async {
        seed &+= 1
        engine = PitchGameEngine(target: target, speedFactor: speedFactor, seed: seed)
        wasListening = monitor.status.isRunning
        if !monitor.status.isRunning {
            await monitor.start()
        }
        guard monitor.status.isRunning else { return }
        phase = .playing
        loop?.cancel()
        loop = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                let now = Date()
                let dt = min(now.timeIntervalSince(last), 0.1)
                last = now
                self.tick(dt: dt)
                if case .over = self.phase { return }
            }
        }
    }

    private func tick(dt: Double) {
        guard phase == .playing else { return }
        let pitch = monitor.readoutIsLive ? monitor.readoutFrequency : nil
        let resonance = (monitor.resonance?.isLive ?? false) ? monitor.resonance?.score : nil
        engine.step(dt: dt, pitch: pitch, resonance: resonance)
        if engine.isOver {
            let isBest = PitchGameScores.save(engine.score)
            phase = .over(score: engine.score, isBest: isBest)
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        if phase == .playing {
            phase = .ready
        }
        if !wasListening, monitor.status.isRunning {
            await monitor.pause(.user)
        }
    }
}

/// The balloon game (SPEC section 12): steer with your pitch, bonus points
/// for bright resonance.
struct PitchGameView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        PitchGameContent(monitor: monitor)
    }
}

private struct PitchGameContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var model: PitchGameModel

    init(monitor: LiveVoiceMonitor) {
        _model = State(initialValue: PitchGameModel(monitor: monitor, target: monitor.targetZone, speedFactor: 1))
    }

    private var target: PitchTargetZone { profiles.first?.targetZone ?? model.monitor.targetZone }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("\(model.engine.score)", systemImage: "star.fill")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Score \(model.engine.score)")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<PitchGameEngine.startingLives, id: \.self) { index in
                        Image(systemName: index < model.engine.lives ? "heart.fill" : "heart")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.engine.lives) lives left")
            }

            PitchGameCanvas(engine: model.engine)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Balloon game")
                .accessibilityValue(accessibilityStatus)

            controls

            Text("Speak or hum: higher pitch lifts the balloon, lower lets it sink. The green band is your target. A bright, forward resonance while passing a gap scores a bonus star.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background { AppBackground() }
        .navigationTitle("Balloon Game")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: model.engine.score)
        .sensoryFeedback(.warning, trigger: model.engine.lives)
        .onDisappear {
            Task { await model.stop() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .ready:
            startButton("Start")
        case .playing:
            Button("Stop") {
                Task { await model.stop() }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        case .over(let score, let isBest):
            VStack(spacing: 8) {
                Text(isBest ? "New best: \(score)!" : "Score: \(score)")
                    .font(.title3.weight(.semibold))
                Text("Best \(PitchGameScores.best)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                startButton("Play again")
            }
            .onAppear {
                _ = MotivationCenter.refresh(context: modelContext)
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            Task { await model.start(target: target, speedFactor: reduceMotion ? 0.7 : 1) }
        } label: {
            Label(title, systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var accessibilityStatus: String {
        let height = Int((model.engine.balloonY * 100).rounded())
        let next = model.engine.gates.first { !$0.isResolved }
        let gap = next.map { ", next gap at \(Int(($0.gapCenter * 100).rounded())) percent height" } ?? ""
        return "Balloon at \(height) percent height\(gap). Score \(model.engine.score)."
    }
}

/// Draws the sky, target band, gates and balloon.
private struct PitchGameCanvas: View {
    let engine: PitchGameEngine

    var body: some View {
        let band = engine.targetBand
        let gateColor = Theme.pitchLine
        let bandColor = Theme.targetZone
        let balloonColor = Theme.resonanceSeries
        let balloonY = engine.balloonY
        let gates = engine.gates
        let isHeard = engine.isHeard
        Canvas { context, size in
            func y(_ height: Double) -> CGFloat { size.height * CGFloat(1 - height) }

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.secondary.opacity(0.08)))
            let bandRect = CGRect(x: 0, y: y(band.upperBound), width: size.width, height: y(band.lowerBound) - y(band.upperBound))
            context.fill(Path(bandRect), with: .color(bandColor.opacity(0.18)))

            let gateWidth = size.width * 0.07
            for gate in gates {
                let x = size.width * CGFloat(gate.x) - gateWidth / 2
                let top = y(gate.gapCenter + gate.gapHeight / 2)
                let bottom = y(gate.gapCenter - gate.gapHeight / 2)
                let opacity = gate.isResolved && !gate.wasPassed ? 0.35 : 0.85
                context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: gateWidth, height: max(0, top)), cornerRadius: 6), with: .color(gateColor.opacity(opacity)))
                context.fill(Path(roundedRect: CGRect(x: x, y: bottom, width: gateWidth, height: max(0, size.height - bottom)), cornerRadius: 6), with: .color(gateColor.opacity(opacity)))
            }

            let radius = size.height * CGFloat(PitchGameEngine.balloonRadius)
            let center = CGPoint(x: size.width * CGFloat(PitchGameEngine.balloonX), y: y(balloonY))
            var string = Path()
            string.move(to: CGPoint(x: center.x, y: center.y + radius))
            string.addLine(to: CGPoint(x: center.x - 4, y: center.y + radius * 2.4))
            context.stroke(string, with: .color(.secondary), lineWidth: 1.5)
            let balloon = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius * 1.15, width: radius * 2, height: radius * 2.3))
            context.fill(balloon, with: .color(isHeard ? balloonColor : balloonColor.opacity(0.5)))
        }
    }
}
