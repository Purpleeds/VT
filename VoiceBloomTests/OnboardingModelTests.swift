import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

@Suite("PersonalReferences")
struct PersonalReferencesTests {
    @Test("Without personal values the defaults are used")
    func defaults() {
        let references = PersonalReferences.none
        #expect(references.resonance(for: .speech) == ResonanceMode.speech.defaultReference)
        #expect(references.resonance(for: .ee) == ResonanceMode.ee.defaultReference)
        #expect(references.weight == WeightReference.standard)
        #expect(references.intonation == IntonationReference.standard)
    }

    @Test("A baseline replaces the speech starting point")
    func speechBaseline() {
        let references = PersonalReferences(baselineF2: 1_550, baselineF3: 2_550)
        let speech = references.resonance(for: .speech)
        #expect(speech.baselineF2 == 1_550)
        #expect(speech.baselineF3 == 2_550)
        #expect(speech.targetF2 == ResonanceMode.speech.defaultReference.targetF2)
    }

    @Test("A baseline already near the target keeps a minimum gap")
    func minimumGap() {
        let references = PersonalReferences(baselineF2: 1_720, targetF2: 1_760)
        let speech = references.resonance(for: .speech)
        #expect(speech.baselineF2 == 1_760 - PersonalReferences.minimumF2Gap)
    }

    @Test("Held vowels are scaled by the same ratio as speech")
    func vowelScaling() {
        let references = PersonalReferences(baselineF2: 1_650, targetF2: 1_936)
        let ee = references.resonance(for: .ee)
        let defaults = ResonanceMode.ee.defaultReference
        #expect(abs(ee.baselineF2 - defaults.baselineF2 * 1.1) < 1e-9)
        #expect(abs(ee.targetF2 - defaults.targetF2 * 1.1) < 1e-9)
        #expect(ee.baselineF3 == defaults.baselineF3)
    }

    @Test("Weight and intonation use personal values with a minimum gap")
    func weightAndIntonation() {
        let references = PersonalReferences(baselineH1MinusH2: 7, baselineIntonationSD: 2.4, targetIntonationSD: 4)
        #expect(references.weight.baselineH1MinusH2 == 7)
        #expect(references.weight.targetH1MinusH2 == WeightReference.standard.targetH1MinusH2)
        #expect(references.intonation.baselineStandardDeviation == 2.4)
        #expect(references.intonation.targetStandardDeviation == 4)

        let close = PersonalReferences(baselineH1MinusH2: 10.5, baselineIntonationSD: 3.3)
        #expect(close.weight.baselineH1MinusH2 == WeightReference.standard.targetH1MinusH2 - PersonalReferences.minimumH1MinusH2Gap)
        #expect(abs(close.intonation.baselineStandardDeviation - (IntonationReference.standard.targetStandardDeviation - PersonalReferences.minimumIntonationGap)) < 1e-9)
    }
}

@Suite("PlacementScoring")
struct PlacementScoringTests {
    @Test("A tone matches within ±10 Hz")
    func matching() {
        #expect(PlacementScoring.isMatch(sung: 196, target: 196))
        #expect(PlacementScoring.isMatch(sung: 205.5, target: 196))
        #expect(!PlacementScoring.isMatch(sung: 207, target: 196))
        #expect(!PlacementScoring.isMatch(sung: 98, target: 196))
        #expect(!PlacementScoring.isMatch(sung: nil, target: 196))
    }

    @Test("Phases are skipped only in order")
    func recommendedWeek() {
        var result = PlacementResult(pitchMatches: 3, pitchAttempts: 5)
        #expect(PlacementScoring.recommendedWeek(for: result) == 1)

        result.pitchMatches = 4
        result.brightResonancePercent = 50
        #expect(PlacementScoring.recommendedWeek(for: result) == 3)

        result.brightResonancePercent = 70
        result.readingInTarget = 40
        result.readingResonance = 70
        #expect(PlacementScoring.recommendedWeek(for: result) == 7)

        result.readingInTarget = 60
        result.readingWeight = 50
        result.readingIntonation = 60
        #expect(PlacementScoring.recommendedWeek(for: result) == 10)

        result.readingWeight = 60
        #expect(PlacementScoring.recommendedWeek(for: result) == 12)

        // Great reading can't skip the resonance phase without a bright "ee".
        result.brightResonancePercent = 30
        #expect(PlacementScoring.recommendedWeek(for: result) == 3)

        #expect(PlacementScoring.recommendedWeek(for: PlacementResult()) == 1)
    }

    @Test("Every week has an explanation")
    func explanations() {
        for week in [1, 3, 7, 10, 12] {
            #expect(!PlacementScoring.explanation(forWeek: week).isEmpty)
        }
    }
}

@Suite("TakeAnalyzer")
struct TakeAnalyzerTests {
    private let configuration = AnalysisConfiguration()
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

