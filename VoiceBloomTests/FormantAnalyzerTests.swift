import Foundation
import Testing
@testable import VoiceBloom

@Suite("Decimator")
struct DecimatorTests {
    @Test("Decimation factors aim for ~11–12 kHz")
    func factors() {
        let cases: [(input: Double, factor: Int, output: Double)] = [
            (48_000, 4, 12_000),
            (44_100, 4, 11_025),
            (24_000, 2, 12_000),
            (16_000, 1, 16_000),
            (96_000, 8, 12_000),
        ]
        for testCase in cases {
            let decimator = Decimator(inputSampleRate: testCase.input)
            #expect(decimator.factor == testCase.factor, "input \(testCase.input)")
            #expect(decimator.outputSampleRate == testCase.output, "input \(testCase.input)")
        }
    }

    @Test("Filter has unity gain at DC")
    func unityGain() {
        let taps = Decimator(inputSampleRate: 48_000).taps
        #expect(taps.count == 161)
        #expect(abs(taps.reduce(0, +) - 1) < 1e-5)
    }

    @Test("A 2048-sample frame becomes 472 samples at 12 kHz")
    func outputLength() {
        let decimator = Decimator(inputSampleRate: 48_000)
        #expect(decimator.outputLength(forInputLength: 2048) == 472)
        #expect(decimator.decimate([Float](repeating: 0, count: 2048)).count == 472)
        #expect(decimator.outputLength(forInputLength: 100) == 0)
    }

    private func gainDb(_ frequency: Double) -> Double {
        let decimator = Decimator(inputSampleRate: 48_000)
        let input = TestSignal.sine(frequency: frequency, count: 8192, amplitude: 0.5)
        let output = decimator.decimate(input)
        return SignalLevel.decibels(fromAmplitude: SignalLevel.rms(output) / (0.5 / 2.0.squareRoot()))
    }

    @Test("Speech frequencies pass unchanged", arguments: [1_000.0, 3_000.0, 4_000.0])
    func passband(frequency: Double) {
        #expect(abs(gainDb(frequency)) < 0.2)
    }

    @Test("Frequencies above the new Nyquist are removed (no aliasing)", arguments: [6_500.0, 8_000.0, 12_000.0, 20_000.0])
    func stopband(frequency: Double) {
        #expect(gainDb(frequency) < -60)
    }

    @Test("Factor 1 passes samples straight through")
    func passthrough() {
        let decimator = Decimator(inputSampleRate: 16_000)
        let input: [Float] = [0.1, -0.2, 0.3, 0.4]
        #expect(decimator.decimate(input) == input)
    }
}

@Suite("Linear prediction (Levinson–Durbin)")
struct LinearPredictionTests {
    /// Autocorrelation of the AR(2) process x[n] = 1.3·x[n−1] − 0.6·x[n−2] + noise,
    /// from the Yule–Walker relation r[k] = 1.3·r[k−1] − 0.6·r[k−2].
    private func ar2Autocorrelation(lags: Int) -> [Double] {
        var r = [1.0, 1.3 / 1.6]
        while r.count <= lags {
            let count = r.count
            r.append(1.3 * r[count - 1] - 0.6 * r[count - 2])
        }
        return r
    }

    @Test("Recovers the coefficients of a known AR(2) process")
    func recoversAR2() throws {
        let model = try #require(LinearPrediction.levinsonDurbin(autocorrelation: ar2Autocorrelation(lags: 2), order: 2))
        #expect(model.order == 2)
        #expect(abs(model.coefficients[0] - 1) < 1e-12)
        #expect(abs(model.coefficients[1] - -1.3) < 1e-12)
        #expect(abs(model.coefficients[2] - 0.6) < 1e-12)
        #expect(model.predictionError > 0)
        #expect(model.reflectionCoefficients.allSatisfy { abs($0) < 1 })
    }

    @Test("Extra orders of an AR(2) process come out as zero")
    func overfittingIsHarmless() throws {
        let model = try #require(LinearPrediction.levinsonDurbin(autocorrelation: ar2Autocorrelation(lags: 4), order: 4))
        #expect(abs(model.coefficients[1] - -1.3) < 1e-9)
        #expect(abs(model.coefficients[2] - 0.6) < 1e-9)
        #expect(abs(model.coefficients[3]) < 1e-9)
        #expect(abs(model.coefficients[4]) < 1e-9)
    }

