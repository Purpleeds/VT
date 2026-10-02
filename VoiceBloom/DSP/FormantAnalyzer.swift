import Foundation

/// One vocal-tract resonance.
nonisolated struct Formant: Sendable, Equatable {
    /// Centre frequency in Hz.
    let frequency: Double
    /// −3 dB bandwidth in Hz (narrow = sharp, well-defined resonance).
    let bandwidth: Double
}

/// The first three formants of one frame.
nonisolated struct FormantMeasurement: Sendable, Equatable {
    let f1: Formant
    let f2: Formant
    /// F3 is occasionally missing (merged with F2 or too weak to find).
    let f3: Formant?
}

/// Estimates formants (F1, F2, F3) with linear predictive coding.
///
/// Steps for each voiced, stable frame (already decimated to ~11–12 kHz):
/// 1. Pre-emphasis boosts high frequencies by ~6 dB/octave. Voiced speech
///    naturally falls off with frequency; flattening it lets LPC model the
///    upper formants as accurately as F1.
/// 2. A Hamming window tapers the frame edges to reduce spectral leakage.
/// 3. Autocorrelation + Levinson–Durbin fit a 12-pole model of the vocal tract.
/// 4. The poles are the roots of the LPC polynomial. A complex pole pair at
///    radius r and angle θ is a resonance at f = θ·fs/2π with bandwidth
///    B = −ln(r)·fs/π.
/// 5. Sharp resonances in the expected ranges are assigned to F1, F2, F3.
nonisolated final class FormantAnalyzer {
    let sampleRate: Double
    /// Number of LPC poles (two per resonance).
    let order: Int
    /// Pre-emphasis coefficient α in y[n] = x[n] − α·x[n−1].
    let preEmphasis: Double

    private let capacity: Int
    private let prepared: UnsafeMutablePointer<Double>
    private var window: [Double] = []

    /// - Parameters:
    ///   - sampleRate: Rate of the (decimated) input.
    ///   - maximumFrameLength: Longest frame `analyze` will be given.
    init(sampleRate: Double, maximumFrameLength: Int, order: Int = 12, preEmphasis: Double = 0.97) {
        self.sampleRate = sampleRate
        self.order = max(2, order)
        self.preEmphasis = preEmphasis
        let size = max(1, maximumFrameLength)
        capacity = size
        let buffer = UnsafeMutablePointer<Double>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        prepared = buffer
    }

    deinit {
        prepared.deallocate()
    }

    func analyze(_ samples: [Float]) -> FormantMeasurement? {
        samples.withUnsafeBufferPointer { analyze($0) }
    }

    func analyze(_ samples: UnsafeBufferPointer<Float>) -> FormantMeasurement? {
        let candidates = resonances(samples)
        return FormantAnalyzer.assignFormants(candidates, sampleRate: sampleRate)
    }

    /// Every resonance (pole pair) of the LPC model, lowest frequency first.
    func resonances(_ samples: UnsafeBufferPointer<Float>) -> [Formant] {
        let count = min(samples.count, capacity)
        guard count > order * 2 else { return [] }
        prepareWindow(length: count)

        // 1–2. Pre-emphasis, then Hamming window.
        var previous = 0.0
        for index in 0..<count {
            let sample = Double(samples[index])
            prepared[index] = (sample - preEmphasis * previous) * window[index]
            previous = sample
        }

        // 3. Autocorrelation and Levinson–Durbin.
        var correlation = LinearPrediction.autocorrelation(
            UnsafeBufferPointer(start: prepared, count: count),
            maxLag: order
        )
        guard correlation[0] > 1e-12 else { return [] }
        // A tiny "white noise floor" keeps the solution stable for very clean signals.
        correlation[0] *= 1 + 1e-9
        guard let model = LinearPrediction.levinsonDurbin(autocorrelation: correlation, order: order) else {
            return []
        }

        // 4. Poles → resonances. Only the upper half-plane member of each
        //    conjugate pair is kept; real poles shape the overall tilt, not formants.
        var resonances: [Formant] = []
        for root in PolynomialRoots.roots(of: model.coefficients) {
            let radius = root.magnitude
            guard root.imaginary > 1e-9, radius > 0, radius < 1 else { continue }
            let frequency = root.argument * sampleRate / (2 * .pi)
            let bandwidth = -log(radius) * sampleRate / .pi
            resonances.append(Formant(frequency: frequency, bandwidth: bandwidth))
        }
        return resonances.sorted { $0.frequency < $1.frequency }
    }

    /// Picks F1, F2 and F3 from LPC resonances.
    ///
    /// Broad resonances (bandwidth ≥ 600 Hz) usually model spectral slope
    /// rather than a formant and are skipped, as is anything below 150 Hz
    /// (glottal source energy) or right at the Nyquist edge.
    static func assignFormants(_ candidates: [Formant], sampleRate: Double) -> FormantMeasurement? {
        let usable = candidates
            .filter { candidate in
                candidate.frequency >= 150
                    && candidate.frequency <= sampleRate / 2 - 100
                    && candidate.bandwidth < 600
            }
            .sorted { $0.frequency < $1.frequency }

        guard let f1 = usable.first(where: { $0.frequency <= 1300 }) else { return nil }
        guard let f2 = usable.first(where: { $0.frequency > f1.frequency + 100 && (500...3500).contains($0.frequency) }) else {
            return nil
        }
        let f3 = usable.first(where: { $0.frequency > f2.frequency + 100 && (1500...4500).contains($0.frequency) })
        return FormantMeasurement(f1: f1, f2: f2, f3: f3)
    }

    private func prepareWindow(length: Int) {
        guard window.count != length else { return }
        let span = Double(max(1, length - 1))
        window = (0..<length).map { index in
            0.54 - 0.46 * cos(2 * .pi * Double(index) / span)
        }
    }
}
