import Foundation
import Testing
@testable import VoiceBloom

@Suite("Score scales and references")
struct VoiceReferenceTests {
    @Test("Position runs 0 → 1 from baseline to target, clamped")
    func linearPosition() {
        #expect(ScoreScale.position(of: 5, baseline: 5, target: 11) == 0)
        #expect(ScoreScale.position(of: 11, baseline: 5, target: 11) == 1)
        #expect(ScoreScale.position(of: 8, baseline: 5, target: 11) == 0.5)
        #expect(ScoreScale.position(of: 0, baseline: 5, target: 11) == 0)
        #expect(ScoreScale.position(of: 20, baseline: 5, target: 11) == 1)
    }

    @Test("Works when the target is below the baseline (e.g. tilt)")
    func reversedDirection() {
        #expect(ScoreScale.position(of: -6, baseline: -4, target: -8) == 0.5)
        #expect(ScoreScale.position(of: -2, baseline: -4, target: -8) == 0)
        #expect(ScoreScale.position(of: -10, baseline: -4, target: -8) == 1)
    }

    @Test("Logarithmic scale: the geometric mean is halfway")
    func logarithmicPosition() {
        let middle = (1_500.0 * 1_760).squareRoot()
        #expect(abs(ScoreScale.position(of: middle, baseline: 1_500, target: 1_760, logarithmic: true) - 0.5) < 1e-12)
        #expect(ScoreScale.position(of: 0, baseline: 1_500, target: 1_760, logarithmic: true) == 0)
    }

    @Test("Degenerate scales score zero instead of dividing by zero")
    func degenerate() {
        #expect(ScoreScale.position(of: 5, baseline: 5, target: 5) == 0)
        #expect(ScoreScale.position(of: .nan, baseline: 1, target: 2) == 0)
    }

    @Test("Resonance: baseline values score 0, target values score 100", arguments: ResonanceMode.allCases)
    func resonanceEndpoints(mode: ResonanceMode) {
        let reference = mode.defaultReference
        #expect(reference.score(f2: reference.baselineF2, f3: reference.baselineF3) == 0)
        #expect(abs(reference.score(f2: reference.targetF2, f3: reference.targetF3) - 100) < 1e-9)
        // Targets are brighter (higher) than baselines for every vowel.
        #expect(reference.targetF2 > reference.baselineF2)
        #expect(reference.targetF3 > reference.baselineF3)
    }

    @Test("Resonance without F3 uses F2 alone")
    func resonanceWithoutF3() {
        let reference = ResonanceMode.speech.defaultReference
        #expect(abs(reference.score(f2: reference.targetF2, f3: nil) - 100) < 1e-9)
        #expect(reference.score(f2: reference.baselineF2, f3: nil) == 0)
    }

    @Test("Weight and intonation endpoints")
    func weightAndIntonation() {
        let weight = WeightReference.standard
        #expect(weight.score(h1MinusH2: weight.baselineH1MinusH2, spectralTilt: weight.baselineTilt) == 0)
        #expect(abs(weight.score(h1MinusH2: weight.targetH1MinusH2, spectralTilt: weight.targetTilt) - 100) < 1e-9)
        #expect(abs(weight.score(h1MinusH2: weight.targetH1MinusH2, spectralTilt: nil) - 100) < 1e-9)

        let intonation = IntonationReference.standard
        #expect(intonation.score(standardDeviationSemitones: 2.0) == 0)
        #expect(intonation.score(standardDeviationSemitones: 3.5) == 100)
        #expect(intonation.score(standardDeviationSemitones: 2.75) == 50)
    }

    @Test("Zones")
    func zones() {
        #expect(MeterZone(score: 0) == .low)
        #expect(MeterZone(score: 33.9) == .low)
        #expect(MeterZone(score: 34) == .middle)
        #expect(MeterZone(score: 66.9) == .middle)
        #expect(MeterZone(score: 67) == .high)
        #expect(MeterZone(score: 100) == .high)
    }
}

@Suite("Voice meters")
struct VoiceMetersTests {
    private func formants(f2: Double, f3: Double?) -> FormantMeasurement {
        FormantMeasurement(
            f1: Formant(frequency: 500, bandwidth: 80),
            f2: Formant(frequency: f2, bandwidth: 100),
            f3: f3.map { Formant(frequency: $0, bandwidth: 150) }
        )
    }

