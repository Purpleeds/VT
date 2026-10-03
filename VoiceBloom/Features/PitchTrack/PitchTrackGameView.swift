import Foundation
import SwiftUI
import UIKit

/// The Pitch Track game screen (SPEC section 22.2).
struct PitchTrackGameView: View {
    let setup: PitchTrackGameSetup
    let simulated: Bool
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        PitchTrackGameContent(model: PitchTrackGameModel(setup: setup, monitor: monitor, simulated: simulated))
    }
}

private struct PitchTrackGameContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var model: PitchTrackGameModel
    @State private var headphones = TonePlayer.headphonesConnected
    @State private var isConfirmingEnd = false

    init(model: PitchTrackGameModel) {
        _model = State(initialValue: model)
    }

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .ready, .preparing:
                    readyScreen
                case .countdown, .playing, .paused:
                    gameScreen
                case .finished:
                    if let result = model.result {
                        PitchTrackResultsView(result: result, model: model) {
                            Task { await model.start() }
                        }
                    } else {
                        readyScreen
                    }
                }
            }
            .background { AppBackground() }
            .navigationTitle(model.setup.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.tearDown()
                        dismiss()
                    }
                }
            }
        }
        .tracksHeadphones($headphones)
        .onAppear {
            OrientationLock.allowLandscape(true)
        }
        .onDisappear {
            model.tearDown()
            OrientationLock.allowLandscape(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: model.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .confirmationDialog("End this play-through?", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
            Button("End and See Score") {
                model.finishEarly()
            }
        }
    }

    // MARK: Ready

    private var readyScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.setup.title)
                        .font(.title2.weight(.semibold))
                    Text(readySummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if model.isSimulated {
                    NoticeBanner(
                        title: "Simulated voice",
                        message: "Debug mode: a perfect voice sings along instead of the microphone. The score should be close to 100.",
                        systemImage: "ladybug",
                        tint: Color.secondary
                    )
                }
                if model.setup.settings.audioMode.makesSound, !headphones, !model.isSimulated {
                    NoticeBanner(
                        title: "Headphones recommended",
                        message: "Without headphones the microphone also hears the track, which throws off your score. Connect headphones, or play with the bars only.",
                        systemImage: "headphones"
                    )
                }
                if let message = model.listeningMessage ?? model.audioMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Match the bars as they reach the line: higher bars mean higher pitch. Bars fill in as you hit them.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                if model.phase == .preparing {
                    ProgressView("Getting ready…")
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        Task { await model.start() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    if model.setup.settings.audioMode.makesSound, !headphones, !model.isSimulated {
                        Button {
                            playSilently()
                        } label: {
                            Label("Play Silently Instead", systemImage: "speaker.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
            }
            .padding()
        }
    }

    private var readySummary: String {
        let settings = model.setup.settings
        var parts = [settings.difficulty.detail, "\((settings.speed * 100).roundedInt)% speed", settings.audioMode.title]
        if settings.transpose != 0 {
            parts.append("transposed \(settings.transpose > 0 ? "+" : "−")\(abs(settings.transpose))")
        }
        if settings.loop != nil {
            parts.append("looping")
        }
        return parts.joined(separator: " · ")
    }

    /// SPEC section 22.2: no headphones → offer Silent mode.
    private func playSilently() {
        var settings = model.setup.settings
        settings.audioMode = .silent
        let setup = PitchTrackGameSetup(
            trackID: model.setup.trackID,
            title: model.setup.title,
            content: model.setup.content,
            settings: settings,
            sources: model.setup.sources
        )
        model.tearDown()
        model = PitchTrackGameModel(setup: setup, monitor: monitor, simulated: model.isSimulated)
        Task { await model.start() }
    }

    // MARK: Game

    private var gameScreen: some View {
        Group {
            if isLandscape {
                HStack(spacing: 12) {
                    canvas
                    hud
                        .frame(width: 190)
                }
            } else {
                VStack(spacing: 12) {
                    canvas
                    hud
                }
            }
        }
        .padding(isLandscape ? 8 : 12)
    }

    private var canvas: some View {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !model.isRunning)) { _ in
            let now = HostClock.now()
            PitchTrackCanvas(snapshot: PitchTrackDrawing(model: model, host: now), reduceMotion: reduceMotion)
                .overlay {
                    if model.phase == .countdown {
                        let remaining = model.countdownRemaining(atHost: now)
                        Text("\(max(1, remaining.rounded(.up).roundedInt))")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .padding(28)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel("Starting in \(max(1, remaining.rounded(.up).roundedInt))")
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay {
            if model.phase == .paused {
                VStack(spacing: 12) {
                    Text("Paused")
                        .font(.title2.weight(.semibold))
                    Button {
                        model.togglePause()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    Button("End and See Score") {
                        model.finishEarly()
                    }
                    .buttonStyle(.glass)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pitch track")
        .accessibilityValue(accessibilityStatus)
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Combo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(model.combo)")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer()
                feedbackLabel
            }

            if model.setup.settings.scoresResonanceAndWeight {
                miniMeter("Resonance", value: (monitor.resonance?.isLive ?? false) ? monitor.resonance?.score : nil, tint: Theme.resonanceSeries)
                miniMeter("Weight", value: (monitor.weight?.isLive ?? false) ? monitor.weight?.score : nil, tint: Theme.weightSeries)
            }

            if let message = model.audioMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.phase == .paused ? "Resume" : "Pause", systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    isConfirmingEnd = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var feedbackLabel: some View {
        if let feedback = model.feedback {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: feedback))
                    .foregroundStyle(PitchTrackColors.zone(feedback.zone))
                    .accessibilityHidden(true)
                Text(Self.hint(for: feedback))
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(model.phase == .countdown ? "Get ready" : "Listening…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func miniMeter(_ title: String, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(value.map { "\($0.roundedInt)" } ?? "–")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            MeterBar(fraction: (value ?? 0) / 100, tint: tint)
                .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0.roundedInt) out of 100" } ?? "Not measured yet")
    }

    static func symbol(for feedback: LiveBarFeedback) -> String {
        switch feedback.hintGoesHigher {
        case .some(true): "arrow.up.circle.fill"
        case .some(false): "arrow.down.circle.fill"
        case .none: "checkmark.circle.fill"
        }
    }

    static func hint(for feedback: LiveBarFeedback) -> String {
        switch (feedback.zone, feedback.hintGoesHigher) {
        case (.on, _): "On it"
        case (.close, .some(true)): "Close: a bit higher"
        case (.close, _): "Close: a bit lower"
        case (.off, .some(true)): "Go higher"
        case (.off, _): "Go lower"
        }
    }

    private var accessibilityStatus: String {
        let now = model.trackTime()
        let next = model.bars.first { $0.end >= now }
        var parts: [String] = []
        if let next {
            parts.append("Next note \(PitchMath.spokenNoteName(for: PitchMath.frequency(forMidiNote: next.targetMidi(at: max(now, next.start)))) ?? "")")
        }
        if let feedback = model.feedback {
            parts.append(Self.hint(for: feedback))
        }
        parts.append("Combo \(model.combo)")
        return parts.joined(separator: ". ")
    }
}

/// Zone colors; meaning is always repeated with an arrow or words.
@MainActor
enum PitchTrackColors {
    static func zone(_ zone: BarZone) -> Color {
        switch zone {
        case .on: Color.green
        case .close: Color.yellow
        case .off: Color.red
        }
    }

    static func accuracy(_ value: Double) -> Color {
        if value >= PitchTrackScorer.hitThreshold { return zone(.on) }
        if value >= 30 { return zone(.close) }
        return zone(.off)
    }
}

// MARK: - Drawing

/// Everything the canvas draws for one frame (copied from the model).
nonisolated struct PitchTrackDrawing {
    nonisolated struct BarDrawing {
        let bar: TrackBar
        let fill: Double
        let fillColor: Color?
        let outline: Color
        /// 0 (light) … 1 (heavy): thickness of the inner weight line.
        let heaviness: Double?
    }

    let now: Double
    let window: ClosedRange<Double>
    let bars: [BarDrawing]
    let trail: [TrackContourPoint]
    let dotMidi: Double?
    let dotColor: Color
    let gridColor: Color
    let nowLineColor: Color
    let barColor: Color
    let wordColor: Color

    @MainActor
    init(model: PitchTrackGameModel, host: Double) {
        let now = model.trackTime(atHost: host)
        self.now = now
        window = model.pitchWindow
        let visibleStart = now - PitchTrackGameModel.visibleSeconds * PitchTrackGameModel.nowFraction
        let visibleEnd = now + PitchTrackGameModel.visibleSeconds * (1 - PitchTrackGameModel.nowFraction)
        let liveIndex = model.feedback?.barIndex
        let liveZone = model.feedback?.zone
        bars = model.bars.enumerated().compactMap { position, bar in
            guard bar.end >= visibleStart, bar.start <= visibleEnd else { return nil }
            let fill = model.fill(forBar: position)
            var fillColor: Color?
            if let score = model.score(forBar: position) {
                fillColor = PitchTrackColors.accuracy(score.pitchAccuracy)
            } else if position == liveIndex, let liveZone {
                fillColor = PitchTrackColors.zone(liveZone)
            } else if fill > 0 {
                fillColor = PitchTrackColors.zone(.on)
            }
            let brightness = (bar.resonance?.score ?? 50) / 100
            return BarDrawing(
                bar: bar,
                fill: fill,
                fillColor: fillColor,
                outline: Theme.resonanceSeries.opacity(0.35 + 0.65 * min(max(brightness, 0), 1)),
                heaviness: bar.weightScore.map { 1 - min(max($0, 0), 100) / 100 }
            )
        }
        let recent = model.recentTrail
        trail = recent
        if let newest = recent.last, model.phase == .playing {
            dotMidi = newest.midi
        } else {
            dotMidi = nil
        }
        dotColor = model.feedback.map { PitchTrackColors.zone($0.zone) } ?? Theme.pitchLine
        gridColor = Color.secondary
        nowLineColor = Theme.pitchLine
        barColor = Theme.pitchLine
        wordColor = Color.primary
    }
}

private struct PitchTrackCanvas: View {
    let snapshot: PitchTrackDrawing
    let reduceMotion: Bool

    var body: some View {
        let drawing = snapshot
        let glow = !reduceMotion
        Canvas { context, size in
            let labelWidth: CGFloat = 38
            let plotWidth = max(size.width - labelWidth, 1)
            let pixelsPerSecond = plotWidth / CGFloat(PitchTrackGameModel.visibleSeconds)
            let nowX = labelWidth + plotWidth * CGFloat(PitchTrackGameModel.nowFraction)
            let span = max(drawing.window.upperBound - drawing.window.lowerBound, 1)
            let rowHeight = size.height / CGFloat(span)
            func x(_ time: Double) -> CGFloat { nowX + CGFloat(time - drawing.now) * pixelsPerSecond }
            func y(_ midi: Double) -> CGFloat { size.height * CGFloat((drawing.window.upperBound - midi) / span) }

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.secondary.opacity(0.07)))

            // Semitone grid with note names.
            let labelEvery = rowHeight >= 14 ? 1 : 2
            var note = Int(drawing.window.lowerBound.rounded(.up))
            while Double(note) <= drawing.window.upperBound {
                let lineY = y(Double(note))
                let isC = ((note % 12) + 12) % 12 == 0
                var line = Path()
                line.move(to: CGPoint(x: labelWidth, y: lineY))
                line.addLine(to: CGPoint(x: size.width, y: lineY))
                context.stroke(line, with: .color(drawing.gridColor.opacity(isC ? 0.35 : 0.15)), lineWidth: isC ? 1 : 0.5)
                if note % labelEvery == 0 || isC, let name = PitchMath.noteName(for: PitchMath.frequency(forMidiNote: Double(note))) {
                    context.draw(
                        Text(name).font(.caption2).foregroundStyle(drawing.gridColor),
                        at: CGPoint(x: labelWidth / 2, y: lineY)
                    )
                }
                note += 1
            }

            // Bars.
            let thickness = min(max(rowHeight * 0.8, 6), 28)
            for item in drawing.bars {
                let bar = item.bar
                if bar.isCurved {
                    var path = Path()
                    for (index, point) in bar.contour.enumerated() {
                        let location = CGPoint(x: x(point.time), y: y(point.midi))
                        if index == 0 {
                            path.move(to: location)
                        } else {
                            path.addLine(to: location)
                        }
                    }
                    context.stroke(path, with: .color(item.outline), style: StrokeStyle(lineWidth: thickness + 3, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(drawing.barColor.opacity(0.35)), style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
                    if let fillColor = item.fillColor, item.fill > 0 {
                        context.stroke(
                            path.trimmedPath(from: 0, to: min(item.fill, 1)),
                            with: .color(fillColor),
                            style: StrokeStyle(lineWidth: thickness * 0.7, lineCap: .round, lineJoin: .round)
                        )
                    }
                    if let heaviness = item.heaviness {
                        context.stroke(path, with: .color(Color.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1 + 3 * heaviness, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    let rect = CGRect(x: x(bar.start), y: y(bar.midi) - thickness / 2, width: max(4, x(bar.end) - x(bar.start)), height: thickness)
                    let shape = Path(roundedRect: rect, cornerRadius: min(thickness / 2, 8))
                    context.fill(shape, with: .color(drawing.barColor.opacity(0.3)))
                    if let fillColor = item.fillColor, item.fill > 0 {
                        var filled = context
                        filled.clip(to: shape)
                        filled.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(min(item.fill, 1)), height: rect.height)), with: .color(fillColor))
                    }
                    context.stroke(shape, with: .color(item.outline), lineWidth: 2)
                    if let heaviness = item.heaviness {
                        var inner = Path()
                        inner.move(to: CGPoint(x: rect.minX + 4, y: rect.midY))
                        inner.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.midY))
                        context.stroke(inner, with: .color(Color.white.opacity(0.55)), lineWidth: 1 + 3 * heaviness)
                    }
                }
                if let word = bar.word {
                    let lowest = bar.pitchSpan.lowerBound
                    context.draw(
                        Text(word).font(.caption).foregroundStyle(drawing.wordColor),
                        at: CGPoint(x: x(bar.start), y: y(lowest) + thickness / 2 + 9),
                        anchor: .leading
                    )
                }
            }

            // The "now" line.
            var nowLine = Path()
            nowLine.move(to: CGPoint(x: nowX, y: 0))
            nowLine.addLine(to: CGPoint(x: nowX, y: size.height))
            context.stroke(nowLine, with: .color(drawing.nowLineColor.opacity(0.8)), lineWidth: 2)

            // The voice: a short trail ending in a glowing dot on the line.
            if let newest = drawing.trail.last {
                var trailPath = Path()
                var started = false
                for point in drawing.trail {
                    let location = CGPoint(x: nowX - CGFloat(newest.time - point.time) * pixelsPerSecond, y: y(point.midi))
                    if started {
                        trailPath.addLine(to: location)
                    } else {
                        trailPath.move(to: location)
                        started = true
                    }
                }
                context.stroke(trailPath, with: .color(drawing.dotColor.opacity(0.55)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let midi = drawing.dotMidi {
                let center = CGPoint(x: nowX, y: min(max(y(midi), 6), size.height - 6))
                let dot = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                if glow {
                    var glowing = context
                    glowing.addFilter(.shadow(color: drawing.dotColor.opacity(0.9), radius: 8))
                    glowing.fill(dot, with: .color(drawing.dotColor))
                } else {
                    context.fill(dot, with: .color(drawing.dotColor))
                }
                context.stroke(dot, with: .color(Color.white), lineWidth: 2)
            }
        }
    }
}

// MARK: - Results

/// The score after a play-through (SPEC section 22.4).
struct PitchTrackResultsView: View {
    let result: TrackScoreResult
    let model: PitchTrackGameModel
    let onPlayAgain: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    Text("\(result.overall.roundedInt)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= result.stars ? "star.fill" : "star")
                                .foregroundStyle(Theme.intonationSeries)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(result.stars) of 5 stars")
                    Text(headline)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Breakdown")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            StatTile(title: "Pitch accuracy", value: "\(result.pitchAccuracy.roundedInt)")
                            StatTile(title: "Stability", value: result.stability.map { "\($0.roundedInt)" } ?? "–")
                        }
                        GridRow {
                            StatTile(title: "Timing", value: result.timing.map { "\($0.roundedInt)" } ?? "–")
                            StatTile(title: "Bars hit", value: "\(result.percentBarsHit.roundedInt)%")
                        }
                        if model.setup.settings.scoresResonanceAndWeight {
                            GridRow {
                                StatTile(title: "Resonance match", value: result.resonanceMatch.map { "\($0.roundedInt)" } ?? "–")
                                StatTile(title: "Weight match", value: result.weightMatch.map { "\($0.roundedInt)" } ?? "–")
                            }
                        }
                        GridRow {
                            StatTile(title: "Longest combo", value: "\(result.longestCombo)")
                            StatTile(title: "Comfortable notes", value: comfortableRange)
                        }
                    }
                }
                .cardStyle()

                if !model.passResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Loop passes")
                            .font(.headline)
                        ForEach(Array(model.passResults.enumerated()), id: \.offset) { index, pass in
                            LabeledContent("Pass \(index + 1)", value: "\(pass.overall.roundedInt)")
                        }
                        Text("Your best pass is shown above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .cardStyle()
                }

                Button {
                    onPlayAgain()
                } label: {
                    Label("Play Again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Text("Take a sip of water between rounds, and stop if your throat feels tight or sore.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
    }

    private var headline: String {
        switch result.stars {
        case 5: "Outstanding!"
        case 4: "Great singing!"
        case 3: "Nice work, keep going!"
        case 2: "Good start. Try a slower speed or Easy."
        default: "Every try counts. Try Easy, a slower speed, or transposing."
        }
    }

    private var comfortableRange: String {
        guard let low = result.lowestComfortableMidi, let high = result.highestComfortableMidi else { return "–" }
        return TrackRange.label(low...high)
    }
}
