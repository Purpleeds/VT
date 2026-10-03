import AVFoundation
import Foundation
import Observation

/// Everything a game needs to know about the track to play.
nonisolated struct PitchTrackGameSetup: Sendable {
    let trackID: UUID
    let title: String
    let content: PitchTrackContent
    let settings: TrackSettings
    let sources: TrackAudioSources
}

/// Runs one Pitch Track game (SPEC section 22.2): countdown, scrolling bars
/// in step with the audio, live scoring from the microphone, pause, loops.
@MainActor
@Observable
final class PitchTrackGameModel {
    nonisolated enum Phase: Equatable, Sendable {
        case ready
        case preparing
        case countdown
        case playing
        case paused
        case finished
    }

    nonisolated static let countdownSeconds = 3.0
    /// Seconds of track shown across the screen.
    nonisolated static let visibleSeconds = 5.0
    /// The "now" line sits this far from the left (SPEC: about 25 %).
    nonisolated static let nowFraction = 0.25
    nonisolated static let perfectHapticKey = "pitchTrack.perfectHaptic"

    let setup: PitchTrackGameSetup
    /// Bars transposed and limited to the play range.
    let bars: [TrackBar]
    let range: ClosedRange<Double>
    /// Semitones shown on the pitch axis.
    let pitchWindow: ClosedRange<Double>
    let monitor: LiveVoiceMonitor
    let isSimulated: Bool

    private(set) var phase = Phase.ready
    private(set) var combo = 0
    private(set) var feedback: LiveBarFeedback?
    private(set) var result: TrackScoreResult?
    /// Results of finished loop passes.
    private(set) var passResults: [TrackScoreResult] = []
    private(set) var audioMessage: String?
    private(set) var listeningMessage: String?
    /// Bars finished so far (drives the haptic and VoiceOver updates).
    private(set) var finishedBarCount = 0

    @ObservationIgnored private(set) var clock: TrackClock?
    @ObservationIgnored private var scorer: PitchTrackScorer
    @ObservationIgnored private var aligner = FrameTimeAligner()
    @ObservationIgnored private var trail: [TrackContourPoint] = []
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let audio = TrackAudioPlayer()
    @ObservationIgnored private var latencyOffset = 0.0
    @ObservationIgnored private var fixedDelay = 0.0
    @ObservationIgnored private var sampleInterval: Double
    @ObservationIgnored private var currentPass = 0
    @ObservationIgnored private var nextSimulatedTime: Double?
    @ObservationIgnored private var lastPauseHost: Double?

    init(setup: PitchTrackGameSetup, monitor: LiveVoiceMonitor, simulated: Bool) {
        self.setup = setup
        self.monitor = monitor
        isSimulated = simulated
        let range = setup.settings.playRange(trackDuration: setup.content.duration)
        self.range = range
        let bars = setup.content.playableBars(transpose: setup.settings.transpose, range: range)
        self.bars = bars
        pitchWindow = Self.window(for: bars)
        let hop = monitor.analysisConfiguration?.hopDuration ?? AnalysisConfiguration().hopDuration
        sampleInterval = hop * setup.settings.speed
        scorer = PitchTrackScorer(
            bars: bars,
            difficulty: setup.settings.difficulty,
            scoresResonanceAndWeight: setup.settings.scoresResonanceAndWeight,
            sampleInterval: hop * setup.settings.speed
        )
    }

    /// The pitch axis: the bars' range plus two semitones, at least an octave.
    nonisolated static func window(for bars: [TrackBar]) -> ClosedRange<Double> {
        guard let span = TrackRange.span(of: bars) else { return 55...67 }
        let low = (span.lowerBound - 2).rounded(.down)
        let high = (span.upperBound + 2).rounded(.up)
        let middle = (low + high) / 2
        let half = max((high - low) / 2, 6)
        return (middle - half)...(middle + half)
    }

    nonisolated static var perfectHapticEnabled: Bool {
        (UserDefaults.standard.object(forKey: perfectHapticKey) as? Bool) ?? true
    }

    var loops: Bool { setup.settings.loop != nil }
    var isRunning: Bool { phase == .countdown || phase == .playing }

    // MARK: Reading the state (for drawing)

    /// Track time now (before the start during the countdown).
    func trackTime(atHost host: Double = HostClock.now()) -> Double {
        clock?.trackTime(atHost: host) ?? range.lowerBound - Self.countdownSeconds * setup.settings.speed
    }

