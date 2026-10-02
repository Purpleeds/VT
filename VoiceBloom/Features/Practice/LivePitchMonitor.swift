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

/// Live pitch listening shared by the Practice and Debug screens.
///
/// Data flow:
/// 1. `AudioCaptureService` writes microphone samples into a lock-free ring buffer.
/// 2. A detached background task drains the ring every few milliseconds and
///    runs `LivePitchPipeline` (YIN + filters) off the main thread.
/// 3. Batches of `PitchFrame`s are delivered here on the main actor, where they
///    update the graph history, the session statistics, and the readouts.
@MainActor
@Observable
final class LivePitchMonitor {
    private(set) var status: MonitorStatus = .idle
    /// Most recent analysis frame (refreshed ~8 times a second).
    private(set) var latestFrame: PitchFrame?
    /// Pitch for the big number. Updated ~8 times a second so it's readable.
    private(set) var readoutFrequency: Double?
    /// False when the readout is showing a recent value but the voice has stopped.
    private(set) var readoutIsLive = false
    private(set) var stats = PitchSessionStats()
    private(set) var route: AudioRouteInfo?
    private(set) var captureFormat: CaptureFormat?
    private(set) var analysisConfiguration: AnalysisConfiguration?
    private(set) var droppedSampleCount = 0
    /// Moving average of DSP time per frame, in seconds.
    private(set) var averageProcessingTime = 0.0
    /// Changes whenever the graph history is cleared, so paused graphs redraw.
    private(set) var historyRevision = 0
    /// User-facing explanation of the last unexpected stop, if any.
    private(set) var notice: String?
    var targetZone: PitchTargetZone = .feminine

    /// Seconds of pitch shown on the scrolling graph.
    let graphDuration = 10.0

    // Per-frame state lives outside observation; the observed properties above
    // are refreshed ~8 times a second so SwiftUI isn't invalidated 94 times a second.
    // The graph reads `history` directly from its own display-synced timeline.
    @ObservationIgnored private var history = PitchHistory(capacity: 2048)
    @ObservationIgnored private var liveStats = PitchSessionStats()
    @ObservationIgnored private var liveProcessingTime = 0.0
    @ObservationIgnored private var newestFrame: PitchFrame?
    @ObservationIgnored private var lastVoicedFrame: PitchFrame?
    @ObservationIgnored private var lastBatchArrival: Date?
    @ObservationIgnored private var lastPublish = Date.distantPast
    /// The background DSP task and the main-actor task that receives its results.
    @ObservationIgnored private var analysisTasks: (producer: Task<Void, Never>, consumer: Task<Void, Never>)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resumesAfterInterruption = false
    private let capture: AudioCaptureService

    init(capture: AudioCaptureService = AudioCaptureService()) {
        self.capture = capture
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

    /// Clears the graph and statistics for a fresh session.
    func resetSession() {
        history.removeAll()
        liveStats = PitchSessionStats()
        stats = liveStats
        newestFrame = nil
        latestFrame = nil
        lastVoicedFrame = nil
        readoutFrequency = nil
        readoutIsLive = false
        historyRevision += 1
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

    private func beginAnalysis(format: CaptureFormat) async {
        await endAnalysis()
        // The user may have paused while the previous analysis was finishing.
        guard status == .running else { return }

        let configuration = AnalysisConfiguration(sampleRate: format.sampleRate)
        captureFormat = format
        analysisConfiguration = configuration
        // Continue the timeline after a pause, leaving a small visible gap.
        let startTime = history.latestTime.map { $0 + 0.25 } ?? 0
        let ring = capture.samples

        let (stream, continuation) = AsyncStream.makeStream(
            of: [PitchFrame].self,
            bufferingPolicy: .bufferingNewest(128)
        )

        // DSP runs on a background thread, never on the main actor.
        let producer = Task.detached(priority: .userInitiated) {
            let pipeline = LivePitchPipeline(configuration: configuration, startTime: startTime)
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

    private func ingest(_ frames: [PitchFrame]) {
        guard let newest = frames.last else { return }
        for frame in frames {
            history.append(PitchGraphPoint(frame: frame))
            liveStats.add(frame, target: targetZone)
            liveProcessingTime = liveProcessingTime == 0
                ? frame.processingDuration
                : liveProcessingTime * 0.95 + frame.processingDuration * 0.05
            if frame.status == .voiced {
                lastVoicedFrame = frame
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
        if averageProcessingTime != liveProcessingTime {
            averageProcessingTime = liveProcessingTime
        }
        let dropped = capture.samples.droppedSampleCount
        if dropped != droppedSampleCount {
            droppedSampleCount = dropped
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
            if route != info {
                route = info
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