    private func analyze(_ signal: [Float], mode: ResonanceMode = .speech) -> TakeResult {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        var analyzer = TakeAnalyzer(target: target, resonanceMode: mode, frameInterval: configuration.hopDuration)
        for frame in pipeline.process(signal) {
            analyzer.add(frame)
        }
        return analyzer.result()
    }

    @Test("A steady tone: pitch, time in target, contour and histogram")
    func steadyTone() throws {
        let result = analyze(TestSignal.sawtooth(frequency: 200, count: 96_000))
        let average = try #require(result.averagePitch)
        let median = try #require(result.medianPitch)
        #expect(abs(average - 200) < 2)
        #expect(abs(median - 200) < 2)
        #expect(result.percentInTarget == 100)
        #expect(result.voicedDuration > 1.8)
        #expect(result.contour.count == Int((result.voicedDuration / configuration.hopDuration).rounded()))
        let bin = try #require(TakeResult.histogramBin(for: 200))
        #expect(result.pitchHistogram[bin] > 0.95)
        #expect(abs(result.pitchHistogram.reduce(0, +) - 1) < 1e-9)
        #expect(result.phraseCount == 1)
    }

    @Test("A bright female “ee” scores bright resonance")
    func brightVowel() throws {
        let result = analyze(TestSignal.vowel(.femaleEE, count: 96_000), mode: .ee)
        let f2 = try #require(result.f2)
        #expect(abs(f2 - 2_790) < 200)
        let bright = try #require(result.brightResonancePercent)
        #expect(bright > 60)
        let resonance = try #require(result.resonanceScore)
        #expect(resonance > 67)
        #expect(result.h1MinusH2 != nil)
        #expect(result.weightScore != nil)
    }

    @Test("A male “ee” scores darker than a female one")
    func darkVowel() throws {
        let male = analyze(TestSignal.vowel(.maleEE, count: 96_000), mode: .ee)
        let female = analyze(TestSignal.vowel(.femaleEE, count: 96_000), mode: .ee)
        let maleScore = try #require(male.resonanceScore)
        let femaleScore = try #require(female.resonanceScore)
        #expect(maleScore + 30 < femaleScore)
    }

    @Test("Silence has no voice")
    func silence() {
        let result = analyze(TestSignal.silence(count: 24_000))
        #expect(!result.hasVoice)
        #expect(result.averagePitch == nil)
        #expect(result.percentInTarget == nil)
        #expect(result.pitchHistogram.allSatisfy { $0 == 0 })
        #expect(result.duration > 0)
    }

    @Test("An empty take")
    func empty() {
        let analyzer = TakeAnalyzer(target: target, frameInterval: 0.01)
        let result = analyzer.result()
        #expect(result.duration == 0)
        #expect(!result.hasVoice)
        #expect(result.intonationSD == nil)
    }

    @Test("Percentiles and histogram bins")
    func helpers() {
        #expect(TakeAnalyzer.percentile([10, 20, 30, 40, 50], 0.5) == 30)
        #expect(TakeAnalyzer.percentile([10, 20, 30, 40, 50], 0) == 10)
        #expect(TakeAnalyzer.percentile([10, 20, 30, 40, 50], 1) == 50)
        #expect(TakeAnalyzer.percentile([], 0.5) == nil)
        #expect(TakeResult.histogramBin(for: 60) == 0)
        #expect(TakeResult.histogramBin(for: 959) == 47)
        #expect(TakeResult.histogramBin(for: 960) == nil)
        #expect(TakeResult.histogramBin(for: 50) == nil)
        #expect(abs(TakeResult.histogramFrequency(forBin: 12) - 120) < 1e-9)
    }
}

@Suite("ToneSynthesis")
struct ToneSynthesisTests {
    @Test("A note has the right length, level and pitch", arguments: [ToneTimbre.pure, .warm])
    func note(timbre: ToneTimbre) throws {
        let samples = ToneSynthesis.note(frequency: 220, duration: 1, sampleRate: 48_000, timbre: timbre)
        #expect(samples.count == 48_000)
        #expect(samples.allSatisfy { abs($0) <= 0.31 })
        let configuration = AnalysisConfiguration()
        let estimate = PitchAnalyzer(configuration: configuration).estimate(Array(samples[12_000 ..< 12_000 + configuration.frameSize]))
        let frequency = try #require(estimate.frequency)
        #expect(abs(frequency - 220) < 2)
    }

    @Test("A loop holds whole cycles, so it repeats without a click")
    func loop() {
        let samples = ToneSynthesis.loop(frequency: 196.5, sampleRate: 48_000)
        #expect(samples.count == 48_122)
        // The step from the last sample back to the first is no bigger than
        // any other step between neighbors.
        let largestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let wrapStep = abs(samples[0] - (samples.last ?? 0))
        #expect(wrapStep <= largestStep * 1.01)
    }

