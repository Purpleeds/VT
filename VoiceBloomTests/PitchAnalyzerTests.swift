import Foundation
import Testing
@testable import VoiceBloom

@Suite("PitchAnalyzer (YIN)")
struct PitchAnalyzerTests {
    private let configuration = AnalysisConfiguration()

    /// Runs YIN on several overlapping frames (different start phases) and
    /// returns every estimate.
    private func estimates(for signal: [Float], configuration: AnalysisConfiguration, frames: Int = 6) -> [PitchEstimate] {
        let analyzer = PitchAnalyzer(configuration: configuration)
        return (0..<frames).map { index in
            let start = index * configuration.hopSize
            return analyzer.estimate(Array(signal[start ..< start + configuration.frameSize]))
        }
    }

    private func signalLength(_ configuration: AnalysisConfiguration, frames: Int = 6) -> Int {
        configuration.frameSize + configuration.hopSize * frames
    }

    @Test("Sine waves are detected within ±2 Hz", arguments: TestSignal.speakingFrequencies)
    func detectsSineWaves(frequency: Double) throws {
        let signal = TestSignal.sine(frequency: frequency, count: signalLength(configuration))
        for estimate in estimates(for: signal, configuration: configuration) {
            let detected = try #require(estimate.frequency, "No pitch found for a \(frequency) Hz sine")
            #expect(abs(detected - frequency) <= 2, "Expected \(frequency) Hz, got \(detected) Hz")
            #expect(estimate.aperiodicity < 0.12)
        }
    }

    @Test("Sawtooth waves are detected within ±2 Hz", arguments: TestSignal.speakingFrequencies)
    func detectsSawtoothWaves(frequency: Double) throws {
        let signal = TestSignal.sawtooth(frequency: frequency, count: signalLength(configuration))
        for estimate in estimates(for: signal, configuration: configuration) {
            let detected = try #require(estimate.frequency, "No pitch found for a \(frequency) Hz sawtooth")
            #expect(abs(detected - frequency) <= 2, "Expected \(frequency) Hz, got \(detected) Hz")
        }
    }

    @Test("Works at 44.1 kHz too", arguments: [82.41, 146.83, 220.0, 349.23])
    func detectsAt44100(frequency: Double) throws {
        let configuration = AnalysisConfiguration(sampleRate: 44_100)
        let length = signalLength(configuration)
        for signal in [
            TestSignal.sine(frequency: frequency, sampleRate: 44_100, count: length),
            TestSignal.sawtooth(frequency: frequency, sampleRate: 44_100, count: length),
        ] {
            for estimate in estimates(for: signal, configuration: configuration) {
                let detected = try #require(estimate.frequency)
                #expect(abs(detected - frequency) <= 2, "Expected \(frequency) Hz, got \(detected) Hz")
            }
        }
    }

    @Test("Noisy voice-like signal (~20 dB SNR) is still accurate", arguments: [110.0, 196.0, 220.0, 330.0])
    func toleratesNoise(frequency: Double) throws {
        let length = signalLength(configuration)
        let signal = TestSignal.mix(
            TestSignal.sawtooth(frequency: frequency, count: length),
            TestSignal.noise(count: length, amplitude: 0.05)
        )
        for estimate in estimates(for: signal, configuration: configuration) {
            let detected = try #require(estimate.frequency)
            #expect(abs(detected - frequency) <= 2, "Expected \(frequency) Hz, got \(detected) Hz")
        }
    }

    @Test("Loudness doesn't matter: a very quiet tone is still found")
    func detectsQuietSignal() throws {
        let signal = TestSignal.sine(frequency: 200, count: configuration.frameSize, amplitude: 0.001)
        let estimate = PitchAnalyzer(configuration: configuration).estimate(signal)
        let detected = try #require(estimate.frequency)
        #expect(abs(detected - 200) <= 2)
    }

    @Test("Silence has no pitch")
    func silenceIsUnvoiced() {
        let estimate = PitchAnalyzer(configuration: configuration).estimate(TestSignal.silence(count: configuration.frameSize))
        #expect(estimate.frequency == nil)
        #expect(estimate.aperiodicity == 1)
    }

    @Test("White noise is (almost always) rejected")
    func noiseIsUnvoiced() {
        let analyzer = PitchAnalyzer(configuration: configuration)
        var voiced = 0
        for seed in 1...50 {
            let noise = TestSignal.noise(count: configuration.frameSize, amplitude: 0.2, seed: UInt64(seed))
            if analyzer.estimate(noise).frequency != nil {
                voiced += 1
            }
        }
        #expect(voiced <= 2, "\(voiced) of 50 noise frames were reported as pitched")
    }

    @Test("Pitches below the 60 Hz search floor are not reported")
    func belowRangeIsUnvoiced() {
        let signal = TestSignal.sine(frequency: 40, count: configuration.frameSize)
        let estimate = PitchAnalyzer(configuration: configuration).estimate(signal)
        #expect(estimate.frequency == nil)
    }

    @Test("Frames that are too short are rejected safely")
    func shortFrameIsUnvoiced() {
        let analyzer = PitchAnalyzer(configuration: configuration)
        #expect(analyzer.estimate([Float](repeating: 0.5, count: 100)) == .unvoiced)
        #expect(analyzer.estimate([]) == .unvoiced)
    }

    @Test("Search limits match the 60–500 Hz range")
    func lagLimits() {
        let analyzer = PitchAnalyzer(configuration: configuration)
        #expect(analyzer.minimumLag == 96)  // 48000 / 500
        #expect(analyzer.maximumLag == 800) // 48000 / 60
        #expect(analyzer.integrationWindow >= analyzer.maximumLag)
        #expect(analyzer.requiredFrameLength <= configuration.frameSize)
    }
}

@Suite("AnalysisConfiguration")
struct AnalysisConfigurationTests {
    @Test("48 kHz uses the spec's 2048-sample frame and 512-sample hop")
    func referenceSizes() {
        let configuration = AnalysisConfiguration(sampleRate: 48_000)
        #expect(configuration.frameSize == 2048)
        #expect(configuration.hopSize == 512)
        #expect(abs(configuration.hopDuration - 0.010_666) < 0.000_01)
    }

    @Test("Other sample rates keep similar timing and enough room for 60 Hz", arguments: [8_000.0, 16_000.0, 24_000.0, 44_100.0, 96_000.0])
    func scaledSizes(sampleRate: Double) {
        let configuration = AnalysisConfiguration(sampleRate: sampleRate)
        let analyzer = PitchAnalyzer(configuration: configuration)
        // Frame is a power of two.
        #expect(configuration.frameSize & (configuration.frameSize - 1) == 0)
        // Hop stays close to ~10.7 ms.
        #expect(abs(configuration.hopDuration - 0.0107) < 0.001)
        // The longest period (60 Hz) fits in YIN's integration window.
        #expect(Double(analyzer.integrationWindow) >= sampleRate / 60)
        #expect(analyzer.requiredFrameLength <= configuration.frameSize)
    }
}
