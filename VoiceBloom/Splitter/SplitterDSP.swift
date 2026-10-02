import Accelerate
import Foundation

// MARK: - Buffers

/// Two channels of audio. Mono material is stored with both channels equal.
nonisolated struct StereoBuffer: Sendable, Equatable {
    var left: [Float]
    var right: [Float]

    static let empty = StereoBuffer(left: [], right: [])

    init(left: [Float], right: [Float]) {
        let count = min(left.count, right.count)
        self.left = left.count == count ? left : Array(left.prefix(count))
        self.right = right.count == count ? right : Array(right.prefix(count))
    }

    init(mono: [Float]) {
        left = mono
        right = mono
    }

    var count: Int { left.count }
    var isEmpty: Bool { left.isEmpty }

    /// (left + right) / 2.
    var mid: [Float] {
        guard !isEmpty else { return [] }
        return vDSP.multiply(0.5, vDSP.add(left, right))
    }

    /// (left − right) / 2.
    var side: [Float] {
        guard !isEmpty else { return [] }
        return vDSP.multiply(0.5, vDSP.subtract(left, right))
    }

    func prefix(_ length: Int) -> StereoBuffer {
        let end = min(max(0, length), count)
        return StereoBuffer(left: Array(left[0..<end]), right: Array(right[0..<end]))
    }

    mutating func append(_ other: StereoBuffer) {
        left.append(contentsOf: other.left)
        right.append(contentsOf: other.right)
    }

    mutating func removeFirst(_ length: Int) {
        let amount = min(max(0, length), count)
        left.removeFirst(amount)
        right.removeFirst(amount)
    }

    /// Both channels multiplied by `gain`.
    func scaled(by gain: Float) -> StereoBuffer {
        guard !isEmpty else { return self }
        return StereoBuffer(left: vDSP.multiply(gain, left), right: vDSP.multiply(gain, right))
    }
}

/// The two parts a separation produces. Vocals + backing add up to the
/// original (both engines split with complementary masks).
nonisolated struct StemPair: Sendable, Equatable {
    var vocals: StereoBuffer
    var backing: StereoBuffer
}

// MARK: - Short-time Fourier transform