    @Test("Silence and invalid input have no model")
    func invalidInput() {
        #expect(LinearPrediction.levinsonDurbin(autocorrelation: [0, 0, 0], order: 2) == nil)
        #expect(LinearPrediction.levinsonDurbin(autocorrelation: [1, 0.5], order: 3) == nil)
        #expect(LinearPrediction.levinsonDurbin(autocorrelation: [1, 0.5], order: 0) == nil)
    }

    @Test("Autocorrelation")
    func autocorrelation() {
        #expect(LinearPrediction.autocorrelation([1, 2, 3], maxLag: 2) == [14, 8, 3])
        #expect(LinearPrediction.autocorrelation([1, 2], maxLag: 3) == [5, 2, 0, 0])
    }
}

@Suite("PolynomialRoots (Aberth)")
struct PolynomialRootsTests {
    private func sortedReal(_ roots: [ComplexNumber]) -> [Double] {
        roots.map(\.real).sorted()
    }

    @Test("Real roots: (z−1)(z−2)(z−3)")
    func realRoots() {
        let roots = PolynomialRoots.roots(of: [1, -6, 11, -6])
        #expect(roots.count == 3)
        #expect(roots.allSatisfy { abs($0.imaginary) < 1e-9 })
        let reals = sortedReal(roots)
        #expect(abs(reals[0] - 1) < 1e-9)
        #expect(abs(reals[1] - 2) < 1e-9)
        #expect(abs(reals[2] - 3) < 1e-9)
    }

    @Test("Complex pair: z² + 1 has roots ±i")
    func complexRoots() {
        let roots = PolynomialRoots.roots(of: [1, 0, 1])
        #expect(roots.count == 2)
        let imaginaries = roots.map(\.imaginary).sorted()
        #expect(abs(imaginaries[0] + 1) < 1e-9)
        #expect(abs(imaginaries[1] - 1) < 1e-9)
        #expect(roots.allSatisfy { abs($0.real) < 1e-9 })
    }

    @Test("Non-monic polynomials and leading zeros")
    func normalization() {
        let scaled = sortedReal(PolynomialRoots.roots(of: [2, 0, -8]))
        #expect(abs(scaled[0] + 2) < 1e-9)
        #expect(abs(scaled[1] - 2) < 1e-9)
        let padded = PolynomialRoots.roots(of: [0, 0, 1, -3])
        #expect(padded.count == 1)
        #expect(abs(padded[0].real - 3) < 1e-9)
        #expect(PolynomialRoots.roots(of: [5]).isEmpty)
        #expect(PolynomialRoots.roots(of: []).isEmpty)
    }

    @Test("Recovers the poles of a 12th-order vocal-tract-like polynomial")
    func lpcLikePolynomial() {
        // Six conjugate pole pairs, like six formants, at 12 kHz.
        let sampleRate = 12_000.0
        let resonances: [(Double, Double)] = [(500, 60), (1500, 90), (2500, 120), (3300, 150), (4200, 200), (5200, 300)]
        var expected: [ComplexNumber] = []
        for (frequency, bandwidth) in resonances {
            let radius = exp(-Double.pi * bandwidth / sampleRate)
            let angle = 2 * Double.pi * frequency / sampleRate
            expected.append(ComplexNumber(radius * cos(angle), radius * sin(angle)))
            expected.append(ComplexNumber(radius * cos(angle), -radius * sin(angle)))
        }
        // Expand Π (z − rootᵢ) into coefficients (highest power first).
        var polynomial = [ComplexNumber.one]
        for root in expected {
            var next = [ComplexNumber](repeating: .zero, count: polynomial.count + 1)
            for (index, coefficient) in polynomial.enumerated() {
                next[index] = next[index] + coefficient
                next[index + 1] = next[index + 1] - coefficient * root
            }
            polynomial = next
        }
        let coefficients = polynomial.map(\.real)

        let found = PolynomialRoots.roots(of: coefficients)
        #expect(found.count == 12)
        for target in expected {
            let closest = found.map { ($0 - target).magnitude }.min() ?? .infinity
            #expect(closest < 1e-8)
        }
    }
}

