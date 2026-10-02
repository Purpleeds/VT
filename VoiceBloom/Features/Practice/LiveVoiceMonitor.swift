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
            resonanceMeter.setMode(resonanceMode)
            UserDefaults.standard.set(resonanceMode.rawValue, forKey: Self.resonanceModeKey)
            publishReadouts(now: Date())
        }
    }
    /// While true (during mic calibration), frames don't count toward session statistics.
    var isCalibrating = false

    /// Seconds of pitch shown on the scrolling graph.
    let graphDuration = 10.0

    /// True when a saved calibration matches the microphone in use.
    var isCalibrationInUse: Bool {
        calibration?.applies(to: route) ?? false
    }

    /// False on devices without a Taptic Engine.
    var supportsHaptics: Bool { feedback.supportsHaptics }

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
    /// The background DSP task and the main-actor task that receives its results.
    @ObservationIgnored private var analysisTasks: (producer: Task<Void, Never>, consumer: Task<Void, Never>)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resumesAfterInterruption = false
    private let capture: AudioCaptureService
    private let feedback: FeedbackOutput

    private static let resonanceModeKey = "resonanceMode"
    /// Minimum seconds between slip alerts, however often the voice slips.
    private static let minimumAlertInterval = 4.0

    init(capture: AudioCaptureService = AudioCaptureService()) {
        let settings = FeedbackSettingsStore.load()
        self.capture = capture
        feedback = FeedbackOutput(capture: capture)
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

        guard await MicrophonePermission.request() else {
            status = .permissionDenied
            return
        }

        do {
            let format = try await capture.start()
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
        history.removeAll()
        liveStats = VoiceSessionStats()
        stats = liveStats
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
        recentInTarget.removeAll()
        recentInTargetPercent = nil
        // A new session: "normal" is re-read, so this session's warm-up can
        // update it again.
        qualityTracker = VoiceQualityTracker(storedNorms: VoiceQualityNormsStore.load())
        newestQuality = nil
        voiceQuality = nil
        strainWarning = nil
        clearSlips()
        historyRevision += 1
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

    /// Plays a cue on the enabled channels so the user can feel/hear it.
    func preview(_ cue: FeedbackCue) {
        deliver(cue)
    }

    private func deliver(_ cue: FeedbackCue) {
        let useHaptics = isEyesFreeActive || feedbackSettings.hapticAlerts
        let useSound = isEyesFreeActive ? feedbackSettings.eyesFreeTones : feedbackSettings.soundAlerts
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
        let startTime = history.latestTime.map { $0 + 0.25 } ?? 0
        let noiseFloor = noiseFloorModel
        let ring = capture.samples

        let (stream, continuation) = AsyncStream.makeStream(
            of: [VoiceFrame].self,
            bufferingPolicy: .bufferingNewest(128)
        )

        // DSP runs on a background thread, never on the main actor.
        let producer = Task.detached(priority: .userInitiated) {
            let pipeline = VoiceAnalysisPipeline(
                configuration: configuration,
                startTime: startTime,
                noiseFloor: noiseFloor
            )
            ring.discardAll()
            while !Task.isCancelled {
                let frames = pipeline.drain(ring)
                if !frames.isEmpty {
                    continuation.yield(frames)
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
        guard let tasks = analysisTasks else { return }
        analysisTasks = nil
        tasks.producer.cancel()
        tasks.consumer.cancel()
        // Wait for the producer to finish so two tasks never read the ring
        // buffer at once (it supports exactly one reader).
        await tasks.producer.value
        await tasks.consumer.value
    }

    private func ingest(_ frames: [VoiceFrame]) {
        guard let newest = frames.last else { return }
        let now = Date()
        // Frames that may contain our own chime or vibration are skipped.
        let isHearingFeedback = now < feedbackQuietUntil
        let isPractice = !isCalibrating && !isHearingFeedback
        let watchesSlips = isPractice && status == .running

        for frame in frames {
            history.append(PitchGraphPoint(frame: frame))
            liveProcessingTime = liveProcessingTime == 0
                ? frame.processingDuration
                : liveProcessingTime * 0.95 + frame.processingDuration * 0.05
            if frame.status == .voiced {
                lastVoicedFrame = frame
            }

            if isPractice {
                liveStats.pitch.add(frame, target: targetZone)
                if frame.status == .voiced, let frequency = frame.filteredFrequency {
                    recentInTarget.add(targetZone.contains(frequency), at: frame.time)
                }
            }

            var rollingResonance: Double?
            if !isHearingFeedback, let formants = frame.formants {
                resonanceMeter.add(formants, at: frame.time)
                newestFormants = formants
                rollingResonance = resonanceMeter.reading(now: frame.time)?.score
                if isPractice {
                    liveStats.resonance.add(resonanceMeter.score(for: formants))
                    if let rollingResonance {
                        liveStats.brightResonance.add(MeterZone(score: rollingResonance) == .high)
                    }
                }
            }
            if !isHearingFeedback, let measurement = frame.weight {
                weightMeter.add(measurement, at: frame.time)
                newestWeight = measurement
                if isPractice {
                    liveStats.weight.add(weightMeter.score(for: measurement))
                }
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
        if evaluation.shouldWarn, feedbackSettings.strainWarnings, !isCalibrating,
           let assessment = evaluation.assessment {
            strainWarning = StrainWarning(roughnessRatio: assessment.roughnessRatio, date: now)
            deliver(.strain)
        }

        guard let newest = newestFrame,
              let voiced = lastVoicedFrame,
              let frequency = voiced.displayFrequency
        else {
            readoutFrequency = nil
            readoutIsLive = false
            return
        }
        // Keep showing the last pitch (dimmed) through short pauses between
        // words, and clear it after two seconds of silence.
        let silence = newest.time - voiced.time
        if silence > 2 {
            readoutFrequency = nil
            readoutIsLive = false
        } else {
            readoutFrequency = frequency
            readoutIsLive = status == .running && silence < 0.25
        }
    }

    // MARK: System events

    private func handle(_ event: CaptureEvent) async {
        switch event {
        case .routeChanged(let info):
            guard route != info else { return }
            let calibrationWasInUse = isCalibrationInUse
            route = info
            // A different kind of mic needs a different noise-floor model.
            if calibrationWasInUse != isCalibrationInUse {
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
