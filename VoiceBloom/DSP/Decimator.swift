import Accelerate
import Foundation

/// Lowers the sample rate by a whole-number factor (48 kHz → 12 kHz, 44.1 kHz → 11.025 kHz).
///
/// Formants live below ~4.5 kHz, so analyzing at ~11–12 kHz keeps everything
/// that matters while letting a low-order LPC model spend its poles on the
/// formants instead of on empty high-frequency spectrum.
///
/// Before throwing samples away, a windowed-sinc low-pass filter removes
/// everything above the new Nyquist frequency; otherwise high frequencies
/// would fold back (alias) and appear as fake low-frequency energy.
nonisolated final class Decimator {
    let inputSampleRate: Double
    /// Keep one sample out of every `factor`.
    let factor: Int
    let outputSampleRate: Double
    /// FIR low-pass coefficients (symmetric).
    let taps: [Float]

    init(inputSampleRate: Double, targetSampleRate: Double = 11_025) {
        let rate = max(inputSampleRate, 1)
        let decimation = max(1, Int(rate / max(targetSampleRate, 1)))
        self.inputSampleRate = rate
        factor = decimation
        outputSampleRate = rate / Double(decimation)
        if decimation > 1 {
            // Cut off at 42% of the new sample rate (5.04 kHz when going to 12 kHz).
            // 40 taps per unit of decimation gives a flat passband up to ~4.5 kHz
            // and > 60 dB of rejection by the new Nyquist frequency.
            let cutoff = 0.42 * (rate / Double(decimation)) / rate
            taps = Decimator.lowPassTaps(count: 40 * decimation + 1, cutoff: cutoff)
        } else {
            taps = [1]
        }
    }

    /// Number of output samples produced from `inputLength` input samples.
    func outputLength(forInputLength inputLength: Int) -> Int {
        guard inputLength >= taps.count else { return 0 }
        return (inputLength - taps.count) / factor + 1
    }

    /// Filters and decimates `input` into `output`.
    /// - Returns: The number of samples written.
    @discardableResult
    func decimate(_ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>) -> Int {
        let count = min(outputLength(forInputLength: input.count), output.count)
        guard count > 0, let source = input.baseAddress, let destination = output.baseAddress else { return 0 }
        taps.withUnsafeBufferPointer { filter in
            guard let coefficients = filter.baseAddress else { return }
            // vDSP_desamp computes C[n] = Σ_p A[n·factor + p] · F[p]: one FIR output
            // for every `factor` input samples, which filters and decimates in one pass.
            vDSP_desamp(
                source,
                vDSP_Stride(factor),
                coefficients,
                destination,
                vDSP_Length(count),
                vDSP_Length(filter.count)
            )
        }
        return count
    }

    /// Convenience for tests and offline analysis.
    func decimate(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: outputLength(forInputLength: input.count))
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                decimate(source, into: destination)
            }
        }
        return Array(output.prefix(written))
    }

    /// Windowed-sinc low-pass filter.
    /// - Parameter cutoff: Cutoff frequency in cycles per sample (0...0.5).
    static func lowPassTaps(count: Int, cutoff: Double) -> [Float] {
        let length = max(1, count)
        guard length > 1 else { return [1] }
        let middle = Double(length - 1) / 2
        let span = Double(length - 1)
        let raw: [Double] = (0..<length).map { index in
            let offset = Double(index) - middle
            // Ideal low-pass impulse response…
            let sinc = offset == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * offset) / (.pi * offset)
            // …tapered by a Blackman window to keep stopband ripple low.
            let position = Double(index) / span
            let window = 0.42 - 0.5 * cos(2 * .pi * position) + 0.08 * cos(4 * .pi * position)
            return sinc * window
        }
        // Normalize to unity gain at 0 Hz.
        let sum = raw.reduce(0, +)
        guard sum != 0 else { return raw.map { Float($0) } }
        return raw.map { Float($0 / sum) }
    }
}
