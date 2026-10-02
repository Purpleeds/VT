import Foundation
import Testing
@testable import VoiceBloom

@Suite("Voice Preview: settings and labels")
struct VoicePreviewSettingsTests {
    @Test("Semitones and percent become factors, clamped to the ranges")
    func factors() {
        let settings = VoicePreviewSettings(pitchSemitones: 12, resonancePercent: 15)
        #expect(abs(settings.pitchFactor - 2) < 1e-12)
        #expect(abs(settings.formantFactor - 1.15) < 1e-12)
        #expect(!settings.isUnchanged)
        #expect(VoicePreviewSettings().isUnchanged)

        let clamped = VoicePreviewSettings(pitchSemitones: 30, resonancePercent: -50)
        #expect(clamped.pitchSemitones == 12)
        #expect(clamped.resonancePercent == -10)
    }

    @Test("Toward my target: pitch to the target, F2 by the ratio")
    func towardTarget() {
        let settings = VoicePreviewSettings.toward(sourcePitch: 120, targetPitch: 200, sourceF2: 1_300, targetF2: 1_500)
        // 12 · log2(200 / 120) = 8.84 → nearest half semitone 9; 1500 / 1300 − 1 = 15.4 % → 15.
        #expect(settings.pitchSemitones == 9)
        #expect(settings.resonancePercent == 15)

        let lowering = VoicePreviewSettings.toward(sourcePitch: 200, targetPitch: 150, sourceF2: 1_700, targetF2: 1_500)
        #expect(lowering.pitchSemitones == -5)
        #expect(lowering.resonancePercent == -10)

        #expect(VoicePreviewSettings.toward(sourcePitch: nil, targetPitch: 200, sourceF2: nil, targetF2: 1_500).isUnchanged)
        let far = VoicePreviewSettings.toward(sourcePitch: 100, targetPitch: 1_000, sourceF2: 1_000, targetF2: 2_000)
        #expect(far.pitchSemitones == 12)
        #expect(far.resonancePercent == 20)
    }

    @Test("Slider labels")
    func labels() {
        #expect(VoicePreviewFormat.signed(4.5, digits: 1) == "+4.5")
        #expect(VoicePreviewFormat.signed(-3, digits: 1) == "−3")
        #expect(VoicePreviewFormat.signed(0, digits: 0) == "0")
        #expect(VoicePreviewFormat.pitch(12, from: 120) == "+12 st (120 → 240 Hz)")
        #expect(VoicePreviewFormat.pitch(-2, from: nil) == "−2 st")
        #expect(VoicePreviewFormat.resonance(15) == "+15 % brighter")
        #expect(VoicePreviewFormat.resonance(-5) == "−5 % darker")
        #expect(VoicePreviewFormat.resonance(0) == "0 %")
        #expect(VoicePreviewFormat.spokenPitch(0) == "No change")
        #expect(VoicePreviewFormat.spokenResonance(10) == "10 percent brighter")
    }
}

@Suite("Voice Preview: pitch periods")
struct VoicePeriodTrackTests {
    private let rate = 48_000.0

    @Test("Periods follow the track; short gaps are bridged, long ones aren't")
    func periods() {
        var points: [PitchTrackPoint] = []
        // 0.10–0.30 s at 200 Hz with one missing frame at 0.15 s.
        for index in 0..<21 {
            points.append(PitchTrackPoint(time: 0.1 + Double(index) * 0.01, frequency: index == 5 ? nil : 200))
        }
        // 0.31–0.40 s: a real pause.
        for index in 0..<10 {
            points.append(PitchTrackPoint(time: 0.31 + Double(index) * 0.01, frequency: nil))
        }
        // 0.41–0.45 s at 100 Hz, then 200 Hz.
        for index in 0..<10 {
            points.append(PitchTrackPoint(time: 0.41 + Double(index) * 0.01, frequency: index < 5 ? 100 : 200))
        }
        let periods = VoicePeriodTrack.periods(points: points, sampleCount: 48_000, sampleRate: rate)
        #expect(periods.count == 48_000)
        #expect(periods[Int(0.15 * rate)] == 240)
        #expect(periods[Int(0.2 * rate)] == 240)
        #expect(periods[Int(0.35 * rate)] == 0)
        // Halfway between 100 Hz and 200 Hz: 150 Hz → 320 samples.
        #expect(abs(periods[Int(0.455 * rate)] - 320) < 0.5)
        // Voicing starts half a hop before the first frame.
        #expect(periods[Int(0.096 * rate)] == 240)
        #expect(periods[Int(0.094 * rate)] == 0)
        #expect(periods[Int(0.8 * rate)] == 0)
    }

