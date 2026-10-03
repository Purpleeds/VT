import Foundation
import Observation

nonisolated enum PauseReason: Sendable, Equatable {
    case user
    case interruption
    case background
    case audioReset
}

nonisolated enum MonitorStatus: Sendable, Equatable {
    case idle
    case starting
    case running
    case paused(PauseReason)
    case permissionDenied
    case failed(String)

    var isRunning: Bool { self == .running }
}

/// Live voice listening shared by the Practice, Debug and calibration screens.
///
/// Data flow:
/// 1. `AudioCaptureService` writes microphone samples into a lock-free ring buffer.
/// 2. A detached background task drains the ring every few milliseconds and
///    runs `VoiceAnalysisPipeline` (pitch, formants, weight, intonation) off
///    the main thread.
/// 3. Batches of `VoiceFrame`s are delivered here on the main actor, where they
///    update the graph history, meters, session statistics and readouts.
///
/// The same background task also hands the raw audio to `AudioTap`, which
/// keeps the last 30 seconds (for "save this as a recording") and feeds the
/// live transcript.
@MainActor
@Observable
final class LiveVoiceMonitor {
    private(set) var status: MonitorStatus = .idle
    /// Most recent analysis frame (refreshed ~8 times a second).
    private(set) var latestFrame: VoiceFrame?
    /// Pitch for the big number. Updated ~8 times a second so it's readable.
    private(set) var readoutFrequency: Double?
    /// False when the readout is showing a recent value but the voice has stopped.
    private(set) var readoutIsLive = false
    private(set) var stats = VoiceSessionStats()
    private(set) var resonance: ResonanceReading?
    private(set) var weight: WeightReading?
    private(set) var intonation: IntonationReading?
    /// Formants of the most recent stable frame (debug screen).
    private(set) var latestFormants: FormantMeasurement?
    /// Weight measurement of the most recent stable frame (debug screen).
    private(set) var latestWeight: WeightMeasurement?
    private(set) var route: AudioRouteInfo?
    private(set) var captureFormat: CaptureFormat?
    private(set) var analysisConfiguration: AnalysisConfiguration?
    /// Sample rate used for formant and weight analysis (after decimation).
    private(set) var spectralSampleRate: Double?
    private(set) var droppedSampleCount = 0
    /// Moving average of DSP time per frame, in seconds.
    private(set) var averageProcessingTime = 0.0
    /// Changes whenever the graph history is cleared, so paused graphs redraw.
    private(set) var historyRevision = 0
    /// User-facing explanation of the last unexpected stop, if any.
    private(set) var notice: String?
    /// The saved mic calibration, if the user has done one.
    private(set) var calibration: MicCalibration?
    /// Channels currently slipped back toward the old voice (for visual alerts).
    private(set) var activeSlips: Set<SlipChannel> = []
    /// Percent of voiced time in the target zone over the last 10 seconds.
    private(set) var recentInTargetPercent: Double?
    /// Jitter, shimmer, HNR and how they compare with the user's normal.
    private(set) var voiceQuality: VoiceQualityStatus?
    /// Showing while the voice sounds clearly rougher than usual.
    private(set) var strainWarning: StrainWarning?
    /// True while the eyes-free practice screen is open.
    private(set) var isEyesFreeActive = false
    /// Identifies the current practice session; `resetSession()` starts a new one.
    private(set) var sessionID = UUID()
    /// When the current session first heard practice audio (nil until then).
    private(set) var sessionStartDate: Date?
    /// The live transcript (when the user turns it on).
    let transcription: TranscriptionService
    /// Clear Mic (SPEC section 24): strength, analysis source, Bluetooth
    /// microphones and the preferred input.
    private(set) var clearMicSettings: ClearMicSettings
    /// Raw input level, peak, background noise and Clear Mic's state, for
    /// Mic Check (refreshed with the other readouts).
    private(set) var micStatus = ClearMicLiveStatus()
    /// A noisy-room hint, at most once per session (SPEC section 24.6).
    private(set) var noiseSuggestion: NoiseSuggestion?
    /// True while Clear Mic's gate hears no voice (meters show "No voice").
    private(set) var isVoiceGated = false
    /// Extra delay of the analyzed audio from Clear Mic (seconds).
    private(set) var analysisLatency = 0.0
    /// When room noise was last sampled for Clear Mic.
    private(set) var noiseSampledAt: Date?
    /// Shared with the analysis thread.
    @ObservationIgnored let clearMic = ClearMicControl()
    /// Called just before listening starts (e.g. to stop recording playback,
    /// which would otherwise be picked up by the microphone).
    @ObservationIgnored var willStartListening: (() -> Void)?
    /// How and when to alert the user.
    var feedbackSettings: FeedbackSettings {
        didSet {
            guard feedbackSettings != oldValue else { return }
            FeedbackSettingsStore.save(feedbackSettings)
            slipDetector.configuration = feedbackSettings.slipConfiguration(target: targetZone)
            activeSlips = slipDetector.activeSlips
        }
    }
    var targetZone: PitchTargetZone = .feminine {
        didSet {
            slipDetector.configuration = feedbackSettings.slipConfiguration(target: targetZone)
        }
    }
    /// Which vowel (or speech) the resonance meter compares against.
    var resonanceMode: ResonanceMode = .speech {
        didSet {
            guard resonanceMode != oldValue else { return }
            resonanceMeter.setMode(resonanceMode, reference: personalReferences.resonance(for: resonanceMode))
            UserDefaults.standard.set(resonanceMode.rawValue, forKey: Self.resonanceModeKey)
            publishReadouts(now: Date())
        }
    }
    /// While true (during mic calibration), frames don't count toward session statistics.
    var isCalibrating = false
    /// While true (Mic Check is open), frames don't count toward session
    /// statistics either. Separate from `isCalibrating`, which takes reset.
    var isCheckingMic = false
    /// While true (Pitch Track games), slip alerts stay quiet: singing below
    /// the target zone is part of the exercise there.
    var suppressesSlipAlerts = false
    /// The user's baseline and targets for resonance, weight and intonation
    /// (from the Day 1 recording and Settings).
    private(set) var personalReferences = PersonalReferences.none