/// Hann-windowed STFT and its inverse (weighted overlap-add), built on
/// vDSP's real FFT. Frames are centred: the signal is padded by half a frame
/// on each side, so the inverse returns exactly the input when nothing is
/// changed. Not thread-safe: use one instance per task.
nonisolated final class SpectralTransform {
    /// Spectra for every frame, frame-major: bin `k` of frame `t` is at
    /// `t * bins + k`. Values are the true DFT (no vDSP factor of 2).
    nonisolated struct Spectrum: Sendable {
        var real: [Float]
        var imag: [Float]
        let frames: Int
        let bins: Int
    }

    let fftSize: Int
    let hopSize: Int
    let binCount: Int
    let window: [Float]
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// - Parameter fftSize: A power of two (at least 16).
    init?(fftSize: Int = 2048, hopSize: Int = 512) {
        guard fftSize >= 16, fftSize & (fftSize - 1) == 0, hopSize > 0, hopSize <= fftSize / 2 else { return nil }
        let log2n = vDSP_Length(Int(log2(Double(fftSize)).rounded()))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.binCount = fftSize / 2 + 1
        self.log2n = log2n
        self.setup = setup
        // Periodic Hann, so overlapping windows add up to a constant.
        window = (0..<fftSize).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(fftSize)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Centre frequency (Hz) of bin `k`.
    func frequency(ofBin bin: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(fftSize)
    }

    func frameCount(forLength length: Int) -> Int {
        length / hopSize + 1
    }

    func forward(_ signal: [Float]) -> Spectrum {
        let n = fftSize
        let half = n / 2
        let frames = frameCount(forLength: signal.count)
        // Half a frame of silence before, and enough after for the last frame.
        var padded = [Float](repeating: 0, count: signal.count + n + hopSize)
        padded.replaceSubrange(half..<(half + signal.count), with: signal)

        var real = [Float](repeating: 0, count: frames * binCount)
        var imag = [Float](repeating: 0, count: frames * binCount)
        var frame = [Float](repeating: 0, count: n)
        var splitReal = [Float](repeating: 0, count: half)
        var splitImag = [Float](repeating: 0, count: half)

        for index in 0..<frames {
            let start = index * hopSize
            vDSP.multiply(padded[start..<(start + n)], window, result: &frame)
            transformFrame(&frame, real: &splitReal, imag: &splitImag)
            // vDSP packs the Nyquist bin into imag[0] and scales by 2.
            let base = index * binCount
            real[base] = splitReal[0] * 0.5
            imag[base] = 0
            real[base + half] = splitImag[0] * 0.5
            imag[base + half] = 0
            for bin in 1..<half {
                real[base + bin] = splitReal[bin] * 0.5
                imag[base + bin] = splitImag[bin] * 0.5
            }
        }
        return Spectrum(real: real, imag: imag, frames: frames, bins: binCount)
    }

    /// Weighted overlap-add back to `length` samples.
    func inverse(_ spectrum: Spectrum, length: Int) -> [Float] {
        let n = fftSize
        let half = n / 2
        guard spectrum.bins == binCount, length > 0 else { return [Float](repeating: 0, count: max(0, length)) }
        var output = [Float](repeating: 0, count: length + n + hopSize + spectrum.frames * hopSize)
        var weights = [Float](repeating: 0, count: output.count)
        var frame = [Float](repeating: 0, count: n)
        var splitReal = [Float](repeating: 0, count: half)
        var splitImag = [Float](repeating: 0, count: half)
        let windowSquared = vDSP.multiply(window, window)
        let scale = 1 / Float(n)

        for index in 0..<spectrum.frames {
            let base = index * binCount
            splitReal[0] = spectrum.real[base]
            splitImag[0] = spectrum.real[base + half]
            for bin in 1..<half {
                splitReal[bin] = spectrum.real[base + bin]
                splitImag[bin] = spectrum.imag[base + bin]
            }
            inverseFrame(&frame, real: &splitReal, imag: &splitImag)
            let start = index * hopSize
            for sample in 0..<n {
                output[start + sample] += frame[sample] * scale * window[sample]
                weights[start + sample] += windowSquared[sample]
            }
        }
        var result = [Float](repeating: 0, count: length)
        for sample in 0..<length {
            let weight = weights[sample + half]
            result[sample] = weight > 1e-6 ? output[sample + half] / weight : 0
        }
        return result
    }

    private func transformFrame(_ frame: inout [Float], real: inout [Float], imag: inout [Float]) {
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress, let imagBase = imagBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                frame.withUnsafeBufferPointer { frameBuffer in
                    guard let frameBase = frameBuffer.baseAddress else { return }
                    frameBase.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func inverseFrame(_ frame: inout [Float], real: inout [Float], imag: inout [Float]) {
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress, let imagBase = imagBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                frame.withUnsafeMutableBufferPointer { frameBuffer in
                    guard let frameBase = frameBuffer.baseAddress else { return }
                    frameBase.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(half))
                    }
                }
            }
        }
    }
}

// MARK: - Basic engine (center cancellation)

