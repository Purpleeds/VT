import CoreHaptics
import Foundation

/// Plays haptic patterns with Core Haptics.
///
/// The engine is created lazily and set to haptics-only, so it never touches
/// the audio session used for recording. The capture service also enables
/// haptics during recording (iOS mutes them by default while the mic is on).
/// If the system resets the engine, the next play rebuilds it.
@MainActor
final class HapticsService {
    /// False on devices without a Taptic Engine (e.g. some iPads), where
    /// haptic alerts are simply skipped.
    let isSupported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var engine: CHHapticEngine?

    func play(_ description: HapticPatternDescription) {
        guard isSupported, !description.events.isEmpty else { return }
        do {
            try start(description)
        } catch {
            // The haptic server may have been reset (e.g. after an
            // interruption). Rebuild the engine once and try again.
            engine = nil
            try? start(description)
        }
    }

    /// Releases the engine (e.g. when leaving practice).
    func stop() {
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    private func start(_ description: HapticPatternDescription) throws {
        let engine = try preparedEngine()
        let pattern = try CHHapticPattern(events: description.events.map(Self.event(from:)), parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
    }

    private func preparedEngine() throws -> CHHapticEngine {
        if let engine {
            try engine.start()
            return engine
        }
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true
        newEngine.isAutoShutdownEnabled = true
        try newEngine.start()
        engine = newEngine
        return newEngine
    }

    private static func event(from description: HapticEventDescription) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(max(description.intensity, 0), 1))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(min(max(description.sharpness, 0), 1))),
        ]
        if description.isTransient {
            return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: description.time)
        }
        return CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: parameters,
            relativeTime: description.time,
            duration: description.duration
        )
    }
}

/// Delivers feedback cues through haptics and/or soft chimes.
@MainActor
final class FeedbackOutput {
    let haptics = HapticsService()
    private let capture: AudioCaptureService

    init(capture: AudioCaptureService) {
        self.capture = capture
    }

    var supportsHaptics: Bool { haptics.isSupported }

    /// Plays `cue` on the requested channels.
    /// - Returns: Seconds the analysis should ignore the microphone, because it
    ///   may hear the chime or the vibration (0 if nothing played).
    @discardableResult
    func play(_ cue: FeedbackCue, haptic: Bool, sound: Bool) -> Double {
        var busy = 0.0
        if haptic, haptics.isSupported {
            let pattern = cue.haptic
            haptics.play(pattern)
            busy = max(busy, pattern.duration)
        }
        if sound {
            let tone = cue.tone
            let capture = capture
            Task { await capture.playTone(tone) }
            busy = max(busy, tone.duration)
        }
        // Allow for audio latency on top of the cue itself.
        return busy > 0 ? busy + 0.3 : 0
    }

    func stop() {
        haptics.stop()
    }
}