    @Test("No track means no voicing")
    func empty() {
        #expect(VoicePeriodTrack.periods(points: [], sampleCount: 100, sampleRate: rate) == [Float](repeating: 0, count: 100))
        #expect(VoicePeriodTrack.periods(points: [], sampleCount: 0, sampleRate: rate).isEmpty)
        let silly = [PitchTrackPoint(time: 0.05, frequency: .nan), PitchTrackPoint(time: 0.06, frequency: 5)]
        #expect(VoicePeriodTrack.periods(points: silly, sampleCount: 4_800, sampleRate: rate).allSatisfy { $0 == 0 })
    }
}

@Suite("Voice Preview: pitch and formant shifting")
struct PitchSynchronousShifterTests {
    private let rate = 48_000.0
    private let configuration = AnalysisConfiguration()

    /// One second of a steady vowel (the filters' start-up is dropped).
    private func steadyVowel(_ vowel: TestVowel) -> [Float] {
        let count = Int(rate)
        let signal = TestSignal.vowel(vowel, sampleRate: rate, count: count + count / 2)
        return Array(signal[(count / 2)...])
    }

    /// A pitch track at the pipeline's frame centres.
    private func periods(_ frequency: Double, count: Int) -> [Float] {
        let frames = (count - configuration.frameSize) / configuration.hopSize + 1
        let points = (0..<frames).map { index in
            PitchTrackPoint(time: (Double(configuration.frameSize / 2) + Double(index * configuration.hopSize)) / rate, frequency: frequency)
        }
        return VoicePeriodTrack.periods(points: points, sampleCount: count, sampleRate: rate)
    }

    private func pitch(_ samples: [Float], at start: Int) -> Double? {
        let analyzer = PitchAnalyzer(configuration: configuration)
        return analyzer.estimate(Array(samples[start ..< start + configuration.frameSize])).frequency
    }

    private func formants(_ samples: [Float], at start: Int) -> FormantMeasurement? {
        let decimator = Decimator(inputSampleRate: rate)
        let analyzer = FormantAnalyzer(
            sampleRate: decimator.outputSampleRate,
            maximumFrameLength: decimator.outputLength(forInputLength: configuration.frameSize)
        )
        return analyzer.analyze(decimator.decimate(Array(samples[start ..< start + configuration.frameSize])))
    }

    @Test("Analysis marks are one period apart")
    func marks() throws {
        let signal = steadyVowel(.maleAH)
        let marks = PitchSynchronousShifter.analysisMarks(samples: signal, periods: [Float](repeating: 400, count: signal.count))
        #expect(marks.count == 120)
        let first = try #require(marks.first)
        #expect(first.position < 400)
        for index in 1..<marks.count {
            #expect(abs(marks[index].position - marks[index - 1].position - 400) < 1e-9)
        }
    }

    @Test(
        "Pitch moves by the factor and formants by the resonance factor",
        arguments: [(7.0, 15.0), (-3.0, 0.0), (0.0, 20.0), (12.0, 10.0)]
    )
    func shifts(semitones: Double, percent: Double) throws {
        let input = steadyVowel(.maleAH)
        let settings = VoicePreviewSettings(pitchSemitones: semitones, resonancePercent: percent)
        let output = PitchSynchronousShifter.shift(
            input,
            periods: periods(120, count: input.count),
            sampleRate: rate,
            pitchFactor: settings.pitchFactor,
            formantFactor: settings.formantFactor
        )
        #expect(output.count == input.count)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.951 })

        let expectedPitch = 120 * settings.pitchFactor
        for start in [20_000, 30_000] {
            let measured = try #require(pitch(output, at: start))
            #expect(abs(measured - expectedPitch) < 2, "pitch \(measured), expected \(expectedPitch)")

            let before = try #require(formants(input, at: start))
            let after = try #require(formants(output, at: start))
            let f1Ratio = after.f1.frequency / before.f1.frequency
            let f2Ratio = after.f2.frequency / before.f2.frequency
            #expect(abs(f2Ratio - settings.formantFactor) < 0.08, "F2 ratio \(f2Ratio)")
            // At very high pitch the harmonics are too sparse to place F1 well.
            if semitones <= 7 {
                #expect(abs(f1Ratio - settings.formantFactor) < 0.1, "F1 ratio \(f1Ratio)")
            }
        }
    }

