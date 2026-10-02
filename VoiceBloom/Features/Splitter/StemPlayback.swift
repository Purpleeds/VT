import AVFoundation
import Foundation

/// Plays the vocals and backing files in sync, each with its own gain
/// (up to 150 %, so each part runs through an EQ unit's global gain).
/// Files stream from disk, so long songs use little memory.
@MainActor
final class StemPlaybackEngine {
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let vocalsNode = AVAudioPlayerNode()
    private let backingNode = AVAudioPlayerNode()
    private let vocalsEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let backingEQ = AVAudioUnitEQ(numberOfBands: 1)
    private var vocalsFile: AVAudioFile?
    private var backingFile: AVAudioFile?
    private var connectedFormats: [AVAudioFormat?] = [nil, nil]
    private var segmentStart = 0.0

    init() {
        engine.attach(vocalsNode)
        engine.attach(backingNode)
        engine.attach(vocalsEQ)
        engine.attach(backingEQ)
        for eq in [vocalsEQ, backingEQ] {
            eq.bands.first?.bypass = true
        }
    }

    /// Opens the parts to play (either may be missing).
    func load(vocals: URL?, backing: URL?) throws {
        let position = currentTime
        let wasPlaying = isPlaying
        stop()
        do {
            vocalsFile = try vocals.map { try AVAudioFile(forReading: $0) }
            backingFile = try backing.map { try AVAudioFile(forReading: $0) }
        } catch {
            throw SeparationError.unreadable
        }
        let files = [vocalsFile, backingFile].compactMap { $0 }
        guard !files.isEmpty else { throw SeparationError.unreadable }
        duration = files.map { Double($0.length) / $0.processingFormat.sampleRate }.max() ?? 0
        connect(vocalsNode, eq: vocalsEQ, format: vocalsFile?.processingFormat, slot: 0)
        connect(backingNode, eq: backingEQ, format: backingFile?.processingFormat, slot: 1)
        segmentStart = min(position, duration)
        if wasPlaying {
            try play(from: segmentStart)
        }
    }

    private func connect(_ node: AVAudioPlayerNode, eq: AVAudioUnitEQ, format: AVAudioFormat?, slot: Int) {
        guard let format, connectedFormats[slot] != format else { return }
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        connectedFormats[slot] = format
    }

    /// Playback position (seconds).
    var currentTime: Double {
        guard isPlaying else { return segmentStart }
        for (node, file) in [(vocalsNode, vocalsFile), (backingNode, backingFile)] where file != nil {
            if let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0 {
                return segmentStart + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
            }
        }
        return segmentStart
    }

    func setGains(vocals: Double, backing: Double) {
        vocalsNode.volume = vocals > 0.0001 ? 1 : 0
        backingNode.volume = backing > 0.0001 ? 1 : 0
        vocalsEQ.globalGain = StemMixSettings.decibels(forGain: vocals)
        backingEQ.globalGain = StemMixSettings.decibels(forGain: backing)
    }

    /// Starts both parts together from `time`.
    func play(from time: Double) throws {
        stopNodes()
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            errorMessage = "Discreet Mode plays audio through headphones only. Connect headphones to listen."
            throw SeparationError.engineFailed
        }
        errorMessage = nil
        try startEngine()
        let start = min(max(0, time), duration)
        var scheduled = false
        for (node, file) in [(vocalsNode, vocalsFile), (backingNode, backingFile)] {
            guard let file else { continue }
            let rate = file.processingFormat.sampleRate
            let firstFrame = AVAudioFramePosition(start * rate)
            let remaining = file.length - firstFrame
            guard remaining > 0 else { continue }
            node.scheduleSegment(file, startingFrame: firstFrame, frameCount: AVAudioFrameCount(remaining), at: nil, completionHandler: nil)
            scheduled = true
        }
        segmentStart = start
        guard scheduled else { return }
        // A shared start time keeps the parts sample-aligned.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        if vocalsFile != nil {
            vocalsNode.play(at: when)
        }
        if backingFile != nil {
            backingNode.play(at: when)
        }
        isPlaying = true
    }

    /// Pauses, keeping the position.
    func stop() {
        let position = currentTime
        stopNodes()
        segmentStart = min(position, duration)
    }

    func seek(to time: Double) throws {
        let target = min(max(0, time), duration)
        if isPlaying {
            try play(from: target)
        } else {
            segmentStart = target
        }
    }

    func shutDown() {
        stopNodes()
        engine.stop()
    }

    private func stopNodes() {
        vocalsNode.stop()
        backingNode.stop()
        isPlaying = false
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // Keep .playAndRecord while recording over the backing.
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            errorMessage = "Audio can’t play right now. Another app may be using it."
            throw SeparationError.engineFailed
        }
    }
}