    /// Seconds left in the countdown (0 once playing).
    func countdownRemaining(atHost host: Double = HostClock.now()) -> Double {
        guard let clock else { return 0 }
        return max(0, clock.startHost - (clock.pausedAt ?? host))
    }

    /// The voice's recent pitch, newest last (track time, semitones).
    var recentTrail: [TrackContourPoint] { trail }

    func fill(forBar position: Int) -> Double {
        scorer.fill(forBar: position)
    }

    func score(forBar position: Int) -> BarScore? {
        scorer.score(forBar: position)
    }

    // MARK: Controls

    /// Prepares the sound, then counts down and starts.
    func start() async {
        guard phase == .ready || phase == .finished else { return }
        resetScoring()
        phase = .preparing
        audioMessage = nil
        listeningMessage = nil

        if !isSimulated {
            if !monitor.status.isRunning {
                await monitor.start()
            }
            guard monitor.status.isRunning else {
                listeningMessage = "Chirp needs the microphone to follow your voice. Check microphone access in Settings."
                phase = .ready
                return
            }
            monitor.suppressesSlipAlerts = true
            listenerID = monitor.addFrameListener { [weak self] frame in
                self?.handle(frame)
            }
        }

        // Load the sound off the main thread.
        let mode = setup.settings.audioMode
        let sources = setup.sources
        let bars = self.bars
        let range = self.range
        let loaded = await Task.detached(priority: .userInitiated) {
            try? TrackAudioLoader.load(mode: mode, sources: sources, transposedBars: bars, range: range)
        }.value
        guard phase == .preparing else { return }
        if mode.makesSound, loaded == nil {
            audioMessage = "The track’s sound isn’t available, so it plays silently."
        }
        let shift = mode == .guideTones ? 0 : setup.settings.transpose
        audio.prepare(loaded?.audio, sampleRate: loaded?.sampleRate ?? GuideToneRenderer.sampleRate, pitchShift: shift, speed: setup.settings.speed)

        // Latency: half a frame, the pitch filter and the input hardware are
        // fixed; the user's own lateness comes from Settings or the route.
        let session = AVAudioSession.sharedInstance()
        if let configuration = monitor.analysisConfiguration {
            // Clear Mic delays the analyzed audio by half an FFT frame.
            fixedDelay = configuration.frameDuration / 2 + 2 * configuration.hopDuration + session.inputLatency + session.ioBufferDuration
                + monitor.analysisLatency
        }
        let automatic = PitchTrackLatency.automaticSeconds(outputLatency: session.outputLatency, playsSound: audio.hasSound)
        latencyOffset = isSimulated ? 0 : PitchTrackLatency.load().offsetSeconds(automatic: automatic)

        let startHost = HostClock.now() + Self.countdownSeconds
        clock = TrackClock(range: range, speed: setup.settings.speed, loops: loops, startHost: startHost)
        if audio.hasSound, !audio.start(atHost: startHost, loops: loops) {
            audioMessage = audio.errorMessage
        }
        nextSimulatedTime = isSimulated ? range.lowerBound : nil
        phase = .countdown
        startTicker()
    }

    func togglePause() {
        guard var clock else { return }
        let now = HostClock.now()
        switch phase {
        case .playing, .countdown:
            clock.pause(atHost: now)
            self.clock = clock
            audio.pause()
            lastPauseHost = now
            phase = .paused
        case .paused:
            let resumeHost = now + 0.05
            clock.resume(atHost: resumeHost)
            self.clock = clock
            audio.resume(atHost: resumeHost)
            // Arrival delays measured before the pause still apply.
            phase = clock.elapsedTrackTime(atHost: resumeHost) > 0 ? .playing : .countdown
        case .ready, .preparing, .finished:
            break
        }
    }

    /// Ends the game now and shows the result for what was played.
    func finishEarly() {
        guard phase == .playing || phase == .paused || phase == .countdown else { return }
        let time = clock.map { $0.trackTime(atHost: HostClock.now()) } ?? range.lowerBound
        finish(through: loops ? .infinity : time)
    }

    /// Stops sound, listening hooks and timers (the screen is closing).
    func tearDown() {
        ticker?.cancel()
        ticker = nil
        audio.shutDown()
        if let listenerID {
            monitor.removeFrameListener(listenerID)
            self.listenerID = nil
        }
        monitor.suppressesSlipAlerts = false
        if phase != .finished {
            phase = .ready
        }
    }

    // MARK: Internals