    @Test("Unvoiced sound passes through unchanged")
    func unvoiced() {
        let noise = TestSignal.noise(count: 20_000, amplitude: 0.2)
        let output = PitchSynchronousShifter.shift(
            noise,
            periods: [Float](repeating: 0, count: noise.count),
            sampleRate: rate,
            pitchFactor: 1.5,
            formantFactor: 1.2
        )
        let difference = zip(output[2_000 ..< 18_000], noise[2_000 ..< 18_000]).map { abs($0 - $1) }.max() ?? 1
        #expect(difference < 0.005)
    }

    @Test("Bad input comes back unchanged")
    func badInput() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        #expect(PitchSynchronousShifter.shift(samples, periods: [0, 0], sampleRate: rate, pitchFactor: 2, formantFactor: 1) == samples)
        #expect(PitchSynchronousShifter.shift(samples, periods: [0, 0, 0], sampleRate: rate, pitchFactor: .nan, formantFactor: 1) == samples)
        #expect(PitchSynchronousShifter.shift([], periods: [], sampleRate: rate, pitchFactor: 2, formantFactor: 1).isEmpty)
        #expect(PitchSynchronousShifter.rms([]) == 0)
    }
}

@Suite("Voice Preview: whole recordings")
struct VoicePreviewSourceTests {
    private let sampleRate = 44_100.0

    /// Three phrases of a vowel with pauses between them.
    private func phrases(_ vowel: TestVowel) -> AudioClip {
        let sound = TestSignal.vowel(vowel, sampleRate: sampleRate, count: Int(0.9 * sampleRate))
        let pause = TestSignal.silence(count: Int(0.6 * sampleRate))
        let samples = (0..<3).flatMap { _ in sound + pause }
        return AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
    }

    @Test("A recording is analyzed and shifted toward a target")
    func endToEnd() throws {
        let clip = phrases(.maleAH)
        let source = VoicePreviewSource.analyze(clip)
        #expect(source.hasEnoughVoice)
        let medianPitch = try #require(source.medianPitch)
        #expect(abs(medianPitch - 120) < 3)
        #expect(abs(Double(source.periods[Int(0.45 * sampleRate)]) - sampleRate / 120) < 10)
        #expect(source.periods[Int(1.2 * sampleRate)] == 0)

        #expect(source.render(VoicePreviewSettings()) == clip)

        let settings = VoicePreviewSettings(pitchSemitones: 7, resonancePercent: 15)
        let shifted = source.render(settings)
        #expect(shifted.samples.count == clip.samples.count)
        let report = TargetClipAnalyzer.analyze(shifted, range: 0...shifted.duration, target: .feminine)
        let shiftedPitch = try #require(report.take.medianPitch)
        #expect(abs(shiftedPitch - 120 * settings.pitchFactor) < 4, "pitch \(shiftedPitch)")
        let originalF2 = try #require(source.f2)
        let shiftedF2 = try #require(report.take.f2)
        let ratio = shiftedF2 / originalF2
        #expect(ratio > 1.06 && ratio < 1.26, "F2 ratio \(ratio)")
    }

    @Test("Silence isn't enough to preview")
    func silence() {
        let source = VoicePreviewSource.analyze(AudioClip(samples: TestSignal.silence(count: 44_100), sampleRate: sampleRate, startTime: 0))
        #expect(!source.hasEnoughVoice)
        #expect(source.medianPitch == nil)
        let empty = VoicePreviewSource.analyze(AudioClip(samples: [], sampleRate: sampleRate, startTime: 0))
        #expect(!empty.hasEnoughVoice)
    }

    @Test("Long recordings are cut to the maximum")
    func maximum() {
        let long = AudioClip(samples: TestSignal.silence(count: Int(25 * 8_000.0)), sampleRate: 8_000, startTime: 0)
        let source = VoicePreviewSource.analyze(long)
        #expect(abs(source.clip.duration - VoicePreviewSource.maximumDuration) < 0.001)
        #expect(source.periods.count == source.clip.samples.count)
    }
}