    @Test("Rolling window keeps only recent values and reports the median")
    func rollingWindow() {
        var window = RollingWindow(duration: 1.0)
        #expect(window.median == nil)
        window.add(100, at: 0)
        window.add(300, at: 0.5)
        window.add(200, at: 1.0)
        #expect(window.median == 200)
        window.add(400, at: 1.6) // drops 0.0 and 0.5
        #expect(window.values == [200, 400])
        window.add(.nan, at: 1.7)
        #expect(window.values.count == 2)
        window.removeAll()
        #expect(window.isEmpty)
    }

    @Test("Resonance meter: median over the window, live then stale")
    func resonanceMeter() throws {
        var meter = ResonanceMeter(mode: .ee)
        let reference = ResonanceMode.ee.defaultReference
        let result1 = meter.reading(now: 0)
        #expect(result1 == nil)
        meter.add(formants(f2: reference.targetF2, f3: reference.targetF3), at: 0.0)
        meter.add(formants(f2: reference.targetF2, f3: reference.targetF3), at: 0.1)
        // One outlier frame doesn't move the median.
        meter.add(formants(f2: 900, f3: 2_000), at: 0.2)
        let result2 = meter.reading(now: 0.25)
        let live = try #require(result2)
        #expect(abs(live.score - 100) < 1e-9)
        #expect(live.isLive)
        let result3 = meter.reading(now: 3.0)
        let stale = try #require(result3)
        #expect(!stale.isLive)
    }

    @Test("Changing the resonance mode swaps the reference and clears old values")
    func resonanceModeChange() {
        var meter = ResonanceMeter(mode: .speech)
        meter.add(formants(f2: 1_600, f3: 2_600), at: 0)
        meter.setMode(.ee)
        #expect(meter.mode == .ee)
        #expect(meter.reference == ResonanceMode.ee.defaultReference)
        let result4 = meter.reading(now: 0)
        #expect(result4 == nil)
    }

    @Test("Weight meter uses corrected H1–H2 when available")
    func weightMeter() throws {
        var meter = WeightMeter()
        let measurement = WeightMeasurement(h1MinusH2: 0, correctedH1MinusH2: 11, spectralTilt: -8)
        meter.add(measurement, at: 0)
        let result5 = meter.reading(now: 0.1)
        let reading = try #require(result5)
        #expect(reading.h1MinusH2 == 11)
        #expect(abs(reading.score - 100) < 1e-9)
        let result6 = meter.score(for: measurement)
        #expect(abs(result6 - 100) < 1e-9)
    }

    @Test("Intonation meter scores the last phrase and goes stale")
    func intonationMeter() throws {
        var meter = IntonationMeter()
        let phrase = PhraseIntonation(
            startTime: 0, endTime: 2, voicedDuration: 1.8, meanFrequency: 200,
            standardDeviationSemitones: 3.5, rangeSemitones: 8, rises: 3, falls: 2
        )
        let score = meter.add(phrase)
        #expect(score == 100)
        let result7 = meter.reading(now: 3)
        let recent = try #require(result7)
        #expect(recent.isRecent)
        let result8 = meter.reading(now: 20)
        let old = try #require(result8)
        #expect(!old.isRecent)
        meter.reset()
        let result9 = meter.reading(now: 3)
        #expect(result9 == nil)
    }

    @Test("Score average")
    func average() {
        var average = ScoreAverage()
        #expect(average.mean == nil)
        average.add(40)
        average.add(80)
        average.add(.nan)
        #expect(average.mean == 60)
        #expect(average.count == 2)
    }
}

@Suite("Mic calibration analysis")
struct MicCalibrationTests {
    @Test("Percentiles")
    func percentiles() {
        let values: [Double] = [5, 1, 4, 2, 3]
        #expect(MicCalibrationAnalysis.percentile(values, 0.5) == 3)
        #expect(MicCalibrationAnalysis.percentile(values, 0) == 1)
        #expect(MicCalibrationAnalysis.percentile(values, 1) == 5)
        #expect(abs((MicCalibrationAnalysis.percentile(values, 0.1) ?? 0) - 1.4) < 1e-12)
        #expect(MicCalibrationAnalysis.percentile([], 0.5) == nil)
    }

    @Test("Room noise verdicts", arguments: [
        (-72.0, NoiseVerdict.quiet),
        (-60.0, NoiseVerdict.quiet),
        (-55.0, NoiseVerdict.acceptable),
        (-48.0, NoiseVerdict.acceptable),
        (-40.0, NoiseVerdict.tooNoisy),
    ])
    func noiseVerdicts(level: Double, verdict: NoiseVerdict) throws {
        let assessment = try #require(MicCalibrationAnalysis.assessNoise(levels: [Double](repeating: level, count: 400)))
        #expect(assessment.verdict == verdict)
        #expect(assessment.floorDb == level)
        #expect(!assessment.isUnsteady)
    }

