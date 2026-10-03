import AVFoundation
import Foundation

/// Synthesized guide notes that follow the bars (SPEC section 22.1: "Guide
/// tones only"), including the curves of speech bars.
nonisolated enum GuideToneRenderer {
    static let sampleRate = 44_100.0
    static let amplitude = 0.22
    static let attack = 0.015
    static let release = 0.04

    /// Mono samples for `range` (track seconds) of the (already transposed) bars.
    static func render(bars: [TrackBar], range: ClosedRange<Double>, sampleRate: Double = sampleRate) -> [Float] {
        let length = max(0, Int(((range.upperBound - range.lowerBound) * sampleRate).rounded()))
        var output = [Float](repeating: 0, count: length)
        guard length > 0 else { return output }
        let weights = harmonicWeights
        for bar in bars {
            let first = max(0, Int(((bar.start - range.lowerBound) * sampleRate).rounded()))
            let last = min(length, Int(((bar.end - range.lowerBound) * sampleRate).rounded()))
            guard first < last else { continue }
            var phase = 0.0
            var frequency = PitchMath.frequency(forMidiNote: bar.targetMidi(at: bar.start))
            for index in first..<last {
                let time = range.lowerBound + Double(index) / sampleRate
                let local = time - bar.start
                let remaining = bar.end - time
                var envelope = 1.0
                if local < attack {
                    envelope = max(0, local / attack)
                }
                if remaining < release {
                    envelope = min(envelope, max(0, remaining / release))
                }
                // Curves change slowly: update the frequency every 64 samples.
                if bar.isCurved, (index - first) % 64 == 0 {
                    frequency = PitchMath.frequency(forMidiNote: bar.targetMidi(at: time))
                }
                phase += 2 * Double.pi * frequency / sampleRate
                if phase > 2 * Double.pi * 1_000 {
                    phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
                }
                var value = 0.0
                for (harmonic, weight) in weights.enumerated() where Double(harmonic + 1) * frequency < sampleRate / 2 {
                    value += weight * sin(phase * Double(harmonic + 1))
                }
                output[index] += Float(amplitude * envelope * value)
            }
        }
        return output
    }

    /// A soft, voice-like tone (same balance as the "warm" reference tones).
    private static var harmonicWeights: [Double] {
        let raw = ToneTimbre.warm.harmonics
        let total = raw.reduce(0, +)
        return raw.map { $0 / total }
    }

    /// Short clicks every `interval` seconds, for the latency calibration.
    static func clicks(count: Int, interval: Double, sampleRate: Double = sampleRate) -> [Float] {
        let length = max(0, Int((Double(count) * interval * sampleRate).rounded()))
        var output = [Float](repeating: 0, count: length)
        let clickLength = Int(0.03 * sampleRate)
        for beat in 0..<count {
            let start = Int((Double(beat) * interval * sampleRate).rounded())
            for offset in 0..<clickLength where start + offset < length {
                let time = Double(offset) / sampleRate
                let envelope = exp(-time * 120)
                output[start + offset] = Float(0.6 * envelope * sin(2 * Double.pi * 1_500 * time))
            }
        }
        return output
    }
}

