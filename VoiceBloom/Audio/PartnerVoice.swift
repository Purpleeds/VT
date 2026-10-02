import AVFoundation
import Foundation
import Observation

/// Reads the other person's lines aloud in scenarios, with the on-device
/// speech synthesizer. While it speaks, the microphone's frames are kept out
/// of the practice statistics.
@MainActor
@Observable
final class PartnerVoice {
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var speakTask: Task<Void, Never>?

    /// Preference key for reading partner lines aloud.
    static let enabledKey = "scenarios.speakPartner"

    /// Speaks `text` and returns when it's done (or stopped).
    func speak(_ text: String, monitor: LiveVoiceMonitor) async {
        stop()
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        // Discreet Mode: only through headphones.
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            return
        }

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.usesApplicationAudioSession = true
        synthesizer.speak(utterance)
        isSpeaking = true

        let task = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                monitor.excludeFromStatistics(for: 0.6)
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                // The synthesizer takes a moment to start; give up after 40 s.
                if (!self.synthesizer.isSpeaking && elapsed > 0.6) || elapsed > 40 {
                    break
                }
            }
        }
        speakTask = task
        await task.value
        if speakTask == task {
            speakTask = nil
            isSpeaking = false
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}
