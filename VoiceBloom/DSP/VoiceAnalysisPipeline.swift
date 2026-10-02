import Foundation

/// The full per-frame chain used while listening:
///
///     samples → framer (2048/512) → level + noise gate → YIN → pitch tracker
///             → stability check → [stable frames] decimate → LPC formants → H1–H2 / tilt
///                                   [every 4th stable frame] jitter / shimmer / HNR
///             → phrase intonation
///
/// The pipeline is a plain, synchronous object so it can be unit-tested by
/// feeding it synthetic audio. In the app it runs inside a background task that
/// drains the capture ring buffer, so all DSP stays off the main thread.
/// Not thread-safe: own it from a single task.
nonisolated final class VoiceAnalysisPipeline {
    let configuration: AnalysisConfiguration
    /// How far (dB) above the noise floor a frame must be to count as voice.
    let gateMarginDb: Double
    /// Stable frames must also be this far (dB) above the gate, so formants
    /// and harmonics are measured with a healthy signal-to-noise ratio.
    let analysisMarginDb: Double

    private let startTime: Double
    private let pitchAnalyzer: PitchAnalyzer
    private let decimator: Decimator
    private let formantAnalyzer: FormantAnalyzer
    private let weightAnalyzer: WeightAnalyzer
    private let voiceQualityAnalyzer: VoiceQualityAnalyzer
    /// Frames between voice-quality measurements (frame size / hop = no overlap).
    private let voiceQualityInterval: Int
    private var lastVoiceQualityIndex = Int.min / 2
    private var tracker: PitchTracker
    private var stability = VoiceStabilityTracker()
    private var intonation: IntonationAnalyzer
    private var framer: SampleFramer
    private var noiseFloor: NoiseFloorEstimator
    private var readScratch: [Float]
    private var decimated: [Float]

    init(
        configuration: AnalysisConfiguration,
        startTime: Double = 0,
        noiseFloor: NoiseFloorEstimator = NoiseFloorEstimator(),
        gateMarginDb: Double = 8,
        analysisMarginDb: Double = 6,
        trackerConfiguration: PitchTrackerConfiguration = PitchTrackerConfiguration()
    ) {
        let decimator = Decimator(inputSampleRate: configuration.sampleRate)
        let decimatedLength = max(1, decimator.outputLength(forInputLength: configuration.frameSize))

        self.configuration = configuration
        self.startTime = startTime
        self.noiseFloor = noiseFloor
        self.gateMarginDb = gateMarginDb
        self.analysisMarginDb = analysisMarginDb
        self.decimator = decimator
        pitchAnalyzer = PitchAnalyzer(configuration: configuration)
        formantAnalyzer = FormantAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: decimatedLength)
        weightAnalyzer = WeightAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: decimatedLength)
        voiceQualityAnalyzer = VoiceQualityAnalyzer(sampleRate: configuration.sampleRate)
        voiceQualityInterval = max(1, configuration.frameSize / max(1, configuration.hopSize))
        tracker = PitchTracker(frameInterval: configuration.hopDuration, configuration: trackerConfiguration)
        intonation = IntonationAnalyzer(frameInterval: configuration.hopDuration)
        framer = SampleFramer(frameSize: configuration.frameSize, hopSize: configuration.hopSize)
        readScratch = [Float](repeating: 0, count: max(4096, configuration.hopSize * 8))
        decimated = [Float](repeating: 0, count: decimatedLength)
    }

    var noiseFloorDb: Double { noiseFloor.floorDb }

    /// Sample rate used for formant and weight analysis.
    var spectralSampleRate: Double { decimator.outputSampleRate }

    /// Analyzes every complete frame that the new samples make available.
    func process(_ samples: UnsafeBufferPointer<Float>) -> [VoiceFrame] {
        framer.append(samples)
        var frames: [VoiceFrame] = []
        framer.forEachFrame { frame, index in
            frames.append(self.analyze(frame, index: index))
        }
        return frames
    }

    func process(_ samples: [Float]) -> [VoiceFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Reads everything waiting in the ring buffer and analyzes it.
    func drain(_ ring: SampleRingBuffer) -> [VoiceFrame] {
        var frames: [VoiceFrame] = []
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

    private func analyze(_ frame: UnsafeBufferPointer<Float>, index: Int) -> VoiceFrame {
        let started = DispatchTime.now().uptimeNanoseconds

        // 1. Loudness and voice-activity gate: frames that are not clearly louder
        //    than the room are ignored, so background noise never draws a pitch.
        let levelDb = SignalLevel.decibels(fromAmplitude: SignalLevel.rms(frame))
        let peakDb = SignalLevel.decibels(fromAmplitude: SignalLevel.peak(frame))
        noiseFloor.update(levelDb: levelDb, elapsed: configuration.hopDuration)
        let gateThreshold = noiseFloor.floorDb + gateMarginDb
        let isLoudEnough = SignalLevel.isAboveGate(
            levelDb: levelDb,
            noiseFloorDb: noiseFloor.floorDb,
            marginDb: gateMarginDb
        )

        // 2. Raw pitch. Computed even for quiet frames so the debug screen can
        //    show what YIN "hears" below the gate.
        let estimate = pitchAnalyzer.estimate(frame)

        // 3. Octave-jump rejection, median filter, smoothing.
        let tracked = tracker.process(isLoudEnough ? estimate.frequency : nil)

        let status: VoiceFrameStatus
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

        // 4. Formants and vocal weight, on voiced, stable, clearly audible frames only.
        let usablePitch = status == .voiced && levelDb >= gateThreshold + analysisMarginDb
            ? tracked.filteredFrequency
            : nil
        let isStable = stability.process(usablePitch)
        var formants: FormantMeasurement?
        var weight: WeightMeasurement?
        if isStable, let fundamental = estimate.frequency ?? tracked.filteredFrequency {
            let written = decimated.withUnsafeMutableBufferPointer { output in
                decimator.decimate(frame, into: output)
            }
            if written > 0 {
                decimated.withUnsafeBufferPointer { buffer in
                    let spectralFrame = UnsafeBufferPointer(rebasing: buffer[0 ..< written])
                    formants = formantAnalyzer.analyze(spectralFrame)
                    weight = weightAnalyzer.analyze(spectralFrame, fundamental: fundamental, formants: formants)
                }
            }
        }

        // 5. Voice quality (jitter, shimmer, HNR) on non-overlapping stable frames,
        //    at the full sample rate for precise cycle timing.
        var voiceQuality: VoiceQualityMeasurement?
        if isStable, index - lastVoiceQualityIndex >= voiceQualityInterval,
           let fundamental = estimate.frequency ?? tracked.filteredFrequency {
            voiceQuality = voiceQualityAnalyzer.analyze(frame, fundamental: fundamental)
            lastVoiceQualityIndex = index
        }

        // 6. Intonation: phrases are split at pauses and summarized when they end.
        let completedPhrase = intonation.process(
            time: time,
            frequency: status == .voiced ? tracked.filteredFrequency : nil
        )

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        return VoiceFrame(
            time: time,
            status: status,
            rawFrequency: estimate.frequency,
            aperiodicity: estimate.aperiodicity,
            filteredFrequency: tracked.filteredFrequency,
            displayFrequency: tracked.displayFrequency,
            levelDb: levelDb,
            peakDb: peakDb,
            noiseFloorDb: noiseFloor.floorDb,
            gateThresholdDb: gateThreshold,
            isStable: isStable,
            formants: formants,
            weight: weight,
            voiceQuality: voiceQuality,
            completedPhrase: completedPhrase,
            processingDuration: elapsed
        )
    }
}
