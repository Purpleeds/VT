import Foundation
import Observation

/// Records and measures one short take: a baseline reading, a placement test
/// part, a Quick Check, a lesson exercise or a scenario turn.
///
/// Takes use the shared microphone but are kept out of the practice
/// session's statistics (like calibration).
@MainActor
@Observable
final class VoiceTakeRecorder {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Seconds recorded so far (audio time).
    private(set) var elapsed = 0.0
    private(set) var plannedDuration = 0.0
    /// Live pitch for the display (nil in silence).
    private(set) var livePitch: Double?
    /// 0…1 input level for a small meter.
    private(set) var liveLevel = 0.0
    private(set) var result: TakeResult?
    /// The take's audio (when it fits in the 30 s recent-audio buffer).
    private(set) var audio: AudioClip?

    let monitor: LiveVoiceMonitor
    @ObservationIgnored private var analyzer: TakeAnalyzer?
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var firstFrameTime: Double?
    @ObservationIgnored private var wasListening = false
    @ObservationIgnored private var lastPublish = 0.0
    @ObservationIgnored private var excludesFromSession = true

    init(monitor: LiveVoiceMonitor) {
        self.monitor = monitor
    }

    var progress: Double {
        plannedDuration > 0 ? min(elapsed / plannedDuration, 1) : 0
    }

    var isRecording: Bool { phase == .recording || phase == .starting }

    /// Starts listening (if needed) and records for `duration` seconds.
    /// - Parameter countsTowardSession: True inside guided sessions, where the
    ///   take is part of practice; false for tests like the baseline.
    func start(
        duration: Double,
        target: PitchTargetZone,
        resonanceMode: ResonanceMode = .speech,
        references: PersonalReferences = .none,
        countsTowardSession: Bool = false
    ) async {
        guard !isRecording else { return }
        phase = .starting
        result = nil
        audio = nil
        elapsed = 0
        livePitch = nil
        plannedDuration = duration
        firstFrameTime = nil
        wasListening = monitor.status.isRunning
        excludesFromSession = !countsTowardSession
        if excludesFromSession {
            monitor.isCalibrating = true
        }

        if !monitor.status.isRunning {
            await monitor.start()
        }
        guard monitor.status.isRunning else {
            if excludesFromSession {
                monitor.isCalibrating = false
            }
            phase = .failed(Self.message(for: monitor.status))
            return
        }
        // Cancelled while the microphone was starting.
        guard phase == .starting else { return }

        let interval = monitor.analysisConfiguration?.hopDuration ?? AnalysisConfiguration().hopDuration
        analyzer = TakeAnalyzer(target: target, resonanceMode: resonanceMode, references: references, frameInterval: interval)
        listenerID = monitor.addFrameListener { [weak self] frame in
            self?.handle(frame)
        }
        phase = .recording

        // Listening can stop underneath us (a call, Siri); don't wait forever.
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.phase == .recording, !self.monitor.status.isRunning {
                    self.fail("Recording stopped because listening was interrupted. Please try again.")
                    return
                }
            }
        }
    }

    /// Ends the take now (or when the time is up) and measures it.
    @discardableResult
    func finish() -> TakeResult? {
        guard phase == .recording, let analyzer else { return nil }
        let measured = analyzer.result()
        audio = monitor.recentAudio(lastSeconds: min(elapsed + 0.2, 30))
        cleanUp()
        result = measured
        phase = .finished
        return measured
    }

    /// Abandons the take.
    func cancel() {
        cleanUp()
        phase = .idle
    }

    /// Stops the microphone again if it wasn't listening before the take.
    func restoreMicrophone() async {
        guard !isRecording, !wasListening, monitor.status.isRunning else { return }
        await monitor.stop()
        monitor.clearLiveReadings()
    }

    func reset() {
        cancel()
        result = nil
        audio = nil
        elapsed = 0
    }

    private func handle(_ frame: VoiceFrame) {
        guard phase == .recording else { return }
        analyzer?.add(frame)
        let start = firstFrameTime ?? frame.time
        firstFrameTime = start
        let newElapsed = frame.time - start
        // Refresh the display ~10 times a second.
        if newElapsed - lastPublish >= 0.1 || newElapsed < lastPublish {
            lastPublish = newElapsed
            elapsed = newElapsed
            livePitch = frame.status == .voiced ? frame.displayFrequency : nil
            liveLevel = min(max((frame.levelDb - frame.noiseFloorDb) / 40, 0), 1)
        }
        if newElapsed >= plannedDuration {
            elapsed = plannedDuration
            finish()
        }
    }

    private func fail(_ message: String) {
        cleanUp()
        phase = .failed(message)
    }

    private func cleanUp() {
        if let listenerID {
            monitor.removeFrameListener(listenerID)
        }
        listenerID = nil
        analyzer = nil
        watchdog?.cancel()
        watchdog = nil
        if excludesFromSession {
            monitor.isCalibrating = false
        }
        lastPublish = 0
    }

    static func message(for status: MonitorStatus) -> String {
        switch status {
        case .permissionDenied:
            "VoiceBloom needs microphone access to hear you. Turn on Microphone for VoiceBloom in Settings."
        case .failed(let message):
            message
        default:
            "The microphone couldn’t start. Please try again."
        }
    }
}
