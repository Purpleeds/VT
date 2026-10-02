import Accelerate
import Foundation

/// Cycle-to-cycle voice quality for one frame.
///
/// These are rough indicators from a phone microphone, not a diagnosis:
/// the app only compares them with the user's own usual values.
nonisolated struct VoiceQualityMeasurement: Sendable, Equatable {
    /// Local jitter: average change in period length between neighbouring
    /// cycles, as a percentage of the period. Nil with fewer than 3 cycles.
    let jitterPercent: Double?
    /// Local shimmer: average change in peak amplitude between neighbouring
    /// cycles, as a percentage of the amplitude.
    let shimmerPercent: Double?
    /// Harmonics-to-noise ratio in dB: how much of the sound is periodic
    /// voice versus breath/noise. Higher is clearer.
    let harmonicsToNoiseDb: Double?
    /// Number of glottal cycles marked in the frame.
    let cycleCount: Int
}

/// Measures jitter, shimmer and harmonics-to-noise ratio (HNR).
///
/// 1. Cycle marking: starting from the highest peak in the first period, each
///    next cycle's peak is searched for 0.8–1.2 periods later (sub-sample
///    accurate via parabolic interpolation). A cycle only counts if its
///    waveform still resembles the previous one (normalized correlation ≥ 0.5),
///    which stops marking at noise or voice breaks.
/// 2. Jitter = mean |Tᵢ − Tᵢ₊₁| relative to their average; shimmer is the same
///    for peak amplitudes (Praat's "local" measures, computed per pair).
/// 3. HNR comes from the normalized autocorrelation r at one period lag:
///    a periodic signal plus noise gives r = P / (P + N), so HNR = 10·log₁₀(r / (1 − r)).
///
/// Not thread-safe; use one instance per analysis thread.
nonisolated final class VoiceQualityAnalyzer {
    let sampleRate: Double
    /// Minimum correlation between consecutive cycles for a mark to be accepted.
    static let minimumCycleCorrelation = 0.5
    /// r is capped just below 1, which caps HNR at 50 dB for perfectly periodic input.
    static let maximumCorrelation = 0.99999

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func analyze(_ frame: [Float], fundamental: Double) -> VoiceQualityMeasurement? {
        frame.withUnsafeBufferPointer { analyze($0, fundamental: fundamental) }
    }

    /// - Parameters:
    ///   - frame: A voiced frame at the original sample rate (not decimated:
    ///     cycle timing needs the full time resolution).
    ///   - fundamental: F0 of the frame in Hz.
    func analyze(_ frame: UnsafeBufferPointer<Float>, fundamental: Double) -> VoiceQualityMeasurement? {
        guard fundamental > 0, fundamental.isFinite else { return nil }
        let period = sampleRate / fundamental
        guard period >= 4, Double(frame.count) >= 3 * period else { return nil }

        let marks = VoiceQualityAnalyzer.cycleMarks(frame, period: period)
        let periods = zip(marks.dropFirst(), marks).map { $0.position - $1.position }
        let jitter = VoiceQualityAnalyzer.relativeChangePercent(periods)
        let shimmer = VoiceQualityAnalyzer.relativeChangePercent(marks.map(\.amplitude))
        let hnr = VoiceQualityAnalyzer.harmonicsToNoise(frame, period: period)

        guard jitter != nil || shimmer != nil || hnr != nil else { return nil }
        return VoiceQualityMeasurement(
            jitterPercent: jitter,
            shimmerPercent: shimmer,
            harmonicsToNoiseDb: hnr,
            cycleCount: marks.count
        )
    }

    // MARK: Cycle marking

    nonisolated struct CycleMark: Sendable, Equatable {
        /// Peak position in samples (fractional).
        let position: Double
        /// Peak value.
        let amplitude: Double
    }

    /// Finds one peak per glottal cycle.
    static func cycleMarks(_ samples: UnsafeBufferPointer<Float>, period: Double) -> [CycleMark] {
        let count = samples.count
        let firstEnd = min(count, Int(period.rounded(.up)))
        guard firstEnd > 2, let base = samples.baseAddress else { return [] }

        var marks = [interpolatedPeak(samples, at: indexOfMaximum(samples, in: 0..<firstEnd))]
        var currentPeriod = period

        while marks.count < 128, let previous = marks.last {
            // Search the window where the next cycle's peak should be.
            let lower = Int((previous.position + 0.8 * currentPeriod).rounded(.down))
            let upper = Int((previous.position + 1.2 * currentPeriod).rounded(.up))
            guard lower > 0, upper < count - 1 else { break }

            let mark = interpolatedPeak(samples, at: indexOfMaximum(samples, in: lower..<(upper + 1)))
            let length = Int(currentPeriod.rounded())
            let previousStart = Int(previous.position.rounded())
            let nextStart = Int(mark.position.rounded())
            guard length > 2, previousStart + length <= count, nextStart + length <= count else { break }

            // The new cycle must look like the last one, or we've hit noise.
            let similarity = normalizedCorrelation(base, first: previousStart, second: nextStart, length: length)
            guard similarity >= minimumCycleCorrelation else { break }

            let measuredPeriod = mark.position - previous.position
            guard measuredPeriod > 0.7 * period, measuredPeriod < 1.4 * period else { break }
            marks.append(mark)
            currentPeriod = measuredPeriod
        }
        return marks
    }

    /// Mean of |xᵢ − xᵢ₊₁| / ((xᵢ + xᵢ₊₁) / 2) over consecutive pairs, in percent.
    static func relativeChangePercent(_ values: [Double]) -> Double? {
        var total = 0.0
        var pairs = 0
        for index in 0..<max(0, values.count - 1) {
            let mean = (values[index] + values[index + 1]) / 2
            guard mean > 0 else { continue }
            total += abs(values[index] - values[index + 1]) / mean
            pairs += 1
        }
        guard pairs > 0 else { return nil }
        return 100 * total / Double(pairs)
    }

    // MARK: Harmonics-to-noise ratio

    /// HNR (dB) from the normalized autocorrelation peak near one period.
    static func harmonicsToNoise(_ samples: UnsafeBufferPointer<Float>, period: Double) -> Double? {
        let count = samples.count
        guard let base = samples.baseAddress else { return nil }
        let lowest = max(2, Int((0.9 * period).rounded(.down)))
        let highest = min(count - 2, Int((1.1 * period).rounded(.up)))
        guard highest > lowest, count - highest - 1 > 8 else { return nil }

        // r(τ) for each candidate lag, plus one extra on each side for interpolation.
        let lags = Array((lowest - 1)...(highest + 1))
        let correlations = lags.map { lag in
            normalizedCorrelation(base, first: 0, second: lag, length: count - lag)
        }
        var best = 1
        for index in 1..<(correlations.count - 1) where correlations[index] > correlations[best] {
            best = index
        }
        let peak = parabolicPeak(correlations[best - 1], correlations[best], correlations[best + 1])
        let r = min(max(peak, 1e-6), maximumCorrelation)
        return 10 * log10(r / (1 - r))
    }

    // MARK: Helpers

    /// Normalized cross-correlation of two equal-length segments (−1...1).
    static func normalizedCorrelation(_ base: UnsafePointer<Float>, first: Int, second: Int, length: Int) -> Double {
        guard length > 0 else { return 0 }
        var cross: Float = 0
        var firstEnergy: Float = 0
        var secondEnergy: Float = 0
        vDSP_dotpr(base + first, 1, base + second, 1, &cross, vDSP_Length(length))
        vDSP_svesq(base + first, 1, &firstEnergy, vDSP_Length(length))
        vDSP_svesq(base + second, 1, &secondEnergy, vDSP_Length(length))
        let denominator = (Double(firstEnergy) * Double(secondEnergy)).squareRoot()
        guard denominator > 0 else { return 0 }
        return Double(cross) / denominator
    }

    static func indexOfMaximum(_ samples: UnsafeBufferPointer<Float>, in range: Range<Int>) -> Int {
        var bestIndex = range.lowerBound
        var bestValue = -Float.infinity
        for index in range where samples[index] > bestValue {
            bestValue = samples[index]
            bestIndex = index
        }
        return bestIndex
    }

    /// Refines a sample peak to a fractional position and height with a parabola.
    static func interpolatedPeak(_ samples: UnsafeBufferPointer<Float>, at index: Int) -> CycleMark {
        let value = Double(samples[index])
        guard index > 0, index < samples.count - 1 else {
            return CycleMark(position: Double(index), amplitude: value)
        }
        let before = Double(samples[index - 1])
        let after = Double(samples[index + 1])
        let curvature = before - 2 * value + after
        guard curvature < 0 else { return CycleMark(position: Double(index), amplitude: value) }
        let shift = min(max(0.5 * (before - after) / curvature, -0.5), 0.5)
        return CycleMark(position: Double(index) + shift, amplitude: value - 0.25 * (before - after) * shift)
    }

    /// Height of the parabola through three equally spaced points.
    static func parabolicPeak(_ before: Double, _ value: Double, _ after: Double) -> Double {
        let curvature = before - 2 * value + after
        guard curvature < 0 else { return value }
        let shift = min(max(0.5 * (before - after) / curvature, -1), 1)
        return value - 0.25 * (before - after) * shift
    }
}
