import Accelerate
import Foundation

/// Clear Mic's place in the live chain (SPEC section 24.2), on the analysis
/// thread right after the lock-free ring buffer:
///
///     ring → raw chunk → recent-audio buffer + transcript (always raw)
///                      → raw level, peak and noise meters
///                      → ClearMicProcessor → enhanced chunk
///     pipeline ← enhanced chunk (or the raw chunk when analyzing raw)
///
/// Frame timestamps stay exact: enhanced sample n is the pipeline's n-th
/// sample, so only arrival is delayed (by `latency`).
///
/// All buffers are allocated up front; draining never allocates except for
/// the frames the pipeline returns (as before). Not thread-safe: owned by the
/// single analysis task.
nonisolated final class ClearMicStage {
    let sampleRate: Double
    /// True when the pipeline hears enhanced audio.
    let analyzesEnhanced: Bool
    private let processor: ClearMicProcessor?
    private let control: ClearMicControl
    private let inputKind: AudioInputKind?
    private let rawScratch: UnsafeMutablePointer<Float>
    private let rawCapacity: Int
    private let enhancedScratch: UnsafeMutablePointer<Float>
    private var parametersRevision: Int
    // Raw meters. Background noise is the quietest 100 ms of the last 2 s:
    // quick to settle, and a pause between words is enough to see the room.
    private static let blocksPerSegment = 5
    private static let segmentCount = 20
    private var segmentLevels: [Double]
    private var segmentWriteIndex = 0
    private var segmentFilled = 0
    private var segmentSquares = 0.0
    private var segmentBlocks = 0
    private var blockSquares = 0.0
    private var blockCount = 0
    private let blockLength: Int
    private var levelPower = 0.0
    private let levelSmoothing: Double
    private var peakDb = SignalLevel.silenceDb
    private var peakAge = 0.0
    private var sinceProfilePublish = 0.0
    private(set) var rawSampleCount = 0

    /// - Parameters:
    ///   - parameters: Clear Mic's processing, or nil for Off (the processor
    ///     still runs, passing audio through, so it keeps learning the room).
    ///   - analyzesEnhanced: Whether the pipeline gets the enhanced audio.
    ///   - profile: A saved noise profile to start from.
    init(
        sampleRate: Double,
        parameters: ClearMicParameters?,
        analyzesEnhanced: Bool,
        profile: ClearMicNoiseProfile?,
        inputKind: AudioInputKind?,
        control: ClearMicControl,
        hopHint: Int
    ) {
        self.sampleRate = sampleRate
        self.control = control
        self.inputKind = inputKind
        processor = ClearMicProcessor(sampleRate: sampleRate, parameters: parameters ?? .passThrough, profile: profile)
        self.analyzesEnhanced = analyzesEnhanced && processor != nil && parameters != nil
        rawCapacity = max(4_096, hopHint * 8)
        rawScratch = .allocate(capacity: rawCapacity)
        rawScratch.initialize(repeating: 0, count: rawCapacity)
        let enhancedCapacity = rawCapacity + (processor?.hopSize ?? 0) + 1
        enhancedScratch = .allocate(capacity: enhancedCapacity)
        enhancedScratch.initialize(repeating: 0, count: enhancedCapacity)
        parametersRevision = control.currentParameters.revision
        blockLength = max(1, Int(sampleRate * 0.02))
        // ~50 ms smoothing for the level meter, per 20 ms block.
        levelSmoothing = exp(-0.02 / 0.05)
        segmentLevels = [Double](repeating: SignalLevel.silenceDb, count: ClearMicStage.segmentCount)
    }

    deinit {
        rawScratch.deallocate()
        enhancedScratch.deallocate()
    }

    /// Extra delay of the analyzed audio (seconds).
    var latency: Double {
        analyzesEnhanced ? (processor?.latency ?? 0) : 0
    }

    var fftSize: Int? { processor?.fftSize }

    /// Reads everything waiting in the ring buffer: raw audio to `tap`,
    /// enhanced (or raw) audio to `pipeline`.
    /// - Parameter rawStartTime: Audio time of the run's first raw sample.
    func drain(_ ring: SampleRingBuffer, pipeline: VoiceAnalysisPipeline, tap: AudioTap, rawStartTime: Double) -> [VoiceFrame] {
        applyRequests()
        var frames: [VoiceFrame] = []
        while true {
            let count = ring.read(into: UnsafeMutableBufferPointer(start: rawScratch, count: rawCapacity))
            guard count > 0 else { break }
            let raw = UnsafeBufferPointer(start: rawScratch, count: count)
            tap.consume(raw, startTime: rawStartTime + Double(rawSampleCount) / sampleRate)
            rawSampleCount += count
            meter(raw)

            if let processor {
                let written = processor.process(raw, into: enhancedScratch)
                if analyzesEnhanced {
                    if written > 0 {
                        frames.append(contentsOf: pipeline.process(UnsafeBufferPointer(start: enhancedScratch, count: written)))
                    }
                } else {
                    frames.append(contentsOf: pipeline.process(raw))
                }
            } else {
                frames.append(contentsOf: pipeline.process(raw))
            }
            if count < rawCapacity {
                break
            }
        }
        publish()
        return frames
    }

    // MARK: Internals

    private func applyRequests() {
        guard let processor else { return }
        if let change = control.parameters(after: parametersRevision) {
            parametersRevision = change.revision
            processor.setParameters(change.parameters ?? .passThrough)
        }
        if let seconds = control.takeCaptureRequest() {
            processor.beginNoiseCapture(seconds: seconds)
        }
    }

    /// Raw level (20 ms blocks, smoothed), peak hold and background noise.
    private func meter(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        let chunkPeakDb = SignalLevel.decibels(fromAmplitude: Double(peak))
        let chunkSeconds = Double(samples.count) / sampleRate
        peakAge += chunkSeconds
        if chunkPeakDb >= peakDb || peakAge > 1.5 {
            peakDb = chunkPeakDb
            peakAge = 0
        }
        var offset = 0
        while offset < samples.count {
            let take = min(blockLength - blockCount, samples.count - offset)
            var squares: Float = 0
            vDSP_svesq(base + offset, 1, &squares, vDSP_Length(take))
            blockSquares += Double(squares)
            blockCount += take
            offset += take
            if blockCount >= blockLength {
                let meanSquare = blockSquares / Double(blockCount)
                levelPower = levelPower * levelSmoothing + meanSquare * (1 - levelSmoothing)
                blockSquares = 0
                blockCount = 0
                segmentSquares += meanSquare
                segmentBlocks += 1
                if segmentBlocks >= Self.blocksPerSegment {
                    segmentLevels[segmentWriteIndex] = SignalLevel.decibels(fromAmplitude: (segmentSquares / Double(segmentBlocks)).squareRoot())
                    segmentWriteIndex = (segmentWriteIndex + 1) % Self.segmentCount
                    segmentFilled = min(segmentFilled + 1, Self.segmentCount)
                    segmentSquares = 0
                    segmentBlocks = 0
                }
            }
        }
        sinceProfilePublish += chunkSeconds
    }

    /// The quietest 100 ms of the last 2 seconds (nil before the first 100 ms).
    private var backgroundDb: Double? {
        guard segmentFilled > 0 else { return nil }
        var quietest = segmentLevels[0]
        for index in 1..<segmentFilled {
            quietest = min(quietest, segmentLevels[index])
        }
        return quietest
    }

    private func publish() {
        let processorStatus = processor?.status
        var status = ClearMicLiveStatus()
        status.inputLevelDb = SignalLevel.decibels(fromAmplitude: levelPower.squareRoot())
        status.peakDb = peakDb
        status.noiseFloorDb = backgroundDb
        status.isEnhancing = analyzesEnhanced
        status.isGateOpen = processorStatus?.isGateOpen ?? true
        status.isNoiseKnown = processorStatus?.isNoiseKnown ?? false
        status.captureProgress = processorStatus?.captureProgress
        status.latency = latency
        control.publish(status)

        guard let processor else { return }
        if let captured = processor.takeCapturedProfile() {
            var profile = captured
            profile.inputKind = inputKind
            control.publishCaptured(profile)
            sinceProfilePublish = 0
        } else if sinceProfilePublish >= 5, let learned = processor.noiseProfile(inputKind: inputKind) {
            // Occasionally hand the learned profile over for saving.
            control.publishLatest(learned)
            sinceProfilePublish = 0
        }
    }
}