/// The Basic engine (SPEC section 23.1): no model, stereo only.
///
/// Studio mixes usually put the lead vocal in the centre (equal in both
/// channels) and spread instruments to the sides. For every time–frequency
/// bin we compare the mid signal (L+R)/2 with the side signal (L−R)/2:
/// - a centred sound has no side, so its "centredness" is 1;
/// - a sound panned hard left or right has |mid| = |side|, so it's 0.
/// The vocal mask is centredness² limited to the voice band (~100 Hz–8 kHz).
/// Vocals = mask × mid, and the backing is the original minus the vocals
/// in each channel: that is center cancellation, the stereo image of the
/// instruments is kept, and everything below the voice band (bass, kick
/// drum) stays in the backing, which is the low-frequency restore.
nonisolated final class BasicSeparationEngine: SeparationService {
    let kind = SeparationEngineKind.basic
    let chunkDuration = 10.0
    let overlapDuration = 1.0
    /// Voice band edges (Hz): fully passed between the inner pair.
    static let lowCut = 80.0
    static let lowFull = 120.0
    static let highFull = 7_000.0
    static let highCut = 9_000.0

    private let transform: SpectralTransform
    private var cachedBandWeights: [Float] = []
    private var bandSampleRate = 0.0

    init?() {
        guard let transform = SpectralTransform(fftSize: 2048, hopSize: 512) else { return nil }
        self.transform = transform
    }

    func separate(_ chunk: StereoBuffer, sampleRate: Double, quality: SeparationQuality) throws -> StemPair {
        guard !chunk.isEmpty else { return StemPair(vocals: .empty, backing: .empty) }
        let mid = chunk.mid
        let side = chunk.side
        var midSpectrum = transform.forward(mid)
        let sideSpectrum = transform.forward(side)
        let weights = bandWeights(sampleRate: sampleRate)

        let bins = midSpectrum.bins
        for frame in 0..<midSpectrum.frames {
            let base = frame * bins
            for bin in 0..<bins {
                let index = base + bin
                let weight = weights[bin]
                guard weight > 0 else {
                    midSpectrum.real[index] = 0
                    midSpectrum.imag[index] = 0
                    continue
                }
                let midMagnitude = hypot(midSpectrum.real[index], midSpectrum.imag[index])
                let sideMagnitude = hypot(sideSpectrum.real[index], sideSpectrum.imag[index])
                let centred = max(midMagnitude - sideMagnitude, 0) / (midMagnitude + 1e-9)
                let mask = centred * centred * weight
                midSpectrum.real[index] *= mask
                midSpectrum.imag[index] *= mask
            }
        }

        let vocals = transform.inverse(midSpectrum, length: chunk.count)
        let backing = StereoBuffer(left: vDSP.subtract(chunk.left, vocals), right: vDSP.subtract(chunk.right, vocals))
        return StemPair(vocals: StereoBuffer(mono: vocals), backing: backing)
    }

    /// 0…1 per bin: the vocal band with smooth edges.
    private func bandWeights(sampleRate: Double) -> [Float] {
        if sampleRate == bandSampleRate, !cachedBandWeights.isEmpty {
            return cachedBandWeights
        }
        cachedBandWeights = (0..<transform.binCount).map { bin in
            Float(Self.bandWeight(frequency: transform.frequency(ofBin: bin, sampleRate: sampleRate)))
        }
        bandSampleRate = sampleRate
        return cachedBandWeights
    }

    static func bandWeight(frequency: Double) -> Double {
        let rise = min(max((frequency - lowCut) / (lowFull - lowCut), 0), 1)
        let fall = min(max((highCut - frequency) / (highCut - highFull), 0), 1)
        return rise * fall
    }
}

// MARK: - Vocal clean-up

/// Optional clean-up for separated vocals (SPEC section 23.2).
nonisolated struct CleanupOptions: Sendable, Equatable, Codable {
    var noiseGate = false
    var deReverb = false

    var isEmpty: Bool { !noiseGate && !deReverb }
}

