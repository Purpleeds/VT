import Accelerate
import Foundation

// MARK: - Strength

/// How hard Clear Mic works (SPEC section 24.4).
nonisolated enum ClearMicStrength: String, CaseIterable, Identifiable, Sendable, Codable {
    case off
    case light
    case strong
    /// iOS voice processing (only offered after the System Mode Check passes).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .strong: "Strong"
        case .system: "System"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "The microphone exactly as it is."
        case .light:
            "Removes rumble and hum, quiets the room between words and gently reduces steady background noise. Readings stay as accurate as without it."
        case .strong:
            "Stronger noise reduction for loud places like cafés or traffic. Resonance readings may be slightly less precise."
        case .system:
            "iOS voice processing (echo and noise suppression), with automatic gain kept off. Experimental."
        }
    }

    var systemImage: String {
        switch self {
        case .off: "mic"
        case .light: "mic.and.signal.meter"
        case .strong: "mic.and.signal.meter.fill"
        case .system: "waveform.badge.mic"
        }
    }

    /// The processor settings for this strength; nil for Off.
    var parameters: ClearMicParameters? {
        switch self {
        case .off: nil
        case .light: .light
        case .strong: .strong
        case .system: .system
        }
    }
}

/// The processor's settings.
nonisolated struct ClearMicParameters: Sendable, Equatable, Codable {
    var highPass: Bool
    var noiseReduction: Bool
    /// Over-subtraction factor α (capped per strength).
    var overSubtraction: Float
    /// Spectral floor β: the lowest gain any bin gets (amplitude, 0…1).
    var spectralFloor: Float
    var gate: Bool
    /// The gate opens when a frame is this far above the room's noise floor.
    var gateMarginDb: Double
    /// How much the closed gate turns the sound down.
    var gateRangeDb: Double

    static let light = ClearMicParameters(
        highPass: true,
        noiseReduction: true,
        overSubtraction: 1.3,
        spectralFloor: Float(pow(10, -8.0 / 20)),
        gate: true,
        gateMarginDb: 6,
        gateRangeDb: 12
    )

    static let strong = ClearMicParameters(
        highPass: true,
        noiseReduction: true,
        overSubtraction: 2.2,
        spectralFloor: Float(pow(10, -16.5 / 20)),
        gate: true,
        gateMarginDb: 4,
        gateRangeDb: 24
    )

    /// iOS voice processing does the noise reduction.
    static let system = ClearMicParameters(
        highPass: true,
        noiseReduction: false,
        overSubtraction: 1,
        spectralFloor: 1,
        gate: true,
        gateMarginDb: 6,
        gateRangeDb: 12
    )

    /// Everything off: the output is the input, delayed.
    static let passThrough = ClearMicParameters(
        highPass: false,
        noiseReduction: false,
        overSubtraction: 1,
        spectralFloor: 1,
        gate: false,
        gateMarginDb: 6,
        gateRangeDb: 0
    )
}

// MARK: - High-pass filter

