import Foundation

/// The full per-frame chain used while listening:
///
///     samples → framer (2048/512) → level + noise gate → YIN → tracker → PitchFrame
///
/// The pipeline is a plain, synchronous object so it can be unit-tested by
/// feeding it synthetic audio. In the app it runs inside a background task that
/// drains the capture ring buffer, so all DSP stays off the main thread.
/// Not thread-safe: own it from a single task.
nonisolated final class LivePitchPipeline {
    let configuration: AnalysisConfiguration
    /// How far (dB) above the noise floor a frame must be to count as voice.
    let gateMarginDb: Double

    private let startTime: Double
    private let analyzer: PitchAnalyzer
    private var tracker: PitchTracker
    private var framer: SampleFramer
    private var noiseFloor: NoiseFloorEstimator
    private var readScratch: [Float]

    init(
        configuration: AnalysisConfiguration,
        startTime: Double = 0,
        noiseFloor: NoiseFloorEstimator = NoiseFloorEstimator(),
        gateMarginDb: Double = 8,
        trackerConfiguration: PitchTrackerConfiguration = PitchTrackerConfiguration()
    ) {
        self.configuration = configuration
        self.startTime = startTime
        self.noiseFloor = noiseFloor
        self.gateMarginDb = gateMarginDb
        analyzer = PitchAnalyzer(configuration: configuration)
        tracker = PitchTracker(frameInterval: configuration.hopDuration, configuration: trackerConfiguration)
        framer = SampleFramer(frameSize: configuration.frameSize, hopSize: configuration.hopSize)
        readScratch = [Float](repeating: 0, count: max(4096, configuration.hopSize * 8))
    }

    var noiseFloorDb: Double { noiseFloor.floorDb }

    /// Analyzes every complete frame that the new samples make available.
    func process(_ samples: UnsafeBufferPointer<Float>) -> [PitchFrame] {
        framer.append(samples)
        var frames: [PitchFrame] = []
        framer.forEachFrame { frame, index in
            frames.append(self.analyze(frame, index: index))
        }
        return frames
    }

    func process(_ samples: [Float]) -> [PitchFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Reads everything waiting in the ring buffer and analyzes it.
    func drain(_ ring: SampleRingBuffer) -> [PitchFrame] {
        var frames: [PitchFrame] = []
        while true {
            let count = readScratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            guard count > 0 else { break }
            let produced = readScratch.withUnsafeBufferPointer { buffer in
                process(UnsafeBufferPointer(rebasing: buffer[0 ..< count]))
            }
            frames.append(contentsOf: produced)
            if count < readScratch.count {
                break
            }
        }
        return frames
    }

    private func analyze(_ frame: UnsafeBufferPointer<Float>, index: Int) -> PitchFrame {
        let started = DispatchTime.now().uptimeNanoseconds

        // 1. Loudness and voice-activity gate: frames that are not clearly louder
        //    than the room are ignored, so background noise never draws a pitch.
        let levelDb = SignalLevel.decibels(fromAmplitude: SignalLevel.rms(frame))
        noiseFloor.update(levelDb: levelDb, elapsed: configuration.hopDuration)
        let gateThreshold = noiseFloor.floorDb + gateMarginDb
        let isLoudEnough = SignalLevel.isAboveGate(
            levelDb: levelDb,
            noiseFloorDb: noiseFloor.floorDb,
            marginDb: gateMarginDb
        )

        // 2. Raw pitch. Computed even for quiet frames so the debug screen can
        //    show what YIN "hears" below the gate.
        let estimate = analyzer.estimate(frame)

        // 3. Octave-jump rejection, median filter, smoothing.
        let tracked = tracker.process(isLoudEnough ? estimate.frequency : nil)

        let status: PitchFrameStatus
        if !isLoudEnough {
            status = .belowNoiseGate
        } else {
            switch tracked.status {
            case .voiced: status = .voiced
            case .unvoiced: status = .unpitched
            case .octaveJumpHeld: status = .octaveJumpHeld
            }
        }

        // Timestamp the centre of the frame.
        let frameStart = Double(index * configuration.hopSize)
        let time = startTime + (frameStart + Double(configuration.frameSize) / 2) / configuration.sampleRate
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        return PitchFrame(
            time: time,
            status: status,
            rawFrequency: estimate.frequency,
            aperiodicity: estimate.aperiodicity,
            filteredFrequency: tracked.filteredFrequency,
            displayFrequency: tracked.displayFrequency,
            levelDb: levelDb,
            noiseFloorDb: noiseFloor.floorDb,
            gateThresholdDb: gateThreshold,
            processingDuration: elapsed
        )
    }
}