    @Test("Bad input gives silence")
    func badInput() {
        #expect(ToneSynthesis.note(frequency: 0, duration: 1, sampleRate: 48_000).isEmpty)
        #expect(ToneSynthesis.note(frequency: 220, duration: 0, sampleRate: 48_000).isEmpty)
        #expect(ToneSynthesis.loop(frequency: -1, sampleRate: 48_000).isEmpty)
    }
}

/// Baseline and placement storage, in an in-memory store.
@MainActor
@Suite("Onboarding storage", .serialized)
struct OnboardingStorageTests {
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    private var context: ModelContext { container.mainContext }

    private func take(median: Double, low: Double, high: Double, f2: Double, voiced: Double, intonationSD: Double?) -> TakeResult {
        TakeResult(
            duration: voiced + 2,
            voicedDuration: voiced,
            averagePitch: median,
            medianPitch: median,
            lowPitch: low,
            highPitch: high,
            percentInTarget: 10,
            f1: 500,
            f2: f2,
            f3: 2_500,
            resonanceScore: 20,
            brightResonancePercent: 5,
            h1MinusH2: 4,
            spectralTilt: -5,
            weightScore: 30,
            intonationSD: intonationSD,
            intonationScore: 25,
            phraseCount: 3,
            contour: [],
            pitchHistogram: []
        )
    }

    @Test("The baseline sets profile values, weighted by voiced time")
    func baselineValues() throws {
        let profile = ProfileStore(context: context).profile()
        let reading = take(median: 120, low: 100, high: 160, f2: 1_500, voiced: 10, intonationSD: 2)
        let speech = take(median: 130, low: 95, high: 170, f2: 1_600, voiced: 30, intonationSD: 3)
        profile.applyBaseline(reading: reading, speech: speech, recordingID: nil)

        let pitch = try #require(profile.baselinePitch)
        #expect(abs(pitch - 127.5) < 1e-9)
        #expect(profile.baselinePitchLow == 95)
        #expect(profile.baselinePitchHigh == 170)
        let f2 = try #require(profile.baselineF2)
        #expect(abs(f2 - 1_575) < 1e-9)
        let intonation = try #require(profile.baselineIntonationSD)
        #expect(abs(intonation - 2.75) < 1e-9)
        #expect(profile.hasBaseline)
        #expect(profile.personalReferences.baselineF2 == profile.baselineF2)
    }

    @Test("Saving the baseline stores a baseline session")
    func baselineSession() async throws {
        let profile = ProfileStore(context: context).profile()
        let reading = BaselineStore.Take(result: take(median: 120, low: 100, high: 160, f2: 1_500, voiced: 10, intonationSD: 2), audio: nil, transcript: nil)
        let session = try await BaselineStore.save(
            reading: reading,
            speech: nil,
            target: .feminine,
            profile: profile,
            updatesProfile: true,
            context: context
        )
        #expect(session.kind == .baseline)
        #expect(session.isFinished)
        #expect(session.averagePitch == 120)
        #expect(profile.baselinePitch == 120)
        let sessions = try context.fetchCount(FetchDescriptor<PracticeSession>())
        #expect(sessions == 1)
    }

    @Test("A re-recording doesn't change the Day 1 values")
    func reRecording() async throws {
        let profile = ProfileStore(context: context).profile()
        profile.baselinePitch = 118
        let later = BaselineStore.Take(result: take(median: 190, low: 170, high: 230, f2: 1_750, voiced: 20, intonationSD: 3.5), audio: nil, transcript: nil)
        try await BaselineStore.save(reading: later, speech: nil, target: .feminine, profile: profile, updatesProfile: false, context: context)
        #expect(profile.baselinePitch == 118)
    }

    @Test("Placement unlocks the recommended week and those before it")
    func placementUnlocks() throws {
        try PlacementStore.apply(week: 7, result: PlacementResult(pitchMatches: 5, pitchAttempts: 5), context: context)
        let progress = try context.fetch(FetchDescriptor<LessonProgress>(sortBy: [SortDescriptor(\.week)]))
        #expect(progress.map(\.week) == Array(1...7))
        #expect(progress.allSatisfy { $0.unlockedDate != nil })

        // Applying again doesn't duplicate weeks.
        try PlacementStore.apply(week: 3, result: PlacementResult(), context: context)
        let count = try context.fetchCount(FetchDescriptor<LessonProgress>())
        #expect(count == 7)
        #expect(AppPreferences.placementWeek == 3)
    }

    @Test("Goals set their default pitch targets")
    func goals() {
        let profile = ProfileStore(context: context).profile()
        profile.setGoal(.androgynous)
        #expect(profile.targetZone == .androgynous)
        profile.targetPitchLow = 170
        profile.setGoal(.custom)
        #expect(profile.targetPitchLow == 170)
        #expect(profile.goalType == .custom)
        profile.setGoal(.feminine)
        #expect(profile.targetZone == .feminine)
    }
}