/// The 4th-order Butterworth high-pass (two biquads) at Clear Mic's constant
/// cutoff. Removes rumble, handling noise and mains hum without touching the
/// voice: −0.24 dB at 100 Hz, −6.5 dB at 60 Hz, −12 dB at 50 Hz.
nonisolated struct HighPassDesign: Sendable, Equatable {
    nonisolated struct Section: Sendable, Equatable {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
    }

    /// The constant cutoff (Hz): below the lowest voices, above rumble.
    static let cutoff = 70.0
    /// Q values of the two sections of a 4th-order Butterworth.
    static let qualityFactors = [0.541_196_100_146_197, 1.306_562_964_876_377]

    let sampleRate: Double
    let cutoff: Double
    let sections: [Section]

    init(sampleRate: Double, cutoff: Double = HighPassDesign.cutoff) {
        self.sampleRate = sampleRate
        self.cutoff = cutoff
        let omega = 2 * Double.pi * cutoff / max(sampleRate, 1)
        let cosine = cos(omega)
        let sine = sin(omega)
        sections = Self.qualityFactors.map { quality in
            // RBJ cookbook high-pass, normalized so a0 = 1.
            let alpha = sine / (2 * quality)
            let a0 = 1 + alpha
            return Section(
                b0: (1 + cosine) / 2 / a0,
                b1: -(1 + cosine) / a0,
                b2: (1 + cosine) / 2 / a0,
                a1: -2 * cosine / a0,
                a2: (1 - alpha) / a0
            )
        }
    }

    /// The filter's gain (dB, ≤ 0) at a frequency.
    func gainDb(at frequency: Double) -> Double {
        guard frequency > 0, sampleRate > 0 else { return -120 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(omega)
        let s1 = sin(omega)
        let c2 = cos(2 * omega)
        let s2 = sin(2 * omega)
        var magnitude = 1.0
        for section in sections {
            // H(e^jω) = (b0 + b1 e^−jω + b2 e^−2jω) / (1 + a1 e^−jω + a2 e^−2jω)
            let numeratorReal = section.b0 + section.b1 * c1 + section.b2 * c2
            let numeratorImag = -(section.b1 * s1 + section.b2 * s2)
            let denominatorReal = 1 + section.a1 * c1 + section.a2 * c2
            let denominatorImag = -(section.a1 * s1 + section.a2 * s2)
            let numerator = (numeratorReal * numeratorReal + numeratorImag * numeratorImag).squareRoot()
            let denominator = (denominatorReal * denominatorReal + denominatorImag * denominatorImag).squareRoot()
            guard denominator > 0 else { return 0 }
            magnitude *= numerator / denominator
        }
        return 20 * log10(max(magnitude, 1e-12))
    }
}

/// Running state of the high-pass filter (transposed direct form II, in
/// double precision: the poles sit very close to 1 at a 70 Hz cutoff).
nonisolated struct HighPassFilterState: Sendable {
    let design: HighPassDesign
    private var z1: (Double, Double) = (0, 0)
    private var z2: (Double, Double) = (0, 0)

    init(design: HighPassDesign) {
        self.design = design
    }

    mutating func reset() {
        z1 = (0, 0)
        z2 = (0, 0)
    }

    mutating func process(_ sample: Float) -> Float {
        var value = Double(sample)
        let first = design.sections[0]
        var output = first.b0 * value + z1.0
        z1.0 = first.b1 * value - first.a1 * output + z2.0
        z2.0 = first.b2 * value - first.a2 * output
        value = output
        let second = design.sections[1]
        output = second.b0 * value + z1.1
        z1.1 = second.b1 * value - second.a1 * output + z2.1
        z2.1 = second.b2 * value - second.a2 * output
        return Float(output)
    }

    /// Filters a whole signal (offline use).
    mutating func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            output[index] = process(samples[index])
        }
        return output
    }
}

// MARK: - Noise profile

/// The room's noise spectrum: average power per FFT bin (in the processor's
/// own units) and the broadband level. Only reused with the same sample rate
/// and FFT size, and only for the kind of microphone it was measured with.
nonisolated struct ClearMicNoiseProfile: Sendable, Equatable, Codable {
    var sampleRate: Double
    var fftSize: Int
    var bins: [Float]
    /// Mean frame level (dBFS) of the noise.
    var levelDb: Double
    var inputKind: AudioInputKind?
    var date: Date

    func matches(sampleRate rate: Double, fftSize size: Int) -> Bool {
        abs(sampleRate - rate) < 1 && fftSize == size && bins.count == size / 2 + 1
    }
}

/// What the processor knows after each frame.
nonisolated struct ClearMicFrameStatus: Sendable, Equatable {
    /// Frame level after the high-pass filter (dBFS).
    var levelDb: Double = SignalLevel.silenceDb
    /// Broadband noise floor estimate (dBFS); nil before the first frame.
    var noiseFloorDb: Double?
    var isGateOpen = true
    /// True once the background is known (sampled, saved or learned in a pause).
    var isNoiseKnown = false
    /// 0…1 while sampling room noise; nil otherwise.
    var captureProgress: Double?
}

// MARK: - Processor

