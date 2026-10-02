import Foundation
import Testing
@testable import VoiceBloom

@Suite("VoiceQualityAnalyzer (jitter, shimmer, HNR)")
struct VoiceQualityAnalyzerTests {
    private let analyzer = VoiceQualityAnalyzer(sampleRate: 48_000)

    /// Analyzes consecutive, non-overlapping 2048-sample frames (as the
    /// pipeline does) and pools the per-pair results across frames.
    private func pooled(_ signal: [Float], fundamental: Double) -> (jitter: Double?, shimmer: Double?, hnr: [Double]) {
        var jitterTotal = 0.0
        var jitterPairs = 0
        var shimmerTotal = 0.0
        var shimmerPairs = 0
        var hnr: [Double] = []
        var start = 0
        while start + 2048 <= signal.count {
            if let measurement = analyzer.analyze(Array(signal[start ..< start + 2048]), fundamental: fundamental) {
                // Per-frame values are means over (cycles − 2) period pairs and
                // (cycles − 1) amplitude pairs; weight them accordingly.
                if let jitter = measurement.jitterPercent {
                    let pairs = measurement.cycleCount - 2
                    jitterTotal += jitter * Double(pairs)
                    jitterPairs += pairs
                }
                if let shimmer = measurement.shimmerPercent {
                    let pairs = measurement.cycleCount - 1
                    shimmerTotal += shimmer * Double(pairs)
                    shimmerPairs += pairs
                }
                if let value = measurement.harmonicsToNoiseDb {
                    hnr.append(value)
                }
            }
            start += 2048
        }
        return (
            jitterPairs > 0 ? jitterTotal / Double(jitterPairs) : nil,
            shimmerPairs > 0 ? shimmerTotal / Double(shimmerPairs) : nil,
            hnr
        )
    }

    @Test("A perfectly periodic voice has ~0 jitter and shimmer and a high HNR", arguments: [120.0, 220.0])
    func periodic(fundamental: Double) throws {
        let signal = TestSignal.ringPulses(fundamental: fundamental, count: 6144)
        let measurement = try #require(analyzer.analyze(Array(signal[2048 ..< 4096]), fundamental: fundamental))
        #expect(measurement.cycleCount >= 4)
        #expect(try #require(measurement.jitterPercent) < 0.05)
        #expect(try #require(measurement.shimmerPercent) < 0.05)
        #expect(try #require(measurement.harmonicsToNoiseDb) > 30)
    }

    @Test("±1% random period changes give local jitter ≈ 0.67%")
    func knownJitter() throws {
        // For periods varying uniformly by ±δ, E|Tᵢ − Tᵢ₊₁| / T = 2δ/3.
        let signal = TestSignal.ringPulses(fundamental: 220, count: 48_000, periodJitter: 0.01, seed: 3)
        let jitter = try #require(pooled(signal, fundamental: 220).jitter)
        #expect(abs(jitter - 0.667) < 0.2, "jitter \(jitter)")
    }

    @Test("More period variation measures as more jitter")
    func jitterScales() throws {
        let small = try #require(pooled(TestSignal.ringPulses(fundamental: 220, count: 48_000, periodJitter: 0.01, seed: 4), fundamental: 220).jitter)
        let large = try #require(pooled(TestSignal.ringPulses(fundamental: 220, count: 48_000, periodJitter: 0.03, seed: 4), fundamental: 220).jitter)
        #expect(large > small * 2)
    }

    @Test("Amplitudes alternating ±3% give shimmer ≈ 6%", arguments: [120.0, 220.0])
    func alternatingShimmer(fundamental: Double) throws {
        let signal = TestSignal.ringPulses(fundamental: fundamental, count: 48_000, alternatingAmplitude: 0.03)
        let shimmer = try #require(pooled(signal, fundamental: fundamental).shimmer)
        #expect(abs(shimmer - 6.0) < 0.3, "shimmer \(shimmer)")
    }

    @Test("±5% random amplitude changes give shimmer ≈ 3.3%")
    func randomShimmer() throws {
        let signal = TestSignal.ringPulses(fundamental: 220, count: 48_000, amplitudeJitter: 0.05, seed: 5)
        let shimmer = try #require(pooled(signal, fundamental: 220).shimmer)
        #expect(abs(shimmer - 3.33) < 0.8, "shimmer \(shimmer)")
    }

    @Test("HNR matches the signal-to-noise ratio of a noisy vowel", arguments: [20.0, 10.0])
    func harmonicsToNoise(signalToNoise: Double) throws {
        let clean = TestSignal.vowel(.maleAH, count: 48_000)
        let power = clean[2048...].map { Double($0) * Double($0) }.reduce(0, +) / Double(clean.count - 2048)
        // Uniform noise of amplitude a has power a²/3.
        let amplitude = (3 * power / pow(10, signalToNoise / 10)).squareRoot()
        let noisy = TestSignal.mix(clean, TestSignal.noise(count: clean.count, amplitude: amplitude, seed: 7))
        let values = pooled(Array(noisy[2048...]), fundamental: 120).hnr
        let median = try #require(PitchMath.median(of: values))
        #expect(abs(median - signalToNoise) < 1.5, "HNR \(median)")
    }

    @Test("A noisier (breathier) voice has more jitter and less HNR")
    func noiseIsRougher() throws {
        let clean = TestSignal.vowel(.maleAH, count: 24_000)
        let noisy = TestSignal.mix(clean, TestSignal.noise(count: clean.count, amplitude: 0.08, seed: 11))
        let cleanResult = pooled(Array(clean[2048...]), fundamental: 120)
        let noisyResult = pooled(Array(noisy[2048...]), fundamental: 120)
        let cleanHNR = try #require(PitchMath.median(of: cleanResult.hnr))
        let noisyHNR = try #require(PitchMath.median(of: noisyResult.hnr))
        #expect(noisyHNR < cleanHNR - 10)
        #expect(try #require(noisyResult.jitter) > (cleanResult.jitter ?? 0))
    }

    @Test("White noise has no cycles to measure and a very low HNR")
    func whiteNoise() {
        for seed in 1...3 {
            let noise = TestSignal.noise(count: 2048, amplitude: 0.2, seed: UInt64(seed))
            guard let measurement = analyzer.analyze(noise, fundamental: 200) else { continue }
            #expect(measurement.cycleCount < 3)
            #expect(measurement.jitterPercent == nil)
            #expect((measurement.harmonicsToNoiseDb ?? -100) < 0)
        }
    }

    @Test("Invalid pitch or too-short frames give nothing")
    func invalidInput() {
        let signal = TestSignal.ringPulses(fundamental: 200, count: 2048)
        #expect(analyzer.analyze(signal, fundamental: 0) == nil)
        #expect(analyzer.analyze(signal, fundamental: .nan) == nil)
        // 40 Hz needs 3 periods = 3600 samples.
        #expect(analyzer.analyze(signal, fundamental: 40) == nil)
        #expect(analyzer.analyze([], fundamental: 200) == nil)
    }

    @Test("Relative change of consecutive values")
    func relativeChange() throws {
        let value = try #require(VoiceQualityAnalyzer.relativeChangePercent([100, 102, 100]))
        #expect(abs(value - 200.0 / 101.0) < 1e-9)
        #expect(VoiceQualityAnalyzer.relativeChangePercent([100]) == nil)
        #expect(VoiceQualityAnalyzer.relativeChangePercent([]) == nil)
        #expect(VoiceQualityAnalyzer.relativeChangePercent([5, 5, 5]) == 0)
    }
}