@Suite("FormantAnalyzer (synthetic vowels)")
struct FormantAnalyzerTests {
    /// Analyzes three steady frames of the vowel, the way the live pipeline does.
    private func measure(_ vowel: TestVowel, sampleRate: Double = 48_000) -> [FormantMeasurement?] {
        let configuration = AnalysisConfiguration(sampleRate: sampleRate)
        let decimator = Decimator(inputSampleRate: sampleRate)
        let analyzer = FormantAnalyzer(
            sampleRate: decimator.outputSampleRate,
            maximumFrameLength: decimator.outputLength(forInputLength: configuration.frameSize)
        )
        let signal = TestSignal.vowel(vowel, sampleRate: sampleRate, count: configuration.frameSize * 3)
        return [0, 1, 2].map { step in
            let start = configuration.frameSize + step * configuration.hopSize
            let frame = Array(signal[start ..< start + configuration.frameSize])
            return analyzer.analyze(decimator.decimate(frame))
        }
    }

    @Test("F1, F2 and F3 are found within tolerance", arguments: TestVowel.all)
    func findsFormants(vowel: TestVowel) throws {
        for result in measure(vowel) {
            let formants = try #require(result, "No formants found for \(vowel.name)")
            let f3 = try #require(formants.f3, "No F3 found for \(vowel.name)")
            #expect(abs(formants.f1.frequency - vowel.formants[0].frequency) <= 60, "F1 \(formants.f1.frequency)")
            #expect(abs(formants.f2.frequency - vowel.formants[1].frequency) <= 90, "F2 \(formants.f2.frequency)")
            #expect(abs(f3.frequency - vowel.formants[2].frequency) <= 120, "F3 \(f3.frequency)")
            #expect(formants.f1.bandwidth > 0 && formants.f1.bandwidth < 600)
        }
    }

    @Test("Works at 44.1 kHz too", arguments: [TestVowel.maleAH, .femaleEE])
    func findsFormantsAt44100(vowel: TestVowel) throws {
        for result in measure(vowel, sampleRate: 44_100) {
            let formants = try #require(result)
            #expect(abs(formants.f1.frequency - vowel.formants[0].frequency) <= 60)
            #expect(abs(formants.f2.frequency - vowel.formants[1].frequency) <= 90)
        }
    }

    @Test("A brighter (shorter vocal tract) vowel measures higher F2 and F3")
    func distinguishesResonance() throws {
        let male = try #require(measure(.maleAH)[0])
        let female = try #require(measure(.femaleAH)[0])
        let maleF3 = try #require(male.f3)
        let femaleF3 = try #require(female.f3)
        #expect(female.f2.frequency > male.f2.frequency)
        #expect(femaleF3.frequency > maleF3.frequency)
    }

    @Test("Silence has no formants")
    func silence() {
        let analyzer = FormantAnalyzer(sampleRate: 12_000, maximumFrameLength: 472)
        #expect(analyzer.analyze([Float](repeating: 0, count: 472)) == nil)
        #expect(analyzer.analyze([Float](repeating: 0, count: 10)) == nil)
    }

    @Test("Noise doesn't crash and resonances stay in range")
    func noise() {
        let analyzer = FormantAnalyzer(sampleRate: 12_000, maximumFrameLength: 472)
        for seed in 1...10 {
            let noise = TestSignal.noise(count: 472, amplitude: 0.2, seed: UInt64(seed))
            let resonances = noise.withUnsafeBufferPointer { analyzer.resonances($0) }
            #expect(resonances.allSatisfy { $0.frequency >= 0 && $0.frequency <= 6_000 && $0.bandwidth > 0 })
        }
    }

    @Test("Assignment skips broad and too-low resonances")
    func assignment() throws {
        let candidates = [
            Formant(frequency: 100, bandwidth: 50),   // glottal energy, too low
            Formant(frequency: 520, bandwidth: 80),
            Formant(frequency: 1_400, bandwidth: 2_000), // spectral slope, too broad
            Formant(frequency: 1_600, bandwidth: 90),
            Formant(frequency: 2_600, bandwidth: 120),
            Formant(frequency: 3_500, bandwidth: 200),
        ]
        let formants = try #require(FormantAnalyzer.assignFormants(candidates, sampleRate: 12_000))
        #expect(formants.f1.frequency == 520)
        #expect(formants.f2.frequency == 1_600)
        #expect(formants.f3?.frequency == 2_600)
    }

    @Test("Assignment needs at least F1 and F2")
    func assignmentNeedsTwo() {
        let onlyOne = [Formant(frequency: 500, bandwidth: 80)]
        #expect(FormantAnalyzer.assignFormants(onlyOne, sampleRate: 12_000) == nil)
        #expect(FormantAnalyzer.assignFormants([], sampleRate: 12_000) == nil)
    }
}