/// The Clear Mic enhancer (SPEC section 24.3): a 70 Hz high-pass filter,
/// spectral subtraction with an over-subtraction limit and spectral floor,
/// a learned noise profile, and a smooth noise gate.
///
/// Streaming STFT: 1024-point frames (512 below 32 kHz), 50 % hop, square-root
/// periodic Hann windows on both sides, so with every stage off the output is
/// exactly the input delayed by `latencySamples` (half a frame). Phase is never
/// changed, and gains only ever reduce, so pitch and formants stay put.
///
/// Real-time safe: every buffer and the FFT setup are allocated in `init`;
/// `process(_:into:)` never allocates, locks or waits. Not thread-safe: one
/// thread at a time (the analysis task) uses it.
nonisolated final class ClearMicProcessor {
    /// Frames at least this far below the recent loudest frame prove what the
    /// background is (so a long vowel can't be mistaken for noise).
    static let quietGapDb = 10.0
    /// Frames within this much of the noise floor update the noise profile.
    static let noiseLikeMarginDb = 3.0
    /// The broadband noise floor rises at most this fast (dB per second)…
    static let floorRiseDbPerSecond = 2.0
    /// …and falls this fraction of the way per frame toward quieter frames.
    static let floorFallCoefficient = 0.3
    /// The recent-loudest level relaxes this fast (dB per second).
    static let peakDecayDbPerSecond = 3.0
    static let gateHold = 0.08
    static let gateAttack = 0.003
    static let gateRelease = 0.12
    /// Noise frames averaged when learning a profile from scratch.
    static let bootstrapFrames = 20
    static let minimumBootstrapFrames = 4

    let sampleRate: Double
    let fftSize: Int
    let hopSize: Int
    let binCount: Int
    let highPassDesign: HighPassDesign
    private(set) var parameters: ClearMicParameters
    private(set) var status = ClearMicFrameStatus()

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    /// The newest `fftSize` input samples (after the high-pass filter).
    private let inputFrame: UnsafeMutablePointer<Float>
    private let workFrame: UnsafeMutablePointer<Float>
    private let overlapAdd: UnsafeMutablePointer<Float>
    private let splitReal: UnsafeMutablePointer<Float>
    private let splitImag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let smoothedPower: UnsafeMutablePointer<Float>
    private let noise: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private let captureSum: UnsafeMutablePointer<Float>
    private var split: DSPSplitComplex
    private var highPass: HighPassFilterState
    private var fill = 0
    private var hasSmoothedPower = false
    private var floorDb: Double?
    private var recentMaxDb = -200.0
    private var isNoiseKnown = false
    private var bootstrapCount = 0
    private var gateGain: Float = 1
    private var holdRemaining = 0
    private let holdFrames: Int
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let hopDuration: Double
    // Room noise capture ("Sample Room Noise", or quiet frames of a recording).
    private var captureFramesLeft = 0
    private var captureFramesTotal = 0
    private var captureCount = 0
    private var captureLevelSum = 0.0
    private var captureMaximumLevelDb: Double?
    private(set) var capturedProfile: ClearMicNoiseProfile?
    /// Frames processed so far (the first one is partly the initial silence).
    private var framesProcessed = 0

    /// - Parameter profile: A saved noise profile to start from (ignored if
    ///   it was measured at another sample rate or FFT size).
    init?(sampleRate: Double, parameters: ClearMicParameters, profile: ClearMicNoiseProfile? = nil) {
        guard sampleRate >= 8_000 else { return nil }
        let size = ClearMicProcessor.fftSize(forSampleRate: sampleRate)
        let log2n = vDSP_Length(Int(log2(Double(size)).rounded()))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        fftSize = size
        hopSize = size / 2
        binCount = size / 2 + 1
        self.log2n = log2n
        fftSetup = setup
        self.parameters = parameters
        let design = HighPassDesign(sampleRate: sampleRate)
        highPassDesign = design
        highPass = HighPassFilterState(design: design)
        let hop = Double(size / 2) / sampleRate
        hopDuration = hop
        holdFrames = max(1, Int((ClearMicProcessor.gateHold / hop).rounded()))
        attackCoefficient = Float(exp(-1 / (ClearMicProcessor.gateAttack * sampleRate)))
        releaseCoefficient = Float(exp(-1 / (ClearMicProcessor.gateRelease * sampleRate)))

        func allocate(_ count: Int, value: Float = 0) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: value, count: count)
            return pointer
        }
        let real = allocate(size / 2)
        let imag = allocate(size / 2)
        window = allocate(size)
        inputFrame = allocate(size)
        workFrame = allocate(size)
        overlapAdd = allocate(size)
        splitReal = real
        splitImag = imag
        power = allocate(size / 2 + 1)
        smoothedPower = allocate(size / 2 + 1)
        noise = allocate(size / 2 + 1)
        gains = allocate(size / 2 + 1, value: 1)
        captureSum = allocate(size / 2 + 1)
        split = DSPSplitComplex(realp: real, imagp: imag)
        // Square-root periodic Hann: analysis × synthesis = Hann, which adds
        // up to exactly 1 at a 50 % hop.
        for index in 0..<size {
            window[index] = Float((0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(size))).squareRoot())
        }
        if let profile, profile.matches(sampleRate: sampleRate, fftSize: size) {
            for bin in 0..<binCount {
                noise[bin] = profile.bins[bin]
            }
            isNoiseKnown = true
            bootstrapCount = ClearMicProcessor.bootstrapFrames
            floorDb = profile.levelDb
            recentMaxDb = profile.levelDb
        }
        status.isNoiseKnown = isNoiseKnown
        status.noiseFloorDb = floorDb
    }

    deinit {
        for pointer in [window, inputFrame, workFrame, overlapAdd, splitReal, splitImag, power, smoothedPower, noise, gains, captureSum] {
            pointer.deallocate()
        }
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// The FFT size used at a sample rate (1024, or 512 below 32 kHz).
    static func fftSize(forSampleRate sampleRate: Double) -> Int {
        sampleRate >= 32_000 ? 1_024 : 512
    }

    /// Output lags input by this many samples (half a frame).
    var latencySamples: Int { fftSize - hopSize }
    var latency: Double { Double(latencySamples) / sampleRate }

    /// Changes the strength from the next frame on.
    func setParameters(_ newParameters: ClearMicParameters) {
        guard newParameters != parameters else { return }
        if newParameters.highPass != parameters.highPass {
            highPass.reset()
        }
        parameters = newParameters
    }

    /// Averages the next `seconds` of input into a new noise profile ("Sample
    /// Room Noise": the user stays quiet). The result replaces the profile.
    func beginNoiseCapture(seconds: Double) {
        captureFramesTotal = max(1, Int((seconds / hopDuration).rounded()))
        captureFramesLeft = captureFramesTotal
        captureMaximumLevelDb = nil
        resetCaptureSums()
    }

    /// Averages every frame at or below `maximumLevelDb` until `finishCapture()`
    /// (the quiet parts of a recording).
    func beginQuietFrameCapture(maximumLevelDb: Double) {
        captureFramesTotal = Int.max
        captureFramesLeft = Int.max
        captureMaximumLevelDb = maximumLevelDb
        resetCaptureSums()
    }

    /// Ends a quiet-frame capture.
    /// - Returns: The profile, or nil if no frame qualified.
    @discardableResult
    func finishCapture() -> ClearMicNoiseProfile? {
        captureFramesLeft = 0
        captureMaximumLevelDb = nil
        guard captureCount > 0 else { return nil }
        return completeCapture()
    }

    /// A finished "Sample Room Noise" capture, once.
    func takeCapturedProfile() -> ClearMicNoiseProfile? {
        let profile = capturedProfile
        capturedProfile = nil
        return profile
    }

    /// The current noise profile (copies it: call occasionally, not per block).
    func noiseProfile(inputKind: AudioInputKind?, date: Date = Date()) -> ClearMicNoiseProfile? {
        guard isNoiseKnown, let floorDb else { return nil }
        let bins = Array(UnsafeBufferPointer(start: noise, count: binCount))
        return ClearMicNoiseProfile(sampleRate: sampleRate, fftSize: fftSize, bins: bins, levelDb: floorDb, inputKind: inputKind, date: date)
    }

    /// Enhances `input` into `output`, which must hold at least
    /// `input.count + hopSize` samples. Output comes in whole hops, so the
    /// number written varies from call to call.
    /// - Returns: The number of samples written.
    func process(_ input: UnsafeBufferPointer<Float>, into output: UnsafeMutablePointer<Float>) -> Int {
        var written = 0
        let tail = fftSize - hopSize
        for sample in input {
            let filtered = parameters.highPass ? highPass.process(sample) : sample
            inputFrame[tail + fill] = filtered
            fill += 1
            if fill == hopSize {
                processFrame(into: output + written)
                written += hopSize
                fill = 0
            }
        }
        return written
    }

    /// Convenience for offline use and tests (allocates).
    func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count + hopSize)
        let written = samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                return process(input, into: base)
            }
        }
        return Array(output.prefix(written))
    }

    // MARK: One frame

    private func processFrame(into output: UnsafeMutablePointer<Float>) {
        let n = fftSize
        let half = n / 2

        // Level and the broadband noise floor.
        var meanSquare: Float = 0
        vDSP_measqv(inputFrame, 1, &meanSquare, vDSP_Length(n))
        let levelDb = meanSquare > 0 ? max(SignalLevel.silenceDb, 10 * log10(Double(meanSquare))) : SignalLevel.silenceDb
        if let current = floorDb {
            if levelDb < current {
                floorDb = current + (levelDb - current) * Self.floorFallCoefficient
            } else {
                floorDb = min(levelDb, current + Self.floorRiseDbPerSecond * hopDuration)
            }
        } else {
            floorDb = levelDb
        }
        recentMaxDb = max(levelDb, recentMaxDb - Self.peakDecayDbPerSecond * hopDuration)
        let floor = floorDb ?? levelDb
        let isNoiseLike = levelDb <= floor + Self.noiseLikeMarginDb && levelDb <= recentMaxDb - Self.quietGapDb

        // Spectrum of the windowed frame.
        vDSP_vmul(inputFrame, 1, window, 1, workFrame, 1, vDSP_Length(n))
        workFrame.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        // vDSP packs DC in real[0] and Nyquist in imag[0].
        power[0] = splitReal[0] * splitReal[0]
        power[half] = splitImag[0] * splitImag[0]
        for bin in 1..<half {
            power[bin] = splitReal[bin] * splitReal[bin] + splitImag[bin] * splitImag[bin]
        }
        if hasSmoothedPower {
            for bin in 0..<binCount {
                smoothedPower[bin] = 0.5 * smoothedPower[bin] + 0.5 * power[bin]
            }
        } else {
            for bin in 0..<binCount {
                smoothedPower[bin] = power[bin]
            }
            hasSmoothedPower = true
        }

        updateNoise(levelDb: levelDb, isNoiseLike: isNoiseLike)

        // Spectral subtraction: gain = √max(0, 1 − α·N/P), floored at β,
        // rising at once but falling smoothly (no "musical noise").
        if parameters.noiseReduction, isNoiseKnown {
            let alpha = parameters.overSubtraction
            let floorGain = parameters.spectralFloor
            for bin in 0..<binCount {
                let estimate = max(smoothedPower[bin], 1e-30)
                var gain = (max(0, 1 - alpha * noise[bin] / estimate)).squareRoot()
                gain = max(gain, floorGain)
                let previous = gains[bin]
                if gain < previous {
                    gain = 0.6 * previous + 0.4 * gain
                }
                gains[bin] = gain
            }
            splitReal[0] *= gains[0]
            splitImag[0] *= gains[half]
            for bin in 1..<half {
                splitReal[bin] *= gains[bin]
                splitImag[bin] *= gains[bin]
            }
        } else {
            for bin in 0..<binCount {
                gains[bin] = 1
            }
        }

        // Back to time, synthesis window, overlap-add. vDSP's forward real FFT
        // is 2× the DFT and its inverse is n× the inverse DFT, so scale 1/(2n).
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        workFrame.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(half))
        }
        var scale = 1 / Float(2 * n)
        vDSP_vsmul(workFrame, 1, &scale, workFrame, 1, vDSP_Length(n))
        vDSP_vmul(workFrame, 1, window, 1, workFrame, 1, vDSP_Length(n))
        vDSP_vadd(overlapAdd, 1, workFrame, 1, overlapAdd, 1, vDSP_Length(n))

        // The gate: decided on this frame (one hop ahead of the samples it
        // shapes), applied sample by sample with smooth attack and release.
        var target: Float = 1
        if parameters.gate, isNoiseKnown {
            if levelDb - floor >= parameters.gateMarginDb {
                holdRemaining = holdFrames
            } else if holdRemaining > 0 {
                holdRemaining -= 1
            } else {
                target = Float(pow(10, -parameters.gateRangeDb / 20))
            }
        }
        for index in 0..<hopSize {
            let coefficient = target > gateGain ? attackCoefficient : releaseCoefficient
            gateGain = target + (gateGain - target) * coefficient
            output[index] = overlapAdd[index] * gateGain
        }

        // Slide the buffers by one hop.
        let tail = n - hopSize
        (overlapAdd).update(from: overlapAdd + hopSize, count: tail)
        (overlapAdd + tail).update(repeating: 0, count: hopSize)
        (inputFrame).update(from: inputFrame + hopSize, count: tail)

        status.levelDb = levelDb
        status.noiseFloorDb = floorDb
        status.isGateOpen = target >= 1
        status.isNoiseKnown = isNoiseKnown
        status.captureProgress = captureFramesLeft > 0 && captureFramesTotal != Int.max
            ? 1 - Double(captureFramesLeft) / Double(max(captureFramesTotal, 1))
            : nil
    }

    private func updateNoise(levelDb: Double, isNoiseLike: Bool) {
        framesProcessed += 1
        if captureFramesLeft > 0 {
            // The first frame still holds the buffer's initial silence.
            let isFilled = framesProcessed * hopSize >= fftSize
            let qualifies = isFilled && (captureMaximumLevelDb.map { levelDb <= $0 } ?? true)
            if qualifies {
                for bin in 0..<binCount {
                    captureSum[bin] += power[bin]
                }
                captureLevelSum += pow(10, levelDb / 10)
                captureCount += 1
            }
            if captureFramesTotal != Int.max {
                captureFramesLeft -= 1
                if captureFramesLeft == 0, captureCount > 0 {
                    capturedProfile = completeCapture()
                }
            }
            return
        }

        if isNoiseLike {
            if bootstrapCount < Self.bootstrapFrames {
                bootstrapCount += 1
                let weight = 1 / Float(bootstrapCount)
                for bin in 0..<binCount {
                    noise[bin] += (smoothedPower[bin] - noise[bin]) * weight
                }
                if bootstrapCount >= Self.minimumBootstrapFrames {
                    isNoiseKnown = true
                }
            } else {
                // Slow rise toward louder background.
                for bin in 0..<binCount where smoothedPower[bin] > noise[bin] {
                    noise[bin] = 0.98 * noise[bin] + 0.02 * smoothedPower[bin]
                }
            }
        }
        if isNoiseKnown {
            // Fast fall whenever a bin is quieter than the profile.
            for bin in 0..<binCount where smoothedPower[bin] < noise[bin] {
                noise[bin] = 0.7 * noise[bin] + 0.3 * smoothedPower[bin]
            }
        }
    }

    private func resetCaptureSums() {
        captureSum.update(repeating: 0, count: binCount)
        captureLevelSum = 0
        captureCount = 0
        capturedProfile = nil
    }

    /// Replaces the profile with the captured average.
    private func completeCapture() -> ClearMicNoiseProfile? {
        guard captureCount > 0 else { return nil }
        let scale = 1 / Float(captureCount)
        for bin in 0..<binCount {
            noise[bin] = captureSum[bin] * scale
        }
        let level = 10 * log10(max(captureLevelSum / Double(captureCount), 1e-20))
        floorDb = level
        recentMaxDb = max(recentMaxDb, level)
        isNoiseKnown = true
        bootstrapCount = Self.bootstrapFrames
        captureFramesLeft = 0
        let bins = Array(UnsafeBufferPointer(start: noise, count: binCount))
        return ClearMicNoiseProfile(sampleRate: sampleRate, fftSize: fftSize, bins: bins, levelDb: level, inputKind: nil, date: Date())
    }
}

