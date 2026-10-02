import Foundation

/// Vocal weight measurements for one frame.
nonisolated struct WeightMeasurement: Sendable, Equatable {
    /// H1–H2: level of the 1st harmonic minus the 2nd, in dB, straight from the spectrum.
    let h1MinusH2: Double
    /// H1*–H2*: the same after removing the boost F1 and F2 give nearby
    /// harmonics. This depends far less on which vowel is being said.
    let correctedH1MinusH2: Double?
    /// Spectral tilt: how fast harmonic levels fall with frequency, in dB per
    /// octave, measured up to 3 kHz (formant-corrected when formants are known).
    let spectralTilt: Double?

    /// Best available H1–H2 (corrected when possible).
    var effectiveH1MinusH2: Double { correctedH1MinusH2 ?? h1MinusH2 }
}

/// Measures vocal weight from the harmonic spectrum.
///
/// "Heavy" voices close the vocal folds firmly, which makes the upper
/// harmonics strong relative to the fundamental: low (or negative) H1–H2 and a
/// shallow spectral tilt. "Lighter" voices have a stronger fundamental and a
/// steeper fall-off: higher H1–H2 and a more negative tilt.
///
/// Harmonic levels are measured with the Goertzel algorithm, which evaluates
/// a single frequency in one pass and so can sit exactly on k × F0 instead of
/// the nearest FFT bin.
nonisolated final class WeightAnalyzer {
    let sampleRate: Double
    /// Highest harmonic frequency used for the tilt regression.
    let maximumTiltFrequency: Double
    /// Bandwidth limits used for formant correction. LPC bandwidths are noisy,
    /// and a too-narrow value would wildly over-correct a harmonic sitting on a formant.
    let minimumBandwidth = 80.0
    let maximumBandwidth = 500.0

    private let capacity: Int
    private let windowed: UnsafeMutablePointer<Double>
    private var window: [Double] = []

    init(sampleRate: Double, maximumFrameLength: Int, maximumTiltFrequency: Double = 3_000) {
        self.sampleRate = sampleRate
        self.maximumTiltFrequency = maximumTiltFrequency
        let size = max(1, maximumFrameLength)
        capacity = size
        let buffer = UnsafeMutablePointer<Double>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        windowed = buffer
    }

    deinit {
        windowed.deallocate()
    }

    func analyze(_ samples: [Float], fundamental: Double, formants: FormantMeasurement?) -> WeightMeasurement? {
        samples.withUnsafeBufferPointer { analyze($0, fundamental: fundamental, formants: formants) }
    }

    /// - Parameters:
    ///   - samples: A voiced frame (decimated is fine), without pre-emphasis.
    ///   - fundamental: F0 of this frame in Hz.
    ///   - formants: Formants of the same frame, used to correct H1, H2 and the tilt.
    func analyze(_ samples: UnsafeBufferPointer<Float>, fundamental: Double, formants: FormantMeasurement?) -> WeightMeasurement? {
        let count = min(samples.count, capacity)
        // Need at least 2.5 periods for distinct harmonic peaks, and H2 below Nyquist.
        guard fundamental > 0, fundamental.isFinite,
              Double(count) >= 2.5 * sampleRate / fundamental,
              2 * fundamental < 0.45 * sampleRate
        else { return nil }

        // Hann window: lower leakage than Hamming between closely spaced harmonics.
        prepareWindow(length: count)
        for index in 0..<count {
            windowed[index] = Double(samples[index]) * window[index]
        }
        let frame = UnsafeBufferPointer(start: windowed, count: count)

        // H1 and H2. A small search (±2%) around k·F0 tolerates slight pitch
        // error and vibrato within the frame.
        let h1 = harmonicLevel(frame, frequency: fundamental, search: true)
        let h2 = harmonicLevel(frame, frequency: 2 * fundamental, search: true)
        let raw = h1 - h2

        var corrected: Double?
        if let formants {
            let lowFormants = [formants.f1, formants.f2]
            corrected = (h1 - formantGain(at: fundamental, formants: lowFormants))
                - (h2 - formantGain(at: 2 * fundamental, formants: lowFormants))
        }

        // Spectral tilt: least-squares slope of harmonic level vs log2(frequency).
        var tiltFormants: [Formant] = []
        if let formants {
            tiltFormants = [formants.f1, formants.f2]
            if let f3 = formants.f3 {
                tiltFormants.append(f3)
            }
        }
        let limit = min(maximumTiltFrequency, 0.45 * sampleRate)
        var octaves: [Double] = []
        var levels: [Double] = []
        var harmonic = 1
        while Double(harmonic) * fundamental <= limit {
            let frequency = Double(harmonic) * fundamental
            let level = harmonicLevel(frame, frequency: frequency, search: harmonic <= 2)
            octaves.append(log2(frequency))
            levels.append(level - formantGain(at: frequency, formants: tiltFormants))
            harmonic += 1
        }
        let tilt = octaves.count >= 3 ? WeightAnalyzer.slope(x: octaves, y: levels) : nil

        return WeightMeasurement(h1MinusH2: raw, correctedH1MinusH2: corrected, spectralTilt: tilt)
    }

    // MARK: Building blocks

    /// Level (dB, arbitrary reference) of the harmonic near `frequency`.
    private func harmonicLevel(_ frame: UnsafeBufferPointer<Double>, frequency: Double, search: Bool) -> Double {
        var power = WeightAnalyzer.goertzelPower(frame, frequency: frequency, sampleRate: sampleRate)
        if search {
            for offset in [-0.02, -0.01, 0.01, 0.02] {
                let candidate = WeightAnalyzer.goertzelPower(frame, frequency: frequency * (1 + offset), sampleRate: sampleRate)
                power = max(power, candidate)
            }
        }
        return 10 * log10(max(power, 1e-30))
    }

    /// Total boost (dB) that the given formants add at `frequency`.
    private func formantGain(at frequency: Double, formants: [Formant]) -> Double {
        formants.reduce(0.0) { total, formant in
            let bandwidth = min(max(formant.bandwidth, minimumBandwidth), maximumBandwidth)
            return total + WeightAnalyzer.resonatorGain(
                at: frequency,
                formant: Formant(frequency: formant.frequency, bandwidth: bandwidth),
                sampleRate: sampleRate
            )
        }
    }

    /// Goertzel algorithm: signal power at one frequency.
    ///
    /// Runs the two-pole recursion s[n] = x[n] + 2cos(ω)·s[n−1] − s[n−2], then
    /// reads the power from the last two states. Equivalent to one DFT bin, but
    /// at any frequency, not just multiples of fs/N.
    static func goertzelPower(_ samples: UnsafeBufferPointer<Double>, frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = sample + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    }

    /// Gain (dB) at `frequency` of a two-pole resonator at the formant's
    /// frequency and bandwidth, normalized to 0 dB at DC.
    ///
    /// This is the correction of Iseli & Alwan (2004): the vocal-tract boost
    /// from each formant is subtracted from the harmonic levels so H1–H2
    /// reflects the voice source instead of the vowel.
    static func resonatorGain(at frequency: Double, formant: Formant, sampleRate: Double) -> Double {
        let radius = exp(-Double.pi * formant.bandwidth / sampleRate)
        let theta = 2 * Double.pi * formant.frequency / sampleRate
        let omega = 2 * Double.pi * frequency / sampleRate
        let numerator = 1 - 2 * radius * cos(theta) + radius * radius
        let below = 1 - 2 * radius * cos(omega - theta) + radius * radius
        let above = 1 - 2 * radius * cos(omega + theta) + radius * radius
        let denominator = (below * above).squareRoot()
        guard numerator > 0, denominator > 0 else { return 0 }
        return 20 * log10(numerator / denominator)
    }

    /// Least-squares slope of y against x.
    static func slope(x: [Double], y: [Double]) -> Double? {
        let count = min(x.count, y.count)
        guard count >= 2 else { return nil }
        let meanX = x.prefix(count).reduce(0, +) / Double(count)
        let meanY = y.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0
        var variance = 0.0
        for index in 0..<count {
            let dx = x[index] - meanX
            covariance += dx * (y[index] - meanY)
            variance += dx * dx
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }

    private func prepareWindow(length: Int) {
        guard window.count != length else { return }
        let span = Double(max(1, length - 1))
        window = (0..<length).map { index in
            0.5 - 0.5 * cos(2 * .pi * Double(index) / span)
        }
    }
}
