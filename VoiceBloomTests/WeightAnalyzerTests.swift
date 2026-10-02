import Foundation
import Testing
@testable import VoiceBloom

@Suite("WeightAnalyzer")
struct WeightAnalyzerTests {
    private let decimator = Decimator(inputSampleRate: 48_000)

    private func analyzer() -> WeightAnalyzer {
        WeightAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: 472)
    }

    /// Harmonic k has amplitude k^(−exponent): H1–H2 = 6.02·exponent dB and
    /// the spectral tilt is −6.02·exponent dB per octave.
    private func series(fundamental: Double, exponent: Double) -> [Float] {
        let count = Int(5_800 / fundamental)
        let amplitudes = (1...count).map { pow(Double($0), -exponent) }
        return decimator.decimate(TestSignal.harmonicSeries(fundamental: fundamental, amplitudes: amplitudes, count: 2048))
    }

    @Test("H1–H2 and tilt of a known harmonic series", arguments: [100.0, 150.0, 220.0, 300.0], [1.0, 2.0])
    func knownSeries(fundamental: Double, exponent: Double) throws {
        let measurement = try #require(analyzer().analyze(series(fundamental: fundamental, exponent: exponent), fundamental: fundamental, formants: nil))
        let expectedDifference = 20 * log10(pow(2, exponent))
        #expect(abs(measurement.h1MinusH2 - expectedDifference) < 0.3)
        #expect(measurement.correctedH1MinusH2 == nil)
        let tilt = try #require(measurement.spectralTilt)
        #expect(abs(tilt + expectedDifference) < 0.3)
    }

    @Test("A small pitch error doesn't change H1–H2")
    func toleratesPitchError() throws {
        let signal = series(fundamental: 180, exponent: 1)
        let measurement = try #require(analyzer().analyze(signal, fundamental: 180 * 1.005, formants: nil))
        #expect(abs(measurement.h1MinusH2 - 6.02) < 0.3)
    }

    @Test("A lighter source (steeper roll-off) scores lighter")
    func lighterIsHigher() throws {
        let heavy = try #require(analyzer().analyze(series(fundamental: 200, exponent: 1), fundamental: 200, formants: nil))
        let light = try #require(analyzer().analyze(series(fundamental: 200, exponent: 2), fundamental: 200, formants: nil))
        let lightTilt = try #require(light.spectralTilt)
        let heavyTilt = try #require(heavy.spectralTilt)
        #expect(light.h1MinusH2 > heavy.h1MinusH2)
        #expect(lightTilt < heavyTilt)
        #expect(WeightReference.standard.score(h1MinusH2: light.h1MinusH2, spectralTilt: light.spectralTilt)
            > WeightReference.standard.score(h1MinusH2: heavy.h1MinusH2, spectralTilt: heavy.spectralTilt))
    }

    @Test("Resonator correction is 0 dB at DC and a boost at the formant")
    func resonatorGain() {
        let formant = Formant(frequency: 500, bandwidth: 80)
        #expect(abs(WeightAnalyzer.resonatorGain(at: 0, formant: formant, sampleRate: 12_000)) < 1e-9)
        #expect(WeightAnalyzer.resonatorGain(at: 500, formant: formant, sampleRate: 12_000) > 10)
        #expect(WeightAnalyzer.resonatorGain(at: 3_000, formant: formant, sampleRate: 12_000) < 0)
    }

    /// The synthetic vowels' source falls 12 dB/octave and lip radiation adds
    /// 6 dB/octave, so the true source H1–H2 is 6.02 dB for every vowel.
    /// ("oo" vowels are excluded: F1 sits right on H2, where any formant
    /// estimate error is magnified by the correction.)
    @Test("Formant-corrected H1*–H2* recovers the source value across vowels", arguments: [
        TestVowel.maleEE, .maleAH, .maleAE, .femaleEE, .femaleAH, .femaleAE,
    ])
    func correctedAcrossVowels(vowel: TestVowel) throws {
        let measurement = try measureVowel(vowel)
        let corrected = try #require(measurement.correctedH1MinusH2)
        #expect(abs(corrected - 6.02) < 2.0, "\(vowel.name): raw \(measurement.h1MinusH2), corrected \(corrected)")
        #expect(abs(corrected - 6.02) <= abs(measurement.h1MinusH2 - 6.02) + 0.5)
    }

    @Test("Correction fixes a vowel whose F1 boosts H2 (male “ee”)")
    func correctionMatters() throws {
        let measurement = try measureVowel(.maleEE)
        let corrected = try #require(measurement.correctedH1MinusH2)
        // Raw H1–H2 is about −3 dB because F1 (270 Hz) lifts H2 (240 Hz).
        #expect(measurement.h1MinusH2 < 0)
        #expect(abs(corrected - 6.02) < abs(measurement.h1MinusH2 - 6.02))
    }

    @Test("Formant-corrected tilt is similar for different vowels")
    func tiltIsVowelIndependent() throws {
        let vowels: [TestVowel] = [.maleEE, .maleAH, .maleAE, .femaleEE, .femaleAH, .femaleAE]
        let tilts = try vowels.map { vowel -> Double in
            let measurement = try measureVowel(vowel)
            return try #require(measurement.spectralTilt)
        }
        let lowest = try #require(tilts.min())
        let highest = try #require(tilts.max())
        #expect(highest - lowest < 3.0, "Tilts: \(tilts)")
        #expect(tilts.allSatisfy { $0 < -2 && $0 > -8 })
    }

    @Test("Invalid pitch or too-short frames give no measurement")
    func invalidInput() {
        let signal = series(fundamental: 200, exponent: 1)
        #expect(analyzer().analyze(signal, fundamental: 0, formants: nil) == nil)
        #expect(analyzer().analyze(signal, fundamental: .nan, formants: nil) == nil)
        // 30 Hz needs 2.5 periods = 83 ms, but the frame is only 39 ms.
        #expect(analyzer().analyze(signal, fundamental: 30, formants: nil) == nil)
        // H2 would be above the usable band.
        #expect(analyzer().analyze(signal, fundamental: 3_000, formants: nil) == nil)
    }

    @Test("Goertzel matches a pure tone's power")
    func goertzel() {
        let samples = (0..<480).map { sin(2 * Double.pi * 1_000 * Double($0) / 12_000) }
        let onTone = samples.withUnsafeBufferPointer { WeightAnalyzer.goertzelPower($0, frequency: 1_000, sampleRate: 12_000) }
        let offTone = samples.withUnsafeBufferPointer { WeightAnalyzer.goertzelPower($0, frequency: 2_500, sampleRate: 12_000) }
        // A unit sine of N samples has power (N/2)² at its own frequency.
        #expect(abs(onTone - 240 * 240) / (240 * 240) < 0.01)
        #expect(offTone < onTone * 1e-3)
    }

    @Test("Least-squares slope")
    func slope() {
        #expect(WeightAnalyzer.slope(x: [0, 1, 2, 3], y: [1, 3, 5, 7]) == 2)
        #expect(WeightAnalyzer.slope(x: [1, 1, 1], y: [1, 2, 3]) == nil)
        #expect(WeightAnalyzer.slope(x: [1], y: [1]) == nil)
    }

    private func measureVowel(_ vowel: TestVowel) throws -> WeightMeasurement {
        let signal = TestSignal.vowel(vowel, count: 2048 * 3)
        let frame = decimator.decimate(Array(signal[2048 ..< 4096]))
        let formantAnalyzer = FormantAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: 472)
        let formants = try #require(formantAnalyzer.analyze(frame))
        return try #require(analyzer().analyze(frame, fundamental: vowel.fundamental, formants: formants))
    }
}