// MARK: - Offline enhancement

/// Enhances a saved recording on the fly (SPEC section 24.7): the noise
/// profile comes from the recording's own quietest frames, the output has the
/// same length and timing as the input, and the file itself is never changed.
nonisolated enum ClearMicOffline {
    /// Share of the quietest frames treated as background.
    static let quietFraction = 0.15

    /// - Parameter knownProfile: A room profile to use instead of estimating
    ///   one from the quiet parts (e.g. the live one, for the Mic Check A/B test).
    static func enhance(_ samples: [Float], sampleRate: Double, parameters: ClearMicParameters, knownProfile: ClearMicNoiseProfile? = nil) -> [Float] {
        guard !samples.isEmpty,
              let probe = ClearMicProcessor(sampleRate: sampleRate, parameters: .passThrough)
        else { return samples }
        let size = probe.fftSize
        if let knownProfile, knownProfile.matches(sampleRate: sampleRate, fftSize: size) {
            return process(samples, sampleRate: sampleRate, parameters: parameters, profile: knownProfile)
        }
        let hop = probe.hopSize

        // 1. Frame levels after the high-pass filter, to find the quiet ones.
        var filter = HighPassFilterState(design: probe.highPassDesign)
        let filtered = parameters.highPass ? filter.process(samples) : samples
        var levels: [Double] = []
        var start = 0
        while start + size <= filtered.count {
            let level = filtered[start..<(start + size)].withUnsafeBufferPointer { buffer -> Double in
                guard let base = buffer.baseAddress else { return SignalLevel.silenceDb }
                var meanSquare: Float = 0
                vDSP_measqv(base, 1, &meanSquare, vDSP_Length(size))
                return meanSquare > 0 ? 10 * log10(Double(meanSquare)) : SignalLevel.silenceDb
            }
            levels.append(level)
            start += hop
        }
        let sorted = levels.sorted()
        let threshold = sorted.isEmpty
            ? SignalLevel.silenceDb
            : sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * quietFraction) - 1))]

        // 2. Average the quiet frames into a profile.
        var profile: ClearMicNoiseProfile?
        if let capture = ClearMicProcessor(sampleRate: sampleRate, parameters: ClearMicParameters(
            highPass: parameters.highPass,
            noiseReduction: false,
            overSubtraction: 1,
            spectralFloor: 1,
            gate: false,
            gateMarginDb: 6,
            gateRangeDb: 0
        )) {
            capture.beginQuietFrameCapture(maximumLevelDb: threshold + 0.01)
            _ = capture.process(samples)
            profile = capture.finishCapture()
        }

        // 3. Process with that profile.
        return process(samples, sampleRate: sampleRate, parameters: parameters, profile: profile)
    }

    /// Runs the processor over the whole signal, then drops its latency so the
    /// output lines up with the input and has the same length.
    static func process(_ samples: [Float], sampleRate: Double, parameters: ClearMicParameters, profile: ClearMicNoiseProfile?) -> [Float] {
        guard let processor = ClearMicProcessor(sampleRate: sampleRate, parameters: parameters, profile: profile) else { return samples }
        let output = processor.process(samples + [Float](repeating: 0, count: processor.fftSize))
        let latency = processor.latencySamples
        guard output.count > latency else { return samples }
        let aligned = Array(output[latency...].prefix(samples.count))
        return aligned.count == samples.count ? aligned : aligned + [Float](repeating: 0, count: samples.count - aligned.count)
    }

    /// The parameters for offline use: Off and System use Light's processing
    /// (System mode only exists live).
    static func parameters(for strength: ClearMicStrength) -> ClearMicParameters {
        switch strength {
        case .strong: .strong
        case .off, .light, .system: .light
        }
    }

    static func enhance(_ clip: AudioClip, strength: ClearMicStrength, knownProfile: ClearMicNoiseProfile? = nil) -> AudioClip {
        AudioClip(
            samples: enhance(clip.samples, sampleRate: clip.sampleRate, parameters: parameters(for: strength), knownProfile: knownProfile),
            sampleRate: clip.sampleRate,
            startTime: clip.startTime
        )
    }
}
