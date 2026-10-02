import AVFoundation
import Foundation
import Observation

nonisolated enum ToneTimbre: String, CaseIterable, Identifiable, Sendable {
    /// Pure sine: easiest to match.
    case pure
    /// A few soft harmonics, closer to a voice or a piano.
    case warm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pure: "Pure"
        case .warm: "Warm"
        }
    }

    /// Relative levels of harmonics 1, 2, 3…
    var harmonics: [Double] {
        switch self {
        case .pure: [1]
        case .warm: [1, 0.35, 0.18, 0.08]
        }
    }
}

/// Synthesizes reference tones (SPEC section 8).
nonisolated enum ToneSynthesis {
    /// A note that fades in quickly and decays like a soft piano.
    static func note(
        frequency: Double,
        duration: Double,
        sampleRate: Double,
        timbre: ToneTimbre = .warm,
        amplitude: Double = 0.3
    ) -> [Float] {
        let count = max(0, Int(duration * sampleRate))
        guard count > 0, frequency > 0, sampleRate > 0 else { return [] }
        let attack = min(0.02, duration / 4)
        let release = min(0.25, duration / 3)
        let weights = normalizedHarmonics(timbre, frequency: frequency, sampleRate: sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            var envelope = 1.0
            if time < attack {
                envelope = time / attack
            } else if time > duration - release {
                envelope = max(0, (duration - time) / release)
            }
            // Gentle decay over the note, like a struck string.
            envelope *= exp(-0.6 * time)
            return Float(amplitude * envelope * sample(at: time, frequency: frequency, weights: weights))
        }
    }

    /// One second (rounded to whole cycles) that loops without clicks, for a
    /// steady drone.
    static func loop(
        frequency: Double,
        sampleRate: Double,
        timbre: ToneTimbre = .pure,
        amplitude: Double = 0.25
    ) -> [Float] {
        guard frequency > 0, sampleRate > 0 else { return [] }
        let cycles = max(1, (frequency).rounded())
        let count = Int((cycles * sampleRate / frequency).rounded())
        // Adjust the frequency very slightly so the buffer holds whole cycles.
        let exact = cycles * sampleRate / Double(count)
        let weights = normalizedHarmonics(timbre, frequency: exact, sampleRate: sampleRate)
        return (0..<count).map { index in
            Float(amplitude * sample(at: Double(index) / sampleRate, frequency: exact, weights: weights))
        }
    }

    private static func normalizedHarmonics(_ timbre: ToneTimbre, frequency: Double, sampleRate: Double) -> [Double] {
        // Drop harmonics above Nyquist and normalize so loudness is the same.
        let nyquist = sampleRate / 2
        let weights = timbre.harmonics.enumerated().map { index, weight in
            Double(index + 1) * frequency < nyquist ? weight : 0
        }
        let total = weights.reduce(0, +)
        return total > 0 ? weights.map { $0 / total } : weights
    }

    private static func sample(at time: Double, frequency: Double, weights: [Double]) -> Double {
        var value = 0.0
        for (index, weight) in weights.enumerated() where weight > 0 {
            value += weight * sin(2 * .pi * frequency * Double(index + 1) * time)
        }
        return value
    }
}

/// Plays reference tones and piano notes (pitch matching, tone generator,
/// mini piano, lessons). Uses its own small engine so it works whether or
/// not the microphone is listening.
@MainActor
@Observable
final class TonePlayer {
    /// Frequency of the steady tone playing now (nil when silent).
    private(set) var droneFrequency: Double?
    /// The last note started (for highlighting piano keys).
    private(set) var lastNote: Double?
    private(set) var errorMessage: String?
    /// Discreet Mode: only play when headphones are connected.
    var requiresHeadphones = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var format: AVAudioFormat?

    /// True when the current output is headphones (wired, AirPods, …).
    static var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphoneTypes: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        return outputs.contains { headphoneTypes.contains($0.portType) }
    }

    /// Plays one decaying note.
    func playNote(_ frequency: Double, duration: Double = 1.4, timbre: ToneTimbre = .warm) {
        guard canPlay() else { return }
        stopDrone()
        guard let format = prepare() else { return }
        let samples = ToneSynthesis.note(frequency: frequency, duration: duration, sampleRate: format.sampleRate, timbre: timbre)
        guard let buffer = Self.buffer(samples, format: format), let node else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        lastNote = frequency
    }

    /// Starts a steady tone until `stopDrone()`.
    func startDrone(_ frequency: Double, timbre: ToneTimbre = .pure) {
        guard canPlay() else { return }
        guard let format = prepare() else { return }
        let samples = ToneSynthesis.loop(frequency: frequency, sampleRate: format.sampleRate, timbre: timbre)
        guard let buffer = Self.buffer(samples, format: format), let node else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        node.play()
        droneFrequency = frequency
        lastNote = frequency
    }

    func stopDrone() {
        node?.stop()
        droneFrequency = nil
    }

    /// Stops everything and releases the engine.
    func stop() {
        node?.stop()
        engine?.stop()
        droneFrequency = nil
    }

    private func canPlay() -> Bool {
        if requiresHeadphones, !Self.headphonesConnected {
            errorMessage = "Discreet Mode plays tones through headphones only. Connect headphones to hear them."
            return false
        }
        errorMessage = nil
        return true
    }

    /// Sets up the audio session and engine if needed.
    private func prepare() -> AVAudioFormat? {
        let session = AVAudioSession.sharedInstance()
        do {
            // While the microphone listens the session is already
            // .playAndRecord; changing it would interrupt listening.
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
        } catch {
            errorMessage = "Tones can’t play right now. Another app may be using audio."
            return nil
        }

        if let engine, engine.isRunning, let format {
            return format
        }

        let newEngine = AVAudioEngine()
        let newNode = AVAudioPlayerNode()
        newEngine.attach(newNode)
        let outputRate = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate > 0 ? outputRate : 48_000, channels: 1) else {
            errorMessage = "Tones can’t play right now."
            return nil
        }
        newEngine.connect(newNode, to: newEngine.mainMixerNode, format: newFormat)
        do {
            try newEngine.start()
        } catch {
            errorMessage = "Tones can’t play right now. Another app may be using audio."
            return nil
        }
        engine?.stop()
        engine = newEngine
        node = newNode
        format = newFormat
        return newFormat
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
