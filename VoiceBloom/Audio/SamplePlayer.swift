import AVFoundation
import Foundation
import Observation

/// Plays part of an in-memory clip: the trimmed selection of an imported
/// target voice, or one phrase of it for shadowing.
///
/// Listening should be paused first (the microphone would hear the clip).
@MainActor
@Observable
final class SamplePlayer {
    /// Identifies what is playing (a shadowing segment, or -1 for the trim preview).
    private(set) var playingID: Int?
    private(set) var errorMessage: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    var isPlaying: Bool { playingID != nil }

    /// Plays `range` (seconds) of the clip.
    /// - Returns: False when it couldn't play (see `errorMessage`).
    @discardableResult
    func play(_ clip: AudioClip, range: ClosedRange<Double>, id: Int = -1) -> Bool {
        stop()
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            errorMessage = "Discreet Mode plays clips through headphones only. Connect headphones to hear it."
            return false
        }
        let section = TargetClipAnalyzer.section(of: clip, range: range)
        guard !section.samples.isEmpty else { return false }
        guard let format = prepare(sampleRate: section.sampleRate),
              let buffer = Self.buffer(section.samples, format: format),
              let node
        else { return false }

        errorMessage = nil
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        playingID = id
        let duration = section.duration
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.15))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        return true
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        node?.stop()
        playingID = nil
    }

    /// Stops and releases the engine (when leaving the screen).
    func shutDown() {
        stop()
        engine?.stop()
        engine = nil
        node = nil
        format = nil
    }

    private func finish() {
        node?.stop()
        playingID = nil
        stopTask = nil
    }

    private func prepare(sampleRate: Double) -> AVAudioFormat? {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
        } catch {
            errorMessage = "The clip can’t play right now. Another app may be using audio."
            return nil
        }

        if let engine, engine.isRunning, let format, format.sampleRate == sampleRate {
            return format
        }
        engine?.stop()

        let newEngine = AVAudioEngine()
        let newNode = AVAudioPlayerNode()
        newEngine.attach(newNode)
        guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            errorMessage = "The clip can’t play right now."
            return nil
        }
        newEngine.connect(newNode, to: newEngine.mainMixerNode, format: newFormat)
        do {
            try newEngine.start()
        } catch {
            errorMessage = "The clip can’t play right now. Another app may be using audio."
            return nil
        }
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
        samples.withUnsafeBufferPointer { source in
            for index in 0..<samples.count {
                channel[index] = source[index]
            }
        }
        return buffer
    }
}
