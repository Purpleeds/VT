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
    var targetZone: PitchTargetZone = .feminine
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
    /// The background DSP task and the main-actor task that receives its results.
    @ObservationIgnored private var analysisTasks: (producer: Task<Void, Never>, consumer: Task<Void, Never>)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resumesAfterInterruption = false
    private let capture: AudioCaptureService

    private static let resonanceModeKey = "resonanceMode"

    init(capture: AudioCaptureService = AudioCaptureService()) {
        self.capture = capture
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
        publishReadouts(now: Date())
    }

    /// Stops listening and returns to the idle state (used after calibration
    /// when the user wasn't listening before).
    func stop() async {
        guard status != .idle else { return }
        status = .idle
        await endAnalysis()
        await capture.stop()
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
        historyRevision += 1
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
        let countsTowardSession = !isCalibrating

        for frame in frames {
            history.append(PitchGraphPoint(frame: frame))
            if countsTowardSession {
                liveStats.pitch.add(frame, target: targetZone)
            }
            liveProcessingTime = liveProcessingTime == 0
                ? frame.processingDuration
                : liveProcessingTime * 0.95 + frame.processingDuration * 0.05
            if frame.status == .voiced {
                lastVoicedFrame = frame
            }

            if let formants = frame.formants {
                resonanceMeter.add(formants, at: frame.time)
                newestFormants = formants
                if countsTowardSession {
                    liveStats.resonance.add(resonanceMeter.score(for: formants))
                }
            }
            if let measurement = frame.weight {
                weightMeter.add(measurement, at: frame.time)
                newestWeight = measurement
                if countsTowardSession {
                    liveStats.weight.add(weightMeter.score(for: measurement))
                }
            }
            if let phrase = frame.completedPhrase {
                let score = intonationMeter.add(phrase)
                if countsTowardSession {
                    liveStats.intonation.add(score)
                }
            }

            for listener in frameListeners.values {
                listener(frame)
            }
        }
        newestFrame = newest

        let now = Date()
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
