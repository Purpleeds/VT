import Foundation
import Observation

nonisolated enum CalibrationStep: Sendable, Equatable {
    case intro
    case measuringNoise
    case measuringVoice
    case finished
    case failed(String)
}

/// Runs the two-step mic calibration:
/// 1. Five seconds of silence to measure the room's noise floor.
/// 2. A short, comfortable "aah" to check the voice level against that floor.
///
/// It listens to every analyzed frame from `LiveVoiceMonitor` and times each
/// step with the audio clock (frame timestamps), not the wall clock.
@MainActor
@Observable
final class MicCalibrationModel {
    static let settleDuration = 0.3
    static let noiseDuration = 5.0
    static let requiredVoicedDuration = 2.0
    static let voiceTimeout = 10.0

    private(set) var step: CalibrationStep = .intro
    /// Progress of the current measuring step (0...1).
    private(set) var progress = 0.0
    /// Live input level for the on-screen meter (dBFS).
    private(set) var currentLevelDb: Double?
    private(set) var noise: NoiseAssessment?
    private(set) var voice: VoiceLevelAssessment?
    private(set) var isSaved = false

    private let monitor: LiveVoiceMonitor
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var phaseStart: Double?
    @ObservationIgnored private var noiseLevels: [Double] = []
    @ObservationIgnored private var voiceLevels: [Double] = []
    @ObservationIgnored private var voicePeakDb = SignalLevel.silenceDb
    @ObservationIgnored private var voicedDuration = 0.0
    @ObservationIgnored private var frameCounter = 0
    /// Whether the user was already listening before calibration started.
    @ObservationIgnored private var wasListeningBefore: Bool?

    init(monitor: LiveVoiceMonitor) {
        self.monitor = monitor
    }

    var isMeasuring: Bool {
        step == .measuringNoise || step == .measuringVoice
    }

    /// The monitor's status, exposed so the view can react to interruptions.
    var monitorStatus: MonitorStatus { monitor.status }

    // MARK: Flow

    func begin() async {
        guard !isMeasuring else { return }
        if wasListeningBefore == nil {
            wasListeningBefore = monitor.status.isRunning
        }
        resetMeasurements()
        isSaved = false
        monitor.isCalibrating = true

        if !monitor.status.isRunning {
            await monitor.start()
        }
        guard monitor.status.isRunning else {
            monitor.isCalibrating = false
            step = .failed(Self.message(forUnavailable: monitor.status))
            return
        }

        listenerID = monitor.addFrameListener { [weak self] frame in
            self?.handle(frame)
        }
        step = .measuringNoise
    }

    /// Stops measuring and puts the microphone back the way it was.
    func cancel() async {
        guard isMeasuring || listenerID != nil else { return }
        if isMeasuring {
            step = .intro
        }
        stopObserving()
        await restoreMicrophone()
    }

    /// Saves the result and starts using it.
    func save() async {
        guard step == .finished, let noise, let voice else { return }
        let route = monitor.route
        let calibration = MicCalibration(
            noiseFloorDb: noise.floorDb,
            voiceLevelDb: voice.levelDb,
            voicePeakDb: voice.peakDb,
            inputName: route?.inputName ?? "Microphone",
            inputKind: route?.inputKind ?? .builtInMicrophone,
            date: Date()
        )
        await monitor.applyCalibration(calibration)
        isSaved = true
    }

    /// Called when the monitor's status changes (e.g. a phone call interrupts).
    func monitorStatusChanged(_ status: MonitorStatus) {
        guard isMeasuring, !status.isRunning else { return }
        fail("Calibration was interrupted. Please try again.")
    }

    // MARK: Measuring

    private func handle(_ frame: VoiceFrame) {
        frameCounter += 1
        // ~20 UI updates a second is plenty for a level meter.
        let shouldPublish = frameCounter % 4 == 0

        switch step {
        case .measuringNoise:
            let start = phaseStart ?? frame.time
            phaseStart = start
            let elapsed = frame.time - start
            // Skip the first moments: the tap on "Start" may still be audible.
            if elapsed >= Self.settleDuration {
                noiseLevels.append(frame.levelDb)
            }
            if shouldPublish {
                currentLevelDb = frame.levelDb
                progress = min(1, elapsed / (Self.settleDuration + Self.noiseDuration))
            }
            if elapsed >= Self.settleDuration + Self.noiseDuration {
                finishNoiseStep()
            }

        case .measuringVoice:
            let start = phaseStart ?? frame.time
            phaseStart = start
            if let floor = noise?.floorDb, MicCalibrationAnalysis.isVoiced(frame, noiseFloorDb: floor) {
                voiceLevels.append(frame.levelDb)
                voicePeakDb = max(voicePeakDb, frame.peakDb)
                voicedDuration += monitor.analysisConfiguration?.hopDuration ?? AnalysisConfiguration().hopDuration
            }
            if shouldPublish {
                currentLevelDb = frame.levelDb
                progress = min(1, voicedDuration / Self.requiredVoicedDuration)
            }
            if voicedDuration >= Self.requiredVoicedDuration {
                finishVoiceStep()
            } else if frame.time - start >= Self.voiceTimeout {
                fail("We couldn’t hear a steady “aah”. Try again and hold the sound for a few seconds at a comfortable volume.")
            }

        case .intro, .finished, .failed:
            break
        }
    }

    private func finishNoiseStep() {
        guard let assessment = MicCalibrationAnalysis.assessNoise(levels: noiseLevels) else {
            fail("Couldn’t measure the room. Please try again.")
            return
        }
        noise = assessment
        phaseStart = nil
        progress = 0
        step = .measuringVoice
    }

    private func finishVoiceStep() {
        guard let floor = noise?.floorDb,
              let assessment = MicCalibrationAnalysis.assessVoice(
                levels: voiceLevels,
                peakDb: voicePeakDb,
                noiseFloorDb: floor
              )
        else {
            fail("Couldn’t measure your voice level. Please try again.")
            return
        }
        voice = assessment
        progress = 1
        step = .finished
        stopObserving()
        Task { await restoreMicrophone() }
    }

    private func fail(_ message: String) {
        step = .failed(message)
        stopObserving()
        Task { await restoreMicrophone() }
    }

    /// Stops receiving frames (synchronous, so a quick retry can't be affected).
    private func stopObserving() {
        if let listenerID {
            monitor.removeFrameListener(listenerID)
            self.listenerID = nil
        }
        monitor.isCalibrating = false
    }

    /// Turns the microphone back off if the user wasn't listening before.
    private func restoreMicrophone() async {
        // A retry may have started in the meantime; leave the mic running for it.
        guard !isMeasuring, wasListeningBefore == false else { return }
        await monitor.stop()
        // The calibration "aah" isn't practice: clear it from the graph and meters.
        monitor.clearLiveReadings()
    }

    private func resetMeasurements() {
        phaseStart = nil
        noiseLevels.removeAll()
        voiceLevels.removeAll()
        voicePeakDb = SignalLevel.silenceDb
        voicedDuration = 0
        frameCounter = 0
        progress = 0
        currentLevelDb = nil
        noise = nil
        voice = nil
    }

    private static func message(forUnavailable status: MonitorStatus) -> String {
        switch status {
        case .permissionDenied:
            "Microphone access is off. Turn on Microphone for Chirp in Settings, then try again."
        case .failed(let message):
            message
        case .idle, .starting, .running, .paused:
            "The microphone couldn’t start. Please try again."
        }
    }
}
