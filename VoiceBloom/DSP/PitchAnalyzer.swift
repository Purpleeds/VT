import Accelerate
import Foundation

/// Result of running YIN on one frame.
nonisolated struct PitchEstimate: Sendable, Equatable {
    /// Fundamental frequency in Hz, or `nil` when the frame isn't clearly periodic
    /// (silence, noise, whispering, or a pitch outside the search range).
    let frequency: Double?
    /// The lowest cumulative-mean-normalized difference found in the search range.
    /// 0 means perfectly periodic, values near 1 mean noise-like.
    let aperiodicity: Double

    /// 0...1, higher means a cleaner, more periodic voice.
    var confidence: Double { min(max(1 - aperiodicity, 0), 1) }

    static let unvoiced = PitchEstimate(frequency: nil, aperiodicity: 1)
}

/// Estimates the fundamental frequency (F0) of a frame with the YIN algorithm
/// (de Cheveigné & Kawahara, 2002).
///
/// YIN asks: "if I shift the signal by τ samples, how different is it from itself?"
/// For a voice with period T the difference is close to zero at τ = T, so the
/// first deep dip in the difference curve gives the period, and F0 = sampleRate / T.
///
/// The analyzer keeps all scratch buffers preallocated, so `estimate` performs
/// no heap allocation and is cheap enough to run ~94 times per second.
/// It is not thread-safe: use one instance per analysis thread.
nonisolated final class PitchAnalyzer {
    let configuration: AnalysisConfiguration
    /// W in the YIN paper: how many samples are compared for each lag.
    let integrationWindow: Int
    /// Smallest lag searched (corresponds to the maximum frequency).
    let minimumLag: Int
    /// Largest lag searched (corresponds to the minimum frequency).
    let maximumLag: Int

    /// Lags 0...maximumLag + 1 are computed; the extra lag lets parabolic
    /// interpolation look one step past the last searched lag.
    private let lagCount: Int
    private let correlation: UnsafeMutablePointer<Float>
    private let difference: UnsafeMutablePointer<Double>
    private let normalizedDifference: UnsafeMutablePointer<Double>

    init(configuration: AnalysisConfiguration) {
        let window = configuration.frameSize / 2
        let rate = configuration.sampleRate
        // τ = sampleRate / frequency, so the highest frequency gives the shortest lag.
        let shortestLag = max(2, Int((rate / configuration.maximumFrequency).rounded(.down)))
        let longestLag = Int((rate / configuration.minimumFrequency).rounded(.up))
        let lastLag = max(shortestLag + 1, min(window - 2, longestLag))
        let count = lastLag + 2

        let correlationBuffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        correlationBuffer.initialize(repeating: 0, count: count)
        let differenceBuffer = UnsafeMutablePointer<Double>.allocate(capacity: count)
        differenceBuffer.initialize(repeating: 0, count: count)
        let normalizedBuffer = UnsafeMutablePointer<Double>.allocate(capacity: count)
        normalizedBuffer.initialize(repeating: 1, count: count)

        self.configuration = configuration
        integrationWindow = window
        minimumLag = shortestLag
        maximumLag = lastLag
        lagCount = count
        correlation = correlationBuffer
        difference = differenceBuffer
        normalizedDifference = normalizedBuffer
    }

    deinit {
        correlation.deallocate()
        difference.deallocate()
        normalizedDifference.deallocate()
    }

    /// Minimum number of samples a frame must contain.
    var requiredFrameLength: Int { integrationWindow + lagCount - 1 }

    func estimate(_ frame: [Float]) -> PitchEstimate {
        frame.withUnsafeBufferPointer { estimate($0) }
    }

    func estimate(_ frame: UnsafeBufferPointer<Float>) -> PitchEstimate {
        guard let samples = frame.baseAddress, frame.count >= requiredFrameLength else {
            return .unvoiced
        }
        let window = integrationWindow

        // Step 1 — Autocorrelation.
        // r(τ) = Σ_{j=0}^{W-1} x[j] · x[j+τ] for every lag τ we need.
        // vDSP_conv with a positive filter stride computes exactly this
        // correlation: C[n] = Σ_p A[n+p] · F[p], using the first W samples as F.
        vDSP_conv(
            samples, 1,
            samples, 1,
            correlation, 1,
            vDSP_Length(lagCount),
            vDSP_Length(window)
        )

        // Step 2 — Difference function.
        // d(τ) = Σ (x[j] − x[j+τ])² expands to e(0) + e(τ) − 2·r(τ), where e(τ) is
        // the energy of the W samples starting at τ. e(τ) is updated with a
        // sliding window (drop one sample, add one) in Double for precision.
        var startEnergy = 0.0
        for index in 0..<window {
            let sample = Double(samples[index])
            startEnergy += sample * sample
        }
        var shiftedEnergy = startEnergy
        difference[0] = 0
        for lag in 1..<lagCount {
            let leaving = Double(samples[lag - 1])
            let entering = Double(samples[lag - 1 + window])
            shiftedEnergy += entering * entering - leaving * leaving
            let value = startEnergy + shiftedEnergy - 2 * Double(correlation[lag])
            // Rounding can push values that should be zero slightly negative.
            difference[lag] = max(0, value)
        }

        // Step 3 — Cumulative mean normalized difference (CMND).
        // d'(τ) = d(τ) / ((1/τ) Σ_{j=1}^{τ} d(j)), with d'(0) = 1. Normalizing by the
        // running mean removes YIN's bias toward tiny lags and puts every frame
        // on the same 0...~1 scale regardless of loudness.
        normalizedDifference[0] = 1
        var runningSum = 0.0
        for lag in 1..<lagCount {
            runningSum += difference[lag]
            normalizedDifference[lag] = runningSum > 0
                ? difference[lag] * Double(lag) / runningSum
                : 1
        }

        // Step 4 — Absolute threshold.
        // Take the first lag whose d' dips below the threshold, then walk forward
        // to the bottom of that dip. Choosing the *first* dip (not the global
        // minimum) is what prevents reporting half the true pitch.
        var bestLag: Int?
        var lag = minimumLag
        while lag <= maximumLag {
            if normalizedDifference[lag] < configuration.yinThreshold {
                while lag + 1 <= maximumLag, normalizedDifference[lag + 1] < normalizedDifference[lag] {
                    lag += 1
                }
                bestLag = lag
                break
            }
            lag += 1
        }

        guard let period = bestLag else {
            // No clear period: report how close we got, for the debug screen.
            var lowest = 1.0
            for candidate in minimumLag...maximumLag {
                lowest = min(lowest, normalizedDifference[candidate])
            }
            return PitchEstimate(frequency: nil, aperiodicity: lowest)
        }

        // Step 5 — Parabolic interpolation.
        // The true period rarely lands on a whole sample. Fitting a parabola
        // through d(τ−1), d(τ), d(τ+1) and taking its vertex gives sub-sample
        // accuracy (well under ±1 Hz at speaking pitches).
        let previous = difference[period - 1]
        let current = difference[period]
        let next = difference[period + 1]
        let curvature = previous - 2 * current + next
        var shift = 0.0
        if curvature > 0 {
            shift = min(max(0.5 * (previous - next) / curvature, -1), 1)
        }
        let refinedPeriod = Double(period) + shift
        guard refinedPeriod > 0 else { return .unvoiced }

        return PitchEstimate(
            frequency: configuration.sampleRate / refinedPeriod,
            aperiodicity: min(max(normalizedDifference[period], 0), 1)
        )
    }
}