    @Test("A brief loud noise doesn't move the floor but is flagged")
    func unsteadyNoise() throws {
        var levels = [Double](repeating: -65, count: 300)
        levels += [Double](repeating: -30, count: 100) // a door slam / passing car
        let assessment = try #require(MicCalibrationAnalysis.assessNoise(levels: levels))
        #expect(assessment.floorDb == -65)
        #expect(assessment.isUnsteady)
        #expect(MicCalibrationAnalysis.assessNoise(levels: []) == nil)
    }

    @Test("Voice level verdicts")
    func voiceVerdicts() throws {
        let good = try #require(MicCalibrationAnalysis.assessVoice(levels: [-25, -24, -26], peakDb: -10, noiseFloorDb: -65))
        #expect(good.verdict == .good)
        #expect(good.signalToNoiseDb == 40)

        let quiet = try #require(MicCalibrationAnalysis.assessVoice(levels: [-50], peakDb: -40, noiseFloorDb: -75))
        #expect(quiet.verdict == .tooQuiet)

        let lowContrast = try #require(MicCalibrationAnalysis.assessVoice(levels: [-40], peakDb: -30, noiseFloorDb: -50))
        #expect(lowContrast.verdict == .tooQuiet)

        let loud = try #require(MicCalibrationAnalysis.assessVoice(levels: [-8], peakDb: -0.5, noiseFloorDb: -60))
        #expect(loud.verdict == .tooLoud)

        #expect(MicCalibrationAnalysis.assessVoice(levels: [], peakDb: -10, noiseFloorDb: -60) == nil)
    }

    @Test("Calibration applies only to the same kind of microphone")
    func appliesToRoute() {
        let calibration = MicCalibration(
            noiseFloorDb: -65, voiceLevelDb: -25, voicePeakDb: -10,
            inputName: "iPhone Microphone", inputKind: .builtInMicrophone, date: Date()
        )
        let builtIn = AudioRouteInfo(inputName: "iPhone Microphone", inputKind: .builtInMicrophone, outputName: "Speaker")
        let headset = AudioRouteInfo(inputName: "Headset Microphone", inputKind: .wiredHeadset, outputName: "Headphones")
        #expect(calibration.applies(to: builtIn))
        #expect(!calibration.applies(to: headset))
        #expect(calibration.signalToNoiseDb == 40)
    }

    @Test("Calibration survives encoding and decoding")
    func codable() throws {
        let calibration = MicCalibration(
            noiseFloorDb: -63.5, voiceLevelDb: -27.25, voicePeakDb: -9,
            inputName: "iPhone Microphone", inputKind: .builtInMicrophone,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(calibration)
        let decoded = try JSONDecoder().decode(MicCalibration.self, from: data)
        #expect(decoded == calibration)
    }

    @Test("Store saves, loads and clears")
    @MainActor
    func store() throws {
        let suite = "VoiceBloomTests.calibration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(MicCalibrationStore.load(from: defaults) == nil)
        let calibration = MicCalibration(
            noiseFloorDb: -70, voiceLevelDb: -30, voicePeakDb: -12,
            inputName: "iPhone Microphone", inputKind: .builtInMicrophone,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        MicCalibrationStore.save(calibration, to: defaults)
        #expect(MicCalibrationStore.load(from: defaults) == calibration)
        MicCalibrationStore.save(nil, to: defaults)
        #expect(MicCalibrationStore.load(from: defaults) == nil)
    }

    @Test("Calibrated noise floor never drops below the measured room level")
    func calibratedFloor() {
        var estimator = NoiseFloorEstimator.calibrated(floorDb: -65)
        for _ in 0..<50 {
            estimator.update(levelDb: -90, elapsed: 0.01)
        }
        #expect(estimator.floorDb == -65)
        // It can still rise if the room gets louder.
        for _ in 0..<100 {
            estimator.update(levelDb: -40, elapsed: 0.01)
        }
        #expect(estimator.floorDb > -65)
    }

    @Test("Only clearly pitched frames above the floor count as the “aah”")
    func voicedFrames() {
        let voiced = FrameFixture.frame(status: .voiced, frequency: 200)
        #expect(MicCalibrationAnalysis.isVoiced(voiced, noiseFloorDb: -60))
        #expect(!MicCalibrationAnalysis.isVoiced(voiced, noiseFloorDb: -25))
        let noise = FrameFixture.frame(status: .unpitched, frequency: nil)
        #expect(!MicCalibrationAnalysis.isVoiced(noise, noiseFloorDb: -60))
    }
}