    /// Seconds of pitch shown on the scrolling graph.
    let graphDuration = 10.0

    /// True when a saved calibration matches the microphone in use.
    var isCalibrationInUse: Bool {
        calibration?.applies(to: route) ?? false
    }

    /// False on devices without a Taptic Engine.
    var supportsHaptics: Bool { feedback.supportsHaptics }

    /// Calibration, takes and Mic Check are measured but aren't practice.
    private var isExcludedFromSession: Bool { isCalibrating || isCheckingMic }

    /// Current slip thresholds (debug screen).
    var slipConfiguration: SlipDetectorConfiguration { slipDetector.configuration }

    // Per-frame state lives outside observation; the observed properties above
    // are refreshed ~8 times a second so SwiftUI isn't invalidated 94 times a second.
    // The graph reads `history` directly from its own display-synced timeline.
    @ObservationIgnored private var history = PitchHistory(capacity: 2048)
    @ObservationIgnored private var liveStats = VoiceSessionStats()
    @ObservationIgnored private var resonanceMeter = ResonanceMeter()
    @ObservationIgnored private var weightMeter = WeightMeter()
    @ObservationIgnored private var intonationMeter = IntonationMeter()
    @ObservationIgnored private var liveProcessingTime = 0.0
    @ObservationIgnored private var newestFrame: VoiceFrame?
    @ObservationIgnored private var newestFormants: FormantMeasurement?
    @ObservationIgnored private var newestWeight: WeightMeasurement?
    @ObservationIgnored private var lastVoicedFrame: VoiceFrame?
    @ObservationIgnored private var lastBatchArrival: Date?
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var frameListeners: [UUID: (VoiceFrame) -> Void] = [:]
    @ObservationIgnored private var slipDetector: SlipDetector
    @ObservationIgnored private var recentInTarget = TimedTally(duration: 10)
    @ObservationIgnored private var qualityTracker: VoiceQualityTracker
    @ObservationIgnored private var newestQuality: VoiceQualityMeasurement?
    /// The mic may hear our own chimes and vibrations; frames arriving before
    /// this moment are left out of statistics, meters and slip detection.
    @ObservationIgnored private var feedbackQuietUntil = Date.distantPast
    @ObservationIgnored private var lastSlipAlert = Date.distantPast
    /// Seconds of listening in this session (pauses and calibration excluded).
    @ObservationIgnored private var activeDuration = 0.0
    @ObservationIgnored private var slipAlertCount = 0
    @ObservationIgnored private var strainWarningCount = 0
    /// Per-frame values of the last ~40 s, for the statistics of a saved clip.
    @ObservationIgnored private var frameLog = FrameLog()
    /// Time of the newest frame. Each listening run continues this timeline,
    /// so recent audio, frames and transcript words always line up.
    @ObservationIgnored private var timelineEnd: Double?
    /// The background DSP task and the main-actor task that receives its results.
    @ObservationIgnored private var analysisTasks: (producer: Task<Void, Never>, consumer: Task<Void, Never>)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var noiseTracker = NoiseSuggestionTracker()
    /// When Clear Mic's gate last closed (for the "No voice" delay).
    @ObservationIgnored private var gateClosedSince: Date?
    /// While true (mic calibration), the analysis hears raw audio.
    @ObservationIgnored private var forcesRawAnalysis = false
    private let capture: AudioCaptureService
    private let feedback: FeedbackOutput
    private let audioTap: AudioTap