    private func resetScoring() {
        scorer = PitchTrackScorer(
            bars: bars,
            difficulty: setup.settings.difficulty,
            scoresResonanceAndWeight: setup.settings.scoresResonanceAndWeight,
            sampleInterval: sampleInterval
        )
        aligner = FrameTimeAligner()
        trail = []
        combo = 0
        feedback = nil
        result = nil
        passResults = []
        currentPass = 0
        finishedBarCount = 0
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
                guard let self else { return }
                self.tick()
                if self.phase == .finished || self.phase == .ready {
                    return
                }
            }
        }
    }

    private func tick() {
        guard let clock else { return }
        let now = HostClock.now()
        if phase == .countdown, clock.elapsedTrackTime(atHost: now) > 0 {
            phase = .playing
        }
        guard phase == .playing else { return }
        if isSimulated {
            simulateVoice(until: clock.trackTime(atHost: now))
        }

        // Score up to where the voice has certainly arrived.
        let scoringHost = now - latencyOffset - fixedDelay - 0.1
        let pass = clock.pass(atHost: scoringHost)
        if pass > currentPass {
            finishPass()
            currentPass = pass
        }
        let scoringTime = clock.trackTime(atHost: scoringHost)
        let finishedBars = scorer.advance(to: scoringTime)
        if !finishedBars.isEmpty {
            finishedBarCount += finishedBars.count
            if !isSimulated, Self.perfectHapticEnabled, finishedBars.contains(where: { $0.pitchAccuracy >= PitchTrackScorer.perfectThreshold }) {
                monitor.tapHaptic()
            }
        }
        if combo != scorer.combo {
            combo = scorer.combo
        }
        if feedback != scorer.latest {
            feedback = scorer.latest
        }
        if !loops, scoringTime >= range.upperBound + PitchTrackScorer.settleTime {
            finish(through: .infinity)
        }
    }

    private func finishPass() {
        passResults.append(scorer.result())
        scorer = PitchTrackScorer(
            bars: bars,
            difficulty: setup.settings.difficulty,
            scoresResonanceAndWeight: setup.settings.scoresResonanceAndWeight,
            sampleInterval: sampleInterval
        )
        nextSimulatedTime = isSimulated ? range.lowerBound : nil
    }

    private func finish(through time: Double) {
        ticker?.cancel()
        ticker = nil
        audio.stop()
        if let listenerID {
            monitor.removeFrameListener(listenerID)
            self.listenerID = nil
        }
        monitor.suppressesSlipAlerts = false
        // Loops keep their best complete pass; otherwise what was played.
        if loops, let best = passResults.max(by: { $0.overall < $1.overall }) {
            result = best
        } else {
            result = scorer.result(through: time)
        }
        phase = .finished
    }

    /// Converts a live frame into a scored sample.
    private func handle(_ frame: VoiceFrame) {
        let arrival = HostClock.now()
        aligner.observe(frameTime: frame.time, arrivalHost: arrival)
        guard phase == .playing, let clock,
              let heardHost = aligner.hostTime(ofFrameTime: frame.time, fixedDelay: fixedDelay)
        else { return }
        let voiceHost = heardHost - latencyOffset
        guard clock.elapsedTrackTime(atHost: voiceHost) > 0, clock.pass(atHost: voiceHost) == currentPass else { return }
        let time = clock.trackTime(atHost: voiceHost)
        let midi = frame.status == .voiced ? frame.filteredFrequency.map(PitchMath.midiNote(for:)) : nil
        let weightReference = monitor.personalReferences.weight
        let sample = TrackVoiceSample(
            time: time,
            midi: midi,
            f2: frame.formants?.f2.frequency,
            f3: frame.formants?.f3?.frequency,
            weightScore: frame.weight.map { weightReference.score(h1MinusH2: $0.effectiveH1MinusH2, spectralTilt: $0.spectralTilt) }
        )
        add(sample)
    }

    private func add(_ sample: TrackVoiceSample) {
        scorer.add(sample)
        if let midi = sample.midi {
            trail.append(TrackContourPoint(time: sample.time, midi: midi))
        }
        // Keep about 1.5 s of trail (and drop it across a loop restart).
        if let newest = trail.last {
            trail.removeAll { $0.time < newest.time - 1.5 || $0.time > newest.time }
        }
    }

    /// Debug (SPEC section 22.9): a perfect voice, one sample per analysis hop.
    private func simulateVoice(until trackTime: Double) {
        guard var next = nextSimulatedTime else { return }
        if loops, trackTime < next - 0.5 {
            // The loop restarted.
            next = range.lowerBound
        }
        while next <= trackTime {
            add(PerfectVoice.sample(at: next, bars: bars))
            next += sampleInterval
        }
        nextSimulatedTime = next
    }
}