/// Reads the part of a file the track plays.
nonisolated enum TrackAudioLoader {
    /// `duration` seconds from `start` (seconds into the file), as stereo.
    static func section(of url: URL, from start: Double, duration: Double) throws -> (audio: StereoBuffer, sampleRate: Double) {
        let reader = try AudioFileStereoReader(url: url)
        let rate = reader.sampleRate
        reader.skip(Int((max(0, start) * rate).rounded()))
        let wanted = max(0, Int((duration * rate).rounded()))
        var buffer = StereoBuffer.empty
        while buffer.count < wanted, let block = try reader.read(maxFrames: min(65_536, wanted - buffer.count)) {
            buffer.append(block)
        }
        return (buffer.prefix(wanted), rate)
    }

    /// The sum of two parts (vocals + backing = the original mix).
    static func mixed(_ first: StereoBuffer, _ second: StereoBuffer) -> StereoBuffer {
        let count = max(first.count, second.count)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for index in 0..<first.count {
            left[index] += first.left[index]
            right[index] += first.right[index]
        }
        for index in 0..<second.count {
            left[index] += second.left[index]
            right[index] += second.right[index]
        }
        return StereoBuffer(left: left, right: right)
    }

    /// The sound for `mode` over `range` (track seconds), ready to play.
    /// Nil for silent mode or when the files are missing.
    static func load(
        mode: TrackAudioMode,
        sources: TrackAudioSources,
        transposedBars: [TrackBar],
        range: ClosedRange<Double>
    ) throws -> (audio: StereoBuffer, sampleRate: Double)? {
        let length = range.upperBound - range.lowerBound
        switch mode {
        case .silent:
            return nil
        case .guideTones:
            let samples = GuideToneRenderer.render(bars: transposedBars, range: range)
            return (StereoBuffer(mono: samples), GuideToneRenderer.sampleRate)
        case .original:
            if let original = sources.original {
                return try section(of: original, from: range.lowerBound, duration: length)
            }
            guard let vocals = sources.vocals, let backing = sources.backing else { return nil }
            let start = range.lowerBound + sources.splitOffset
            let voice = try section(of: vocals, from: start, duration: length)
            let music = try section(of: backing, from: start, duration: length)
            return (mixed(voice.audio, music.audio), voice.sampleRate)
        case .vocalsOnly:
            guard let vocals = sources.vocals else { return nil }
            return try section(of: vocals, from: range.lowerBound + sources.splitOffset, duration: length)
        case .backingOnly:
            guard let backing = sources.backing else { return nil }
            return try section(of: backing, from: range.lowerBound + sources.splitOffset, duration: length)
        }
    }
}

/// Plays a track's sound in step with the bars: speed changes keep the pitch
/// (AVAudioUnitTimePitch), transposition shifts it, and loops repeat
/// seamlessly. Uses its own engine next to the microphone's.
@MainActor
final class TrackAudioPlayer {
    private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var isStarted = false

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    var hasSound: Bool { buffer != nil }

    /// Gets a loaded sound ready (load it with `TrackAudioLoader` off the
    /// main thread).
    /// - Parameter pitchShift: Semitones to shift recorded audio (guide
    ///   tones are rendered at the right pitch already).
    func prepare(_ audio: StereoBuffer?, sampleRate: Double, pitchShift: Int, speed: Double) {
        stop()
        buffer = nil
        guard let audio, !audio.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let channels = pcm.floatChannelData
        else {
            errorMessage = "The track’s sound couldn’t be prepared."
            return
        }
        pcm.frameLength = AVAudioFrameCount(audio.count)
        audio.left.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channels[0].update(from: base, count: audio.count)
            }
        }
        audio.right.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channels[1].update(from: base, count: audio.count)
            }
        }
        if connectedFormat != format {
            if engine.isRunning {
                engine.stop()
            }
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        timePitch.rate = Float(speed)
        timePitch.pitch = Float(pitchShift * 100)
        // The effect adds a little delay, so it's skipped when not needed.
        timePitch.bypass = pitchShift == 0 && abs(speed - 1) < 0.001
        buffer = pcm
    }

    /// Starts playing at a host-clock time (seconds), shared with the bars.
    func start(atHost host: Double, loops: Bool) -> Bool {
        guard let buffer else { return true }
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            errorMessage = "Discreet Mode plays sound through headphones only, so the track is playing silently."
            return false
        }
        do {
            try startEngine()
        } catch {
            errorMessage = "The track’s sound can’t play right now. Another app may be using audio."
            return false
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: loops ? [.loops] : [], completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: HostClock.hostTime(forSeconds: host)))
        isStarted = true
        errorMessage = nil
        return true
    }

    func pause() {
        guard isStarted else { return }
        player.pause()
    }

    func resume(atHost host: Double) {
        guard isStarted else { return }
        player.play(at: AVAudioTime(hostTime: HostClock.hostTime(forSeconds: host)))
    }

    func stop() {
        player.stop()
        isStarted = false
    }

    func shutDown() {
        stop()
        engine.stop()
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // While the microphone listens the session is already .playAndRecord;
        // changing it would interrupt listening.
        if session.category != .playAndRecord {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }
}