    private static let resonanceModeKey = "resonanceMode"
    /// Minimum seconds between slip alerts, however often the voice slips.
    private static let minimumAlertInterval = 4.0
    /// Shortest clip worth saving.
    static let minimumClipDuration = 1.0

    init(capture: AudioCaptureService = AudioCaptureService()) {
        let settings = FeedbackSettingsStore.load()
        let tap = AudioTap()
        self.capture = capture
        feedback = FeedbackOutput(capture: capture)
        audioTap = tap
        transcription = TranscriptionService(tap: tap)
        clearMicSettings = ClearMicSettingsStore.load()
        noiseSampledAt = ClearMicProfileStore.load()?.date
        feedbackSettings = settings
        slipDetector = SlipDetector(configuration: settings.slipConfiguration(target: .feminine))
        qualityTracker = VoiceQualityTracker(storedNorms: VoiceQualityNormsStore.load())
        let savedMode = UserDefaults.standard.string(forKey: Self.resonanceModeKey).flatMap(ResonanceMode.init(rawValue:))
        resonanceMode = savedMode ?? .speech
        resonanceMeter = ResonanceMeter(mode: savedMode ?? .speech)
        calibration = MicCalibrationStore.load()

        eventTask = Task { [weak self] in
            await capture.beginObservingSystemEvents()
            let initialRoute = await capture.currentRoute()
            self?.route = initialRoute
            for await event in capture.events {
                await self?.handle(event)
            }
        }
    }

    // MARK: Controls

    /// Starts (or resumes) listening. Asks for microphone permission if needed.
    func start() async {
        switch status {
        case .starting, .running:
            return
        case .idle, .paused, .permissionDenied, .failed:
            break
        }
        status = .starting
        notice = nil
        willStartListening?()

        guard await MicrophonePermission.request() else {
            status = .permissionDenied
            return
        }

        do {
            let format = try await capture.start(options: clearMicSettings.captureOptions)
            guard status == .starting else {
                // Paused (or backgrounded) while the microphone was starting.
                await capture.stop()
                return
            }
            status = .running
            await beginAnalysis(format: format)
        } catch {
            status = .failed(Self.userMessage(for: error))
        }
    }

    /// Stops listening but keeps the graph and statistics.
    func pause(_ reason: PauseReason = .user) async {
        switch status {
        case .running, .starting:
            break
        case .idle, .paused, .permissionDenied, .failed:
            return
        }
        status = .paused(reason)
        await endAnalysis()
        await capture.stop()
        clearSlips()
        publishReadouts(now: Date())
    }

    /// Stops listening and returns to the idle state (used after calibration
    /// when the user wasn't listening before).
    func stop() async {
        guard status != .idle else { return }
        status = .idle
        await endAnalysis()
        await capture.stop()
        clearSlips()
        publishReadouts(now: Date())
    }

    /// Clears the graph, meters and statistics for a fresh session.
    func resetSession() {
        noiseTracker.reset()
        noiseSuggestion = nil
        clearLiveReadings()
        liveStats = VoiceSessionStats()
        stats = liveStats
        recentInTarget.removeAll()
        recentInTargetPercent = nil
        // A new session: "normal" is re-read, so this session's warm-up can
        // update it again.
        qualityTracker = VoiceQualityTracker(storedNorms: VoiceQualityNormsStore.load())
        newestQuality = nil
        voiceQuality = nil
        strainWarning = nil

        sessionID = UUID()
        sessionStartDate = nil
        activeDuration = 0
        slipAlertCount = 0
        strainWarningCount = 0
        frameLog.removeAll()
        audioTap.recentAudio.removeAll()
        transcription.reset()
    }

    /// Clears the graph, meters and readouts but keeps the session's
    /// statistics (used after mic calibration).
    func clearLiveReadings() {
        history.removeAll()
        resonanceMeter.reset()
        weightMeter.reset()
        intonationMeter.reset()
        newestFrame = nil
        newestFormants = nil
        newestWeight = nil
        latestFrame = nil
        latestFormants = nil
        latestWeight = nil
        lastVoicedFrame = nil
        readoutFrequency = nil
        readoutIsLive = false
        resonance = nil
        weight = nil
        intonation = nil
        clearSlips()
        historyRevision += 1
    }

    /// Scores resonance, weight and intonation against the user's own
    /// baseline and targets from now on.
    func applyReferences(_ references: PersonalReferences) {
        guard references != personalReferences else { return }
        personalReferences = references
        resonanceMeter.setReference(references.resonance(for: resonanceMode))
        weightMeter.reference = references.weight
        intonationMeter.reference = references.intonation
        publishReadouts(now: Date())
    }