nonisolated enum VocalCleanup {
    /// The gate closes to this gain (−20 dB): quiet, not silent.
    static let gateFloor: Float = 0.1

    static func apply(_ buffer: StereoBuffer, options: CleanupOptions, sampleRate: Double, transform: SpectralTransform?) -> StereoBuffer {
        guard !options.isEmpty, !buffer.isEmpty else { return buffer }
        var result = buffer
        if options.deReverb, let transform {
            result = StereoBuffer(
                left: deReverb(result.left, sampleRate: sampleRate, transform: transform),
                right: deReverb(result.right, sampleRate: sampleRate, transform: transform)
            )
        }
        if options.noiseGate {
            // One gain for both channels (from the mid), so the image stays put.
            let gains = gateGains(result.mid, sampleRate: sampleRate)
            result = StereoBuffer(left: vDSP.multiply(result.left, gains), right: vDSP.multiply(result.right, gains))
        }
        return result
    }

    /// Noise gate: the threshold sits 10 dB (or 30 % of the dynamic range)
    /// above the quietest 10 % of 20 ms frames. A power envelope (5 ms
    /// attack, 15 ms release) opens the gate; the gain itself moves smoothly
    /// (2 ms open, 60 ms close) so there are no clicks.
    static func gateGains(_ signal: [Float], sampleRate: Double) -> [Float] {
        guard !signal.isEmpty, sampleRate > 0 else { return [] }
        let frameLength = max(1, Int(0.02 * sampleRate))
        var levels: [Double] = []
        var start = 0
        while start + frameLength <= signal.count {
            var sum = 0.0
            for index in start..<(start + frameLength) {
                sum += Double(signal[index]) * Double(signal[index])
            }
            levels.append(10 * log10(sum / Double(frameLength) + 1e-12))
            start += frameLength
        }
        guard levels.count >= 5 else { return [Float](repeating: 1, count: signal.count) }
        let sorted = levels.sorted()
        let noise = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let threshold = noise + max(10, (loud - noise) * 0.3)

        let attack = exp(-1 / (0.005 * sampleRate))
        let release = exp(-1 / (0.015 * sampleRate))
        let open = exp(-1 / (0.002 * sampleRate))
        let close = exp(-1 / (0.06 * sampleRate))
        var envelope = 0.0
        var gain = 1.0
        var gains = [Float](repeating: 1, count: signal.count)
        for index in signal.indices {
            let power = Double(signal[index]) * Double(signal[index])
            let coefficient = power > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * power
            let target = 10 * log10(envelope + 1e-12) > threshold ? 1.0 : Double(gateFloor)
            let smoothing = target > gain ? open : close
            gain = smoothing * gain + (1 - smoothing) * target
            gains[index] = Float(gain)
        }
        return gains
    }

    /// Light de-reverb by late-reverb suppression: the reverb in each
    /// time–frequency bin is predicted from the power 50 ms earlier, decayed
    /// for a 0.5 s room and assumed to be half the sound; that share is
    /// subtracted (gain never below 0.3, so it stays natural).
    static func deReverb(_ signal: [Float], sampleRate: Double, transform: SpectralTransform) -> [Float] {
        guard signal.count > transform.fftSize, sampleRate > 0 else { return signal }
        var spectrum = transform.forward(signal)
        let bins = spectrum.bins
        let delayFrames = max(1, Int((0.05 * sampleRate / Double(transform.hopSize)).rounded()))
        let reverbTime = 0.5
        let decay = Float(0.5 * exp(-13.8 * Double(delayFrames * transform.hopSize) / sampleRate / reverbTime))
        var power = [Float](repeating: 0, count: spectrum.real.count)
        for index in power.indices {
            power[index] = spectrum.real[index] * spectrum.real[index] + spectrum.imag[index] * spectrum.imag[index]
        }
        guard spectrum.frames > delayFrames else { return signal }
        for frame in delayFrames..<spectrum.frames {
            let base = frame * bins
            let earlier = (frame - delayFrames) * bins
            for bin in 0..<bins {
                let current = power[base + bin]
                let gain = max(1 - decay * power[earlier + bin] / (current + 1e-12), 0.3)
                spectrum.real[base + bin] *= gain
                spectrum.imag[base + bin] *= gain
            }
        }
        return transform.inverse(spectrum, length: signal.count)
    }
}

// MARK: - Source checks

/// Quick checks on a source before splitting (SPEC section 23.2).
nonisolated struct SplitAssessment: Sendable, Equatable {
    /// Side energy relative to mid (dB). Very low means the channels are the same.
    let sideToMidDb: Double
    /// Share of 50 ms frames that are pauses (30 dB below the loud parts).
    let pauseShare: Double
    /// Loudest sample (dBFS).
    let peakDb: Double

    /// Mono, or two identical channels: the Basic engine can't split it.
    var isMono: Bool { sideToMidDb < -40 }
    var isSilent: Bool { peakDb < -60 }
    /// Pauses and a near-mono image sound like plain speech, not music.
    var isLikelySpeechOnly: Bool { !isSilent && pauseShare >= 0.08 && sideToMidDb < -25 }

    static func assess(_ buffer: StereoBuffer, sampleRate: Double) -> SplitAssessment {
        guard !buffer.isEmpty, sampleRate > 0 else {
            return SplitAssessment(sideToMidDb: -120, pauseShare: 1, peakDb: -120)
        }
        let mid = buffer.mid
        let side = buffer.side
        let midPower = Double(vDSP.sumOfSquares(mid))
        let sidePower = Double(vDSP.sumOfSquares(side))
        let ratio = midPower > 1e-12 ? 10 * log10(max(sidePower, 1e-20) / midPower) : -120
        let peak = max(vDSP.maximumMagnitude(buffer.left), vDSP.maximumMagnitude(buffer.right))
        let peakDb = 20 * log10(Double(max(peak, 1e-9)))

        let frameLength = max(1, Int(0.05 * sampleRate))
        var levels: [Double] = []
        var start = 0
        while start + frameLength <= mid.count {
            let power = Double(vDSP.sumOfSquares(mid[start..<(start + frameLength)])) / Double(frameLength)
            levels.append(10 * log10(power + 1e-12))
            start += frameLength
        }
        var pauses = 1.0
        if !levels.isEmpty {
            let sorted = levels.sorted()
            let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            pauses = Double(levels.filter { $0 < loud - 30 }.count) / Double(levels.count)
        }
        return SplitAssessment(sideToMidDb: ratio, pauseShare: pauses, peakDb: peakDb)
    }
}