    // MARK: Session data

    /// The current session's statistics, or nil before any practice audio.
    func sessionSnapshot() -> SessionSnapshot? {
        guard let sessionStartDate else { return nil }
        return SessionSnapshot(
            id: sessionID,
            startDate: sessionStartDate,
            activeDuration: activeDuration,
            frameInterval: frameInterval,
            stats: liveStats,
            voiceQuality: qualityTracker.sessionSummary,
            target: targetZone,
            resonanceMode: resonanceMode,
            slipAlertCount: slipAlertCount,
            strainWarningCount: strainWarningCount
        )
    }

    /// The last stretch of audio (up to `maximumDuration` seconds) with its
    /// statistics and transcript, for "save this as a recording".
    /// Returns nil when less than a second of audio is available.
    func recentClip(maximumDuration: Double = 30) -> RecentClip? {
        guard let audio = audioTap.recentAudio.clip(lastSeconds: maximumDuration),
              audio.duration >= Self.minimumClipDuration
        else { return nil }
        let stats = ClipStats.compute(
            records: frameLog.records,
            from: audio.startTime,
            through: audio.endTime,
            target: targetZone,
            frameInterval: frameInterval,
            intonation: intonationMeter.reference
        )
        let transcript = transcription.text(from: audio.startTime, through: audio.endTime)
        return RecentClip(audio: audio, stats: stats, transcript: transcript)
    }

    /// The last `seconds` of microphone audio (up to 30 s), e.g. a take to save.
    func recentAudio(lastSeconds seconds: Double) -> AudioClip? {
        audioTap.recentAudio.clip(lastSeconds: seconds)
    }

    /// Turns the live transcript on or off (asks for permission the first time).
    func setTranscriptionEnabled(_ enabled: Bool) async {
        guard enabled else {
            transcription.disable()
            return
        }
        guard await transcription.enable() else { return }
        if status == .running, let sampleRate = captureFormat?.sampleRate {
            transcription.startListening(sampleRate: sampleRate)
        }
    }

    /// Seconds between analysis frames.
    private var frameInterval: Double {
        (analysisConfiguration ?? AnalysisConfiguration()).hopDuration
    }

    // MARK: Feedback

    /// Opens eyes-free practice: haptics (and optional chimes) become the
    /// main feedback, including a light tap when the voice is back on target.
    func beginEyesFree() async {
        isEyesFreeActive = true
        if !status.isRunning {
            await start()
        }
        if status.isRunning {
            deliver(.started)
        }
    }

    func endEyesFree() {
        isEyesFreeActive = false
    }

    func dismissStrainWarning() {
        strainWarning = nil
    }

    /// Leaves the next `seconds` of microphone input out of statistics, meters
    /// and slip alerts (e.g. while a reference tone plays from the speaker).
    func excludeFromStatistics(for seconds: Double) {
        feedbackQuietUntil = max(feedbackQuietUntil, Date().addingTimeInterval(seconds))
    }

    /// Plays a cue on the enabled channels so the user can feel/hear it.
    func preview(_ cue: FeedbackCue) {
        deliver(cue)
    }

    /// A light haptic tap only (no sound), e.g. for a perfect Pitch Track
    /// note. The microphone input during the vibration is left out.
    func tapHaptic() {
        let busy = feedback.play(.recovered, haptic: true, sound: false)
        if busy > 0 {
            feedbackQuietUntil = max(feedbackQuietUntil, Date().addingTimeInterval(busy))
        }
    }