// MARK: - Chunks

/// Joins processed chunks that overlap by `overlap` samples with a linear
/// crossfade (the weights add up to 1), so chunk edges never click.
nonisolated struct CrossfadeStitcher: Sendable {
    let overlap: Int
    private var tail = StereoBuffer.empty

    init(overlap: Int) {
        self.overlap = max(0, overlap)
    }

    /// - Returns: The samples that are final now.
    mutating func stitch(_ chunk: StereoBuffer, isLast: Bool) -> StereoBuffer {
        let fade = min(tail.count, chunk.count)
        var output = StereoBuffer(left: [Float](repeating: 0, count: fade), right: [Float](repeating: 0, count: fade))
        for index in 0..<fade {
            let weight = (Float(index) + 0.5) / Float(fade)
            output.left[index] = tail.left[index] * (1 - weight) + chunk.left[index] * weight
            output.right[index] = tail.right[index] * (1 - weight) + chunk.right[index] * weight
        }
        let rest = StereoBuffer(left: Array(chunk.left[fade...]), right: Array(chunk.right[fade...]))
        if isLast || rest.count <= overlap {
            if isLast {
                output.append(rest)
                tail = .empty
            } else {
                tail = rest
            }
            return output
        }
        let keep = rest.count - overlap
        output.append(rest.prefix(keep))
        tail = StereoBuffer(left: Array(rest.left[keep...]), right: Array(rest.right[keep...]))
        return output
    }
}

/// Progress and time-left estimates.
nonisolated enum ProgressEstimate {
    /// Seconds left, once enough is done to guess (2 %).
    static func remainingSeconds(elapsed: Double, fraction: Double) -> Double? {
        guard fraction >= 0.02, fraction < 1, elapsed > 0 else { return fraction >= 1 ? 0 : nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// "About 2 min left", "Less than a minute left".
    static func text(remaining: Double?) -> String {
        guard let remaining else { return "Estimating time left…" }
        if remaining < 60 {
            return "Less than a minute left"
        }
        let minutes = (remaining / 60).rounded(.up)
        return "About \(minutes.roundedInt) min left"
    }
}

/// Disk space needed for a split (SPEC section 23.6: low-storage handling).
nonisolated enum StorageEstimate {
    /// AAC stereo at 192 kbit/s.
    static let bytesPerStemSecond = 24_000.0
    /// Room left for the system and temporary files.
    static let headroomBytes: Int64 = 50_000_000

    static func requiredBytes(duration: Double, stems: Int, sourceBytes: Int64) -> Int64 {
        let stemsBytes = Int64((max(0, duration) * bytesPerStemSecond * Double(max(0, stems)) * 1.2).rounded(.up))
        return stemsBytes + max(0, sourceBytes) + headroomBytes
    }

    static func check(required: Int64, available: Int64?) throws {
        guard let available else { return }
        if available < required {
            throw SeparationError.notEnoughStorage(
                neededMB: Int((Double(required) / 1_000_000).rounded(.up)),
                availableMB: Int(Double(max(0, available)) / 1_000_000)
            )
        }
    }

    /// Free space for important data at `url`'s volume.
    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