    private func deliver(_ cue: FeedbackCue) {
        let useHaptics = isEyesFreeActive || feedbackSettings.hapticAlerts
        var useSound = isEyesFreeActive ? feedbackSettings.eyesFreeTones : feedbackSettings.soundAlerts
        // Discreet Mode: chimes only through headphones.
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            useSound = false
        }
        let busy = feedback.play(cue, haptic: useHaptics, sound: useSound)
        if busy > 0 {
            feedbackQuietUntil = max(feedbackQuietUntil, Date().addingTimeInterval(busy))
        }
    }

    private func handleSlipEvents(_ events: [SlipEvent]) {
        var slipped: Set<SlipChannel> = []
        var didRecover = false
        for event in events {
            switch event {
            case .slipped(let channel): slipped.insert(channel)
            case .recovered: didRecover = true
            }
        }
        let now = Date()
        if !slipped.isEmpty, now.timeIntervalSince(lastSlipAlert) >= Self.minimumAlertInterval {
            lastSlipAlert = now
            slipAlertCount += 1
            deliver(.slip(slipped))
        } else if didRecover, isEyesFreeActive, slipDetector.activeSlips.isEmpty {
            deliver(.recovered)
        }
    }

    private func clearSlips() {
        slipDetector.reset()
        if !activeSlips.isEmpty {
            activeSlips = []
        }
    }

    /// Blends this session's fresh-voice warm-up into the stored norms.
    private func updateNorms(with warmup: VoiceQualitySummary) {
        let stored = VoiceQualityNormsStore.load()
        let updated = stored.map { $0.blended(with: warmup) } ?? VoiceQualityNorms(summary: warmup)
        if let updated {
            VoiceQualityNormsStore.save(updated)
        }
    }

    // MARK: Clear Mic

    /// Saves new Clear Mic settings and applies them: a different capture
    /// setup (System mode, Bluetooth mics, the input) restarts the microphone;
    /// a different analysis source restarts the analysis; a different strength
    /// takes effect at once.
    /// - Parameter persist: False for a temporary change (the System Mode
    ///   Check); the saved settings stay as they were.
    func updateClearMicSettings(_ newSettings: ClearMicSettings, persist: Bool = true) async {
        let old = clearMicSettings
        if persist {
            ClearMicSettingsStore.save(newSettings)
        }
        guard newSettings != old else { return }
        clearMicSettings = newSettings
        guard status.isRunning, let format = captureFormat else { return }
        if newSettings.captureOptions != old.captureOptions {
            await restartCapture()
        } else if newSettings.isEnhancing != old.isEnhancing || newSettings.analyzesEnhancedAudio != old.analyzesEnhancedAudio {
            await restartAnalysisIfRunning()
        } else {
            clearMic.setParameters(Self.clearMicParameters(for: newSettings, format: format))
        }
    }

    func setClearMicStrength(_ strength: ClearMicStrength) async {
        var settings = clearMicSettings
        settings.strength = strength
        await updateClearMicSettings(settings)
    }

    /// Averages the next few seconds into Clear Mic's room-noise profile
    /// (the user stays quiet). Listening must be on.
    func sampleRoomNoise(seconds: Double = 2) {
        clearMic.requestNoiseCapture(seconds: seconds)
    }

    /// Microphones available now (Mic Check's picker).
    func availableInputs() async -> [MicInput] {
        await capture.availableInputs()
    }

    func dismissNoiseSuggestion() {
        noiseSuggestion = nil
    }

    /// Back to Clear Mic's defaults, forgetting the room ("Delete All Data").
    func resetClearMic() async {
        clearMic.clearProfiles()
        ClearMicProfileStore.save(nil)
        noiseSampledAt = nil
        noiseTracker.reset()
        noiseSuggestion = nil
        await updateClearMicSettings(ClearMicSettings())
    }

    /// Mic calibration measures the real room and mic, so it analyzes raw audio.
    func setForcesRawAnalysis(_ forcesRaw: Bool) async {
        guard forcesRawAnalysis != forcesRaw else { return }
        forcesRawAnalysis = forcesRaw
        await restartAnalysisIfRunning()
    }

    /// The processing for these settings on this format (System falls back to
    /// Light when iOS voice processing isn't actually on).
    nonisolated static func clearMicParameters(for settings: ClearMicSettings, format: CaptureFormat) -> ClearMicParameters? {
        switch settings.effectiveStrength {
        case .off: nil
        case .light: .light
        case .strong: .strong
        case .system: format.isVoiceProcessing ? .system : .light
        }
    }

    /// Stops and starts the microphone with the current options, staying in
    /// the running state.
    private func restartCapture() async {
        guard status == .running else { return }
        await endAnalysis()
        await capture.stop()
        do {
            let format = try await capture.start(options: clearMicSettings.captureOptions)
            guard status == .running else {
                await capture.stop()
                return
            }
            await beginAnalysis(format: format)
        } catch {
            status = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: Calibration

    /// Saves a calibration and starts using it right away.
    func applyCalibration(_ newCalibration: MicCalibration) async {
        calibration = newCalibration
        MicCalibrationStore.save(newCalibration)
        await restartAnalysisIfRunning()
    }

    /// Forgets the calibration and goes back to the adaptive noise floor.
    func clearCalibration() async {
        calibration = nil
        MicCalibrationStore.save(nil)
        await restartAnalysisIfRunning()
    }

    /// Calls `listener` on the main actor for every analyzed frame.
    /// - Returns: A token for `removeFrameListener`.
    @discardableResult
    func addFrameListener(_ listener: @escaping (VoiceFrame) -> Void) -> UUID {
        let id = UUID()
        frameListeners[id] = listener
        return id
    }

    func removeFrameListener(_ id: UUID) {
        frameListeners[id] = nil
    }

    // MARK: Graph data

    /// Time (seconds) at the right edge of the graph. Between batches it is
    /// extrapolated from the wall clock so the graph scrolls smoothly.
    func graphEndTime(at date: Date) -> Double {
        guard let latest = history.latestTime else { return graphDuration }
        guard status == .running, let arrival = lastBatchArrival else { return latest }
        let sinceArrival = min(max(date.timeIntervalSince(arrival), 0), 0.08)
        return latest + sinceArrival
    }

    func graphPoints(endingAt endTime: Double) -> [PitchGraphPoint] {
        // A little extra on the left so the line enters smoothly from the edge.
        history.points(from: endTime - graphDuration - 0.1, through: endTime)
    }

    // MARK: Analysis

    /// The noise-floor model for the next analysis run: the calibrated room
    /// level when it matches the current mic, otherwise fully adaptive.
    private var noiseFloorModel: NoiseFloorEstimator {
        if let calibration, calibration.applies(to: route) {
            return .calibrated(floorDb: calibration.noiseFloorDb)
        }
        return NoiseFloorEstimator()
    }

    private func restartAnalysisIfRunning() async {
        guard status == .running, let format = captureFormat else { return }
        await beginAnalysis(format: format)
    }

    private func beginAnalysis(format: CaptureFormat) async {
        await endAnalysis()
        // The user may have paused while the previous analysis was finishing.
        guard status == .running else { return }

        clearSlips()
        let configuration = AnalysisConfiguration(sampleRate: format.sampleRate)
        captureFormat = format
        analysisConfiguration = configuration
        spectralSampleRate = Decimator(inputSampleRate: format.sampleRate).outputSampleRate
        // Continue the timeline after a pause, leaving a small visible gap.
        let startTime = timelineEnd.map { $0 + 0.25 } ?? 0
        let noiseFloor = noiseFloorModel
        let ring = capture.samples
        let tap = audioTap
        tap.begin(sampleRate: format.sampleRate, startTime: startTime)
        transcription.startListening(sampleRate: format.sampleRate)

        // Clear Mic (SPEC section 24.2): the processor always runs (it keeps
        // learning the room); the pipeline hears its output only when
        // enhancing, and raw audio otherwise.
        let control = clearMic
        let parameters = Self.clearMicParameters(for: clearMicSettings, format: format)
        let analyzesEnhanced = parameters != nil && clearMicSettings.analyzesEnhancedAudio && !forcesRawAnalysis
        let inputKind = route?.inputKind
        let fftSize = ClearMicProcessor.fftSize(forSampleRate: format.sampleRate)
        let profile = ClearMicProfileStore.load(sampleRate: format.sampleRate, fftSize: fftSize, inputKind: inputKind)
        let highPass = analyzesEnhanced && (parameters?.highPass ?? false) ? HighPassDesign(sampleRate: format.sampleRate) : nil
        control.setParameters(parameters)
        let latency = analyzesEnhanced ? Double(fftSize / 2) / format.sampleRate : 0
        if analysisLatency != latency {
            analysisLatency = latency
        }
        // Enhanced audio lags the raw audio by the processor's latency.
        // Starting the pipeline's clock that much earlier keeps frame times on
        // the raw audio's timeline, so frames, recordings and transcripts line up.
        let pipelineStartTime = startTime - latency

        let (stream, continuation) = AsyncStream.makeStream(
            of: [VoiceFrame].self,
            bufferingPolicy: .bufferingNewest(128)
        )

        // DSP runs on a background thread, never on the main actor.
        let producer = Task.detached(priority: .userInitiated) {
            let pipeline = VoiceAnalysisPipeline(
                configuration: configuration,
                startTime: pipelineStartTime,
                noiseFloor: noiseFloor,
                inputHighPass: highPass
            )
            let stage = ClearMicStage(
                sampleRate: configuration.sampleRate,
                parameters: parameters,
                analyzesEnhanced: analyzesEnhanced,
                profile: profile,
                inputKind: inputKind,
                control: control,
                hopHint: configuration.hopSize
            )
            ring.discardAll()
            while !Task.isCancelled {
                // Raw audio goes to the recent-audio buffer and transcriber;
                // the pipeline hears enhanced (or raw) audio.
                let frames = stage.drain(ring, pipeline: pipeline, tap: tap, rawStartTime: startTime)
                if !frames.isEmpty {
                    _ = continuation.yield(frames)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            producer.cancel()
        }

        let consumer = Task { [weak self] in
            for await frames in stream {
                self?.ingest(frames)
            }
        }
        analysisTasks = (producer, consumer)
    }

    private func endAnalysis() async {
        transcription.stopListening()
        guard let tasks = analysisTasks else { return }
        analysisTasks = nil
        tasks.producer.cancel()
        tasks.consumer.cancel()
        // Wait for the producer to finish so two tasks never read the ring
        // buffer at once (it supports exactly one reader).
        await tasks.producer.value
        await tasks.consumer.value
        // Keep what Clear Mic learned about the room for next time.
        if let learned = clearMic.latestProfile {
            ClearMicProfileStore.save(learned)
        }
    }

    private func ingest(_ frames: [VoiceFrame]) {
        guard let newest = frames.last else { return }
        let now = Date()
        // Frames that may contain our own chime or vibration are skipped.
        let isHearingFeedback = now < feedbackQuietUntil
        let isPractice = !isExcludedFromSession && !isHearingFeedback
        let watchesSlips = isPractice && status == .running && !suppressesSlipAlerts
        let interval = frameInterval
        if !isExcludedFromSession, sessionStartDate == nil {
            sessionStartDate = now
        }

        for frame in frames {
            history.append(PitchGraphPoint(frame: frame))
            liveProcessingTime = liveProcessingTime == 0
                ? frame.processingDuration
                : liveProcessingTime * 0.95 + frame.processingDuration * 0.05
            if frame.status == .voiced {
                lastVoicedFrame = frame
            }
            if !isExcludedFromSession {
                // Practice time includes moments when an alert was playing.
                activeDuration += interval
            }

            if isPractice {
                liveStats.pitch.add(frame, target: targetZone)
                if frame.status == .voiced, let frequency = frame.filteredFrequency {
                    recentInTarget.add(targetZone.contains(frequency), at: frame.time)
                }
            }

            var rollingResonance: Double?
            var frameResonance: Double?
            var frameWeight: Double?
            if !isHearingFeedback, let formants = frame.formants {
                resonanceMeter.add(formants, at: frame.time)
                newestFormants = formants
                rollingResonance = resonanceMeter.reading(now: frame.time)?.score
                if isPractice {
                    let score = resonanceMeter.score(for: formants)
                    frameResonance = score
                    liveStats.resonance.add(score)
                    if let rollingResonance {
                        liveStats.brightResonance.add(MeterZone(score: rollingResonance) == .high)
                    }
                }
            }
            if !isHearingFeedback, let measurement = frame.weight {
                weightMeter.add(measurement, at: frame.time)
                newestWeight = measurement
                if isPractice {
                    let score = weightMeter.score(for: measurement)
                    frameWeight = score
                    liveStats.weight.add(score)
                }
            }
            if isPractice {
                frameLog.append(FrameRecord(
                    time: frame.time,
                    pitch: frame.status == .voiced ? frame.filteredFrequency : nil,
                    resonanceScore: frameResonance,
                    weightScore: frameWeight
                ))
            }
            if let phrase = frame.completedPhrase {
                let score = intonationMeter.add(phrase)
                if isPractice {
                    liveStats.intonation.add(score)
                }
            }
            if isPractice, let quality = frame.voiceQuality {
                newestQuality = quality
                if let warmup = qualityTracker.add(quality, at: frame.time) {
                    updateNorms(with: warmup)
                }
            }

            if watchesSlips {
                let events = slipDetector.process(
                    time: frame.time,
                    frequency: frame.status == .voiced ? frame.filteredFrequency : nil,
                    resonanceScore: rollingResonance
                )
                if !events.isEmpty {
                    handleSlipEvents(events)
                }
            }

            for listener in frameListeners.values {
                listener(frame)
            }
        }
        newestFrame = newest
        timelineEnd = newest.time

        // Slips can also clear silently (e.g. after a pause), so sync every batch.
        let slips = slipDetector.activeSlips
        if slips != activeSlips {
            activeSlips = slips
        }

        lastBatchArrival = now
        if now.timeIntervalSince(lastPublish) >= 0.12 {
            publishReadouts(now: now)
        }
    }

    /// Copies the per-frame state into the observed properties.
    private func publishReadouts(now: Date) {
        lastPublish = now
        if stats != liveStats {
            stats = liveStats
        }
        if latestFrame != newestFrame {
            latestFrame = newestFrame
        }
        if latestFormants != newestFormants {
            latestFormants = newestFormants
        }
        if latestWeight != newestWeight {
            latestWeight = newestWeight
        }
        if averageProcessingTime != liveProcessingTime {
            averageProcessingTime = liveProcessingTime
        }
        let dropped = capture.samples.droppedSampleCount
        if dropped != droppedSampleCount {
            droppedSampleCount = dropped
        }
        publishClearMic(now: now)

        // Meters are judged against audio time, so they go stale in silence
        // but keep their last value while paused.
        let audioNow = newestFrame?.time ?? 0
        let newResonance = resonanceMeter.reading(now: audioNow)
        if resonance != newResonance {
            resonance = newResonance
        }
        let newWeight = weightMeter.reading(now: audioNow)
        if weight != newWeight {
            weight = newWeight
        }
        let newIntonation = intonationMeter.reading(now: audioNow)
        if intonation != newIntonation {
            intonation = newIntonation
        }
        let recentPercent = recentInTarget.fraction.map { $0 * 100 }
        if recentInTargetPercent != recentPercent {
            recentInTargetPercent = recentPercent
        }

        // Voice quality: compare the last 20 s with the user's normal.
        let evaluation = qualityTracker.evaluate(now: audioNow)
        let quality = VoiceQualityStatus(
            session: qualityTracker.sessionSummary,
            assessment: evaluation.assessment,
            isLearning: qualityTracker.isLearning,
            latest: newestQuality
        )
        if voiceQuality != quality {
            voiceQuality = quality
        }
        if evaluation.shouldWarn, feedbackSettings.strainWarnings, !isExcludedFromSession,
           let assessment = evaluation.assessment {
            strainWarning = StrainWarning(roughnessRatio: assessment.roughnessRatio, date: now)
            strainWarningCount += 1
            deliver(.strain)
        }

        // Keep showing the last pitch (dimmed) through short pauses between
        // words, and clear it after two seconds of silence.
        var newFrequency: Double?
        var newIsLive = false
        if let newest = newestFrame, let voiced = lastVoicedFrame, let frequency = voiced.displayFrequency {
            let silence = newest.time - voiced.time
            if silence <= 2 {
                newFrequency = frequency
                newIsLive = status == .running && silence < 0.25
            }
        }
        // Only touch observed properties when they change, so views that
        // read them don't redraw for nothing.
        if readoutFrequency != newFrequency {
            readoutFrequency = newFrequency
        }
        if readoutIsLive != newIsLive {
            readoutIsLive = newIsLive
        }
    }

    /// Seconds the gate stays shut before the meters say "No voice".
    private static let noVoiceDelay = 0.4

    /// Clear Mic's status, the "No voice" state, sampled noise profiles and
    /// the noisy-room suggestion.
    private func publishClearMic(now: Date) {
        let mic = clearMic.status
        if micStatus != mic {
            micStatus = mic
        }
        // "No voice" only after the gate has stayed shut for a moment, so
        // the meters don't flicker between words.
        let isShut = status == .running && mic.isEnhancing && !mic.isGateOpen
        if isShut {
            gateClosedSince = gateClosedSince ?? now
        } else {
            gateClosedSince = nil
        }
        let gated = gateClosedSince.map { now.timeIntervalSince($0) >= Self.noVoiceDelay } ?? false
        if isVoiceGated != gated {
            isVoiceGated = gated
        }
        if let captured = clearMic.takeCapturedProfile() {
            ClearMicProfileStore.save(captured)
            noiseSampledAt = captured.date
        }
        // Only free practice counts (Pitch Track plays music on purpose);
        // anything else restarts the wait.
        let watchesNoise = status == .running && !isExcludedFromSession && !suppressesSlipAlerts && noiseSuggestion == nil
        if let suggestion = noiseTracker.update(
            noiseFloorDb: watchesNoise ? mic.noiseFloorDb : nil,
            strength: clearMicSettings.effectiveStrength,
            time: now.timeIntervalSinceReferenceDate
        ) {
            noiseSuggestion = suggestion
        }
    }

    // MARK: System events

    private func handle(_ event: CaptureEvent) async {
        switch event {
        case .routeChanged(let info):
            guard route != info else { return }
            let calibrationWasInUse = isCalibrationInUse
            let oldKind = route?.inputKind
            route = info
            if clearMicSettings.allowsBluetoothInput, status == .running, oldKind != nil, oldKind != info.inputKind,
               oldKind == .bluetooth || info.inputKind == .bluetooth {
                // A Bluetooth mic came or went: re-check its high-quality mode
                // (and return to the .measurement mode without it).
                await restartCapture()
            } else if calibrationWasInUse != isCalibrationInUse {
                // A different kind of mic needs a different noise-floor model.
                await restartAnalysisIfRunning()
            }
        case .interruptionBegan:
            guard status == .running else { return }
            resumesAfterInterruption = true
            await pause(.interruption)
        case .interruptionEnded(let shouldResume):
            let resume = resumesAfterInterruption && shouldResume && status == .paused(.interruption)
            resumesAfterInterruption = false
            if resume {
                await start()
            }
        case .restarted(let format):
            guard status == .running else { return }
            await beginAnalysis(format: format)
        case .stopped(let message):
            guard status == .running || status == .starting else { return }
            await pause(.audioReset)
            notice = message
        }
    }

    private static func userMessage(for error: any Error) -> String {
        if let captureError = error as? AudioCaptureError, let description = captureError.errorDescription {
            return description
        }
        return "The microphone couldn’t start. Please try again."
    }
}
