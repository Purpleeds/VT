import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

// MARK: - Helpers

/// Frames every `interval` seconds: (duration, pitch at time t or nil, level dB).
private func makeFrames(_ parts: [(Double, ((Double) -> Double)?, Double)], interval: Double = 0.01) -> [ClipFrameSummary] {
    var frames: [ClipFrameSummary] = []
    var index = 0
    for (duration, pitch, level) in parts {
        let count = Int((duration / interval).rounded())
        for _ in 0..<count {
            let time = Double(index) * interval
            frames.append(ClipFrameSummary(time: time, levelDb: level, pitch: pitch.map { $0(time) }))
            index += 1
        }
    }
    return frames
}

/// Pitch that keeps moving like speech: ±2 semitones, 1.5 times a second.
private func speechLike(_ center: Double) -> (Double) -> Double {
    { time in center * pow(2, 2 * sin(2 * Double.pi * 1.5 * time) / 12) }
}

private func steady(_ frequency: Double) -> (Double) -> Double {
    { _ in frequency }
}

private func check(_ frames: [ClipFrameSummary], duration: Double, clipped: Double = 0) -> ClipQualityReport {
    ClipQualityChecker.check(
        frames: frames,
        phrases: VoicedSpans.phrases(frames, frameInterval: 0.01),
        frameInterval: 0.01,
        duration: duration,
        clippedFraction: clipped
    )
}

private func targetTake(pitch: Double = 200, f2: Double? = 2_050, f3: Double? = 2_950, h1MinusH2: Double? = 10, intonationSD: Double? = 3.4) -> TakeResult {
    var histogram = [Double](repeating: 0, count: TakeResult.histogramBinCount)
    if let bin = TakeResult.histogramBin(for: pitch) {
        histogram[bin] = 1
    }
    return TakeResult(
        duration: 20,
        voicedDuration: 12,
        averagePitch: pitch,
        medianPitch: pitch,
        lowPitch: pitch * 0.85,
        highPitch: pitch * 1.25,
        percentInTarget: 60,
        f1: 600,
        f2: f2,
        f3: f3,
        resonanceScore: 70,
        brightResonancePercent: 60,
        h1MinusH2: h1MinusH2,
        spectralTilt: -8,
        weightScore: 70,
        lightWeightPercent: 60,
        intonationSD: intonationSD,
        intonationScore: 70,
        phraseCount: 6,
        contour: [],
        pitchHistogram: histogram
    )
}

private func oneHot(_ bin: Int) -> [Double] {
    var histogram = [Double](repeating: 0, count: TakeResult.histogramBinCount)
    histogram[bin] = 1
    return histogram
}

// MARK: - Phrases and quality

@Suite("Target clip phrases and quality checks")
struct ClipQualityTests {
    @Test("Phrases split at pauses of 0.35 s or more")
    func phrases() throws {
        let split = makeFrames([(1.0, steady(200), -20), (0.5, nil, -70), (1.0, steady(200), -20)])
        let spans = VoicedSpans.phrases(split, frameInterval: 0.01)
        #expect(spans.count == 2)
        let first = try #require(spans.first)
        let second = try #require(spans.last)
        #expect(abs(first.start) < 1e-9)
        #expect(abs(first.end - 1.0) < 1e-9)
        #expect(first.pitches.count == 100)
        #expect(abs(second.start - 1.5) < 1e-9)
        #expect(abs(second.end - 2.5) < 1e-9)

        let joined = makeFrames([(1.0, steady(200), -20), (0.2, nil, -70), (1.0, steady(200), -20)])
        let one = VoicedSpans.phrases(joined, frameInterval: 0.01)
        #expect(one.count == 1)
        #expect(one.first?.pitches.count == 200)
    }

    @Test("Clean solo speech has no warnings")
    func cleanSpeech() {
        var parts: [(Double, ((Double) -> Double)?, Double)] = []
        for _ in 0..<12 {
            parts.append((1.0, speechLike(200), -20))
            parts.append((0.5, nil, -70))
        }
        let report = check(makeFrames(parts), duration: 18)
        #expect(report.warnings.isEmpty)
        #expect(abs(report.voicedSeconds - 12) < 1e-6)
        #expect(report.signalToNoiseDb == 50)
        #expect(report.heldNoteShare == 0)
        #expect((report.speakerSeparationSemitones ?? 0) < 2)
        #expect(!report.hasSeriousWarnings)
    }

    @Test("Two voices at different pitches are flagged")
    func twoSpeakers() throws {
        var parts: [(Double, ((Double) -> Double)?, Double)] = []
        for index in 0..<12 {
            parts.append((1.0, speechLike(index.isMultiple(of: 2) ? 120 : 220), -20))
            parts.append((0.5, nil, -70))
        }
        let report = check(makeFrames(parts), duration: 18)
        #expect(report.warnings == [.multipleSpeakers])
        let separation = try #require(report.speakerSeparationSemitones)
        #expect(abs(separation - 10.49) < 0.1)
        #expect(report.hasSeriousWarnings)
    }

    @Test("Held notes without pauses sound like music")
    func music() {
        let notes = [262.0, 294, 330, 349, 392, 440, 494, 523, 494, 440, 392, 349]
        let parts: [(Double, ((Double) -> Double)?, Double)] = notes.map { (1.0, steady($0), -20) }
        let report = check(makeFrames(parts), duration: 12)
        #expect(report.warnings.contains(.music))
        #expect(report.heldNoteShare == 1)
    }

    @Test("A loud background is flagged as noise")
    func noisy() {
        var parts: [(Double, ((Double) -> Double)?, Double)] = []
        for _ in 0..<12 {
            parts.append((1.0, speechLike(200), -20))
            parts.append((0.5, nil, -28))
        }
        let report = check(makeFrames(parts), duration: 18)
        #expect(report.warnings == [.noisy])
        #expect(report.signalToNoiseDb == 8)
    }

    @Test("Mostly silence is flagged as too little speech")
    func littleSpeech() {
        let parts: [(Double, ((Double) -> Double)?, Double)] = [
            (0.8, speechLike(200), -20), (5.87, nil, -70),
            (0.8, speechLike(200), -20), (5.87, nil, -70),
            (0.8, speechLike(200), -20), (5.87, nil, -70),
        ]
        let report = check(makeFrames(parts), duration: 20)
        #expect(report.warnings == [.littleSpeech])
        #expect(abs(report.voicedSeconds - 2.4) < 1e-6)
    }

    @Test("Selection length and clipping advice")
    func advice() {
        var parts: [(Double, ((Double) -> Double)?, Double)] = []
        for _ in 0..<5 {
            parts.append((1.0, speechLike(200), -20))
            parts.append((0.25, nil, -70))
        }
        let short = check(makeFrames(parts), duration: 6.25)
        #expect(short.warnings == [.shortSelection])
        #expect(!short.hasSeriousWarnings)

        let clipped = check(makeFrames(parts), duration: 6.25, clipped: 0.01)
        #expect(clipped.warnings == [.clipping, .shortSelection])

        #expect(ClipQualityChecker.clippedFraction([0.99, -1, 0.5, 0.1]) == 0.5)
        #expect(ClipQualityChecker.clippedFraction([]) == 0)
    }

    @Test("Held-note share separates sung notes from moving speech")
    func heldNotes() {
        #expect(ClipQualityChecker.heldNoteShare(makeFrames([(1.0, steady(200), -20)]), frameInterval: 0.01) == 1)
        let shortNotes: [(Double, ((Double) -> Double)?, Double)] = [200.0, 240, 200, 240, 200, 240].map { (0.3, steady($0), -20) }
        #expect(ClipQualityChecker.heldNoteShare(makeFrames(shortNotes), frameInterval: 0.01) == 0)
        #expect(ClipQualityChecker.heldNoteShare([], frameInterval: 0.01) == 0)
    }

    @Test("Too few frames or phrases give no estimate")
    func notEnoughData() {
        let few = makeFrames([(0.05, steady(200), -20)])
        #expect(ClipQualityChecker.signalToNoise(few) == nil)
        let spans = VoicedSpans.phrases(makeFrames([(1.0, steady(200), -20), (0.5, nil, -70), (1.0, steady(120), -20)]), frameInterval: 0.01)
        #expect(ClipQualityChecker.speakerSplit(spans).map { $0.separation } == nil)
    }
}

// MARK: - Shadowing, trimming, waveform

@Suite("Shadowing segments, trimming and waveform")
struct TargetClipEditingTests {
    private func span(_ start: Double, _ end: Double) -> VoicedSpan {
        VoicedSpan(start: start, end: end, pitches: [200])
    }

    @Test("Phrases are grouped into pieces of up to 6 seconds")
    func segments() {
        let phrases = [span(0.5, 2.0), span(2.6, 4.0), span(4.6, 9.5), span(10.2, 10.6)]
        let segments = ShadowingSegmenter.segments(phrases: phrases, clipDuration: 12)
        #expect(segments.count == 2)
        #expect(abs(segments[0].start - 0.3) < 1e-9)
        #expect(abs(segments[0].end - 4.2) < 1e-9)
        #expect(abs(segments[1].start - 4.4) < 1e-9)
        #expect(abs(segments[1].end - 10.8) < 1e-9)
        #expect(segments.map(\.index) == [0, 1])
    }

    @Test("Very short phrases are skipped and the clip end is respected")
    func segmentEdges() {
        let segments = ShadowingSegmenter.segments(phrases: [span(0.0, 0.5), span(8.0, 10.0)], clipDuration: 10.1)
        #expect(segments.count == 1)
        #expect(abs((segments.first?.start ?? 0) - 7.8) < 1e-9)
        #expect(abs((segments.first?.end ?? 0) - 10.1) < 1e-9)
        #expect(ShadowingSegmenter.segments(phrases: [], clipDuration: 5).isEmpty)
    }

    @Test("A long phrase is cut at the maximum length")
    func longPhrase() {
        let segments = ShadowingSegmenter.segments(phrases: [span(1, 12)], clipDuration: 20)
        #expect(segments.count == 1)
        #expect(abs((segments.first?.duration ?? 0) - 6.4) < 1e-9)
    }

    @Test("The first 30 seconds are selected to start with")
    func initialSelection() {
        let long = TrimSelection.initial(clipDuration: 200)
        #expect(long.start == 0)
        #expect(long.end == 30)
        let short = TrimSelection.initial(clipDuration: 12)
        #expect(short.end == 12)
        let tiny = TrimSelection.initial(clipDuration: 2)
        #expect(tiny.length == 2)
    }

    @Test("Handles keep at least 3 s and at most 120 s")
    func handles() {
        var selection = TrimSelection(clipDuration: 200, start: 0, end: 30)
        selection.setStart(29)
        #expect(selection.start == 27)
        selection.setEnd(5)
        #expect(selection.end == 30)
        selection.setEnd(500)
        #expect(selection.end == 147)
        selection.setStart(0)
        #expect(selection.start == 27)
        selection.setStart(-5)
        #expect(selection.start == 27)

        var reversed = TrimSelection(clipDuration: 50, start: 40, end: 10)
        #expect(reversed.start == 10)
        #expect(reversed.end == 40)
        reversed.setEnd(60)
        #expect(reversed.end == 50)

        var tiny = TrimSelection(clipDuration: 2)
        tiny.setStart(1)
        #expect(tiny.start == 0)
        #expect(tiny.end == 2)
    }

    @Test("Waveform peaks are the loudest sample per slice, scaled to 1")
    func peaks() {
        #expect(WaveformSummary.peaks([0, 0.5, -1, 0.25], bucketCount: 2) == [0.5, 1])
        #expect(WaveformSummary.peaks([0.2, -0.4, 0.1], bucketCount: 6) == [0.5, 0.5, 1, 1, 0.25, 0.25])
        #expect(WaveformSummary.peaks([0, 0], bucketCount: 2) == [0, 0])
        #expect(WaveformSummary.peaks([], bucketCount: 4).isEmpty)
    }

    @Test("Shadowing contours are timed from the segment start")
    func materialContour() {
        let clip = AudioClip(samples: [0, 0], sampleRate: 44_100, startTime: 0)
        let points = [0.5, 1.0, 1.5, 2.0, 2.5].map { PitchContourPoint(time: $0, frequency: 200 + $0) }
        let segment = ShadowingSegment(index: 0, start: 0.9, end: 2.1)
        let material = ShadowingMaterial(clip: clip, contour: points, segments: [segment])
        let sliced = material.contour(for: segment)
        #expect(sliced.count == 3)
        #expect(abs((sliced.first?.time ?? 0) - 0.1) < 1e-9)
        #expect(sliced.first?.frequency == 201)
    }
}

// MARK: - Matching

@Suite("Compare to Target and target suggestions")
struct TargetMatchingTests {
    @Test("Histogram overlap counts near misses")
    func overlap() throws {
        let same = try #require(TargetComparison.histogramOverlap(oneHot(20), oneHot(20)))
        #expect(same > 0.999)
        let neighbour = try #require(TargetComparison.histogramOverlap(oneHot(20), oneHot(21)))
        #expect(abs(neighbour - 0.5) < 1e-9)
        let apart = try #require(TargetComparison.histogramOverlap(oneHot(20), oneHot(25)))
        #expect(apart == 0)
        #expect(TargetComparison.histogramOverlap([], oneHot(3)) == nil)
        #expect(TargetComparison.histogramOverlap([0, 0, 0], [0, 1, 0]) == nil)
    }

    @Test("Ratio and difference matches")
    func scales() {
        #expect(abs(TargetComparison.ratioMatch(1_850, 2_050, tolerance: 1.25) - 53.996) < 0.01)
        #expect(TargetComparison.ratioMatch(2_050, 2_050, tolerance: 1.25) == 100)
        #expect(TargetComparison.ratioMatch(1_000, 2_050, tolerance: 1.25) == 0)
        #expect(TargetComparison.differenceMatch(6, 10, tolerance: 8) == 50)
        #expect(abs(TargetComparison.ratioMatch(2, 4, tolerance: 2.5) - 24.353) < 0.01)
    }

    @Test("Every category gets a match, and the overall is their average")
    func categories() throws {
        let target = VoiceSnapshot(pitchHistogram: oneHot(20), medianPitch: 200, f2: 2_050, f3: 2_900, h1MinusH2: 10, intonationSD: 4)
        let user = VoiceSnapshot(pitchHistogram: oneHot(21), medianPitch: 212, f2: 1_850, f3: 2_900, h1MinusH2: 6, intonationSD: 2)
        let matches = TargetComparison.matches(user: user, target: target)
        #expect(matches.map(\.category) == [.pitch, .resonance, .weight, .intonation])
        let byCategory = Dictionary(uniqueKeysWithValues: matches.map { ($0.category, $0.percent) })
        #expect(abs((byCategory[.pitch] ?? 0) - 50) < 1e-6)
        #expect(abs((byCategory[.resonance] ?? 0) - 72.398) < 0.01)
        #expect(abs((byCategory[.weight] ?? 0) - 50) < 1e-6)
        #expect(abs((byCategory[.intonation] ?? 0) - 24.353) < 0.01)
        let overall = try #require(TargetComparison.overall(matches))
        #expect(abs(overall - (50 + 72.398 + 50 + 24.353) / 4) < 0.01)
        #expect(matches.first?.detail == "You 212 Hz · target 200 Hz")
    }

    @Test("Pitch falls back to the median without histograms")
    func pitchFallback() {
        let matches = TargetComparison.matches(user: VoiceSnapshot(medianPitch: 200), target: VoiceSnapshot(medianPitch: 200 * pow(2, 3.0 / 12)))
        #expect(matches.count == 1)
        #expect(abs((matches.first?.percent ?? 0) - 50) < 1e-6)
        #expect(TargetComparison.overall([]) == nil)
    }

    @Test("Suggested targets are centered on the voice and kept in range")
    func suggestions() {
        let typical = TargetSuggestion(medianPitch: 200, f2: 1_873, f3: 2_955, h1MinusH2: 9.3, intonationSD: 3.4)
        #expect(typical.pitchZone == PitchTargetZone(lowerBound: 180, upperBound: 225))
        #expect(typical.f2 == 1_870)
        #expect(typical.f3 == 2_960)
        #expect(typical.h1MinusH2 == 9.5)
        #expect(typical.intonationSD == 3.5)
        #expect(!typical.isEmpty)

        #expect(TargetSuggestion.zone(around: 120) == PitchTargetZone(lowerBound: 105, upperBound: 135))
        #expect(TargetSuggestion.zone(around: 400) == PitchTargetZone(lowerBound: 340, upperBound: 350))
        #expect(TargetSuggestion.zone(around: 70) == PitchTargetZone(lowerBound: 90, upperBound: 100))
        #expect(TargetSuggestion.zone(around: 0) == nil)

        let extreme = TargetSuggestion(medianPitch: nil, f2: 2_900, f3: 1_000, h1MinusH2: 30, intonationSD: 9)
        #expect(extreme.pitchZone == nil)
        #expect(extreme.f2 == 2_400)
        #expect(extreme.f3 == 2_400)
        #expect(extreme.h1MinusH2 == 16)
        #expect(extreme.intonationSD == 6)
        #expect(TargetSuggestion(medianPitch: nil, f2: nil, f3: nil, h1MinusH2: nil, intonationSD: nil).isEmpty)
    }

    @Test("Contour shape ignores pitch level and speed")
    func contours() throws {
        let target = (0..<30).map { PitchContourPoint(time: 2 * Double($0) / 29, frequency: 200 + 50 * Double($0) / 29) }
        let user = (0..<30).map { PitchContourPoint(time: 0.4 + 2.5 * Double($0) / 29, frequency: (200 + 50 * Double($0) / 29) * pow(2, -3.0 / 12)) }
        let same = ContourComparison.compare(target: target, user: user)
        let shape = try #require(same.shapeMatch)
        #expect(shape > 99.9)
        let level = try #require(same.levelDifference)
        #expect(abs(level + 3) < 1e-9)

        let falling = (0..<30).map { PitchContourPoint(time: 2 * Double($0) / 29, frequency: 250 - 50 * Double($0) / 29) }
        #expect(ContourComparison.compare(target: target, user: falling).shapeMatch == 0)

        let flat = (0..<30).map { PitchContourPoint(time: 2 * Double($0) / 29, frequency: 200) }
        let flatResult = ContourComparison.compare(target: target, user: flat)
        #expect(flatResult.shapeMatch == nil)
        #expect(flatResult.levelDifference != nil)

        let tooShort = ContourComparison.compare(target: target, user: Array(user.prefix(3)))
        #expect(tooShort.shapeMatch == nil)
        #expect(ContourComparison.compare(target: [], user: []).levelDifference == nil)
    }
}

// MARK: - Full analysis and decoding

@Suite("Target clip analysis on synthetic voices")
struct TargetClipAnalyzerTests {
    private let sampleRate = TargetClipAnalyzer.sampleRate

    /// Phrases of the given vowels, each followed by a pause.
    private func clip(_ vowels: [TestVowel]) -> AudioClip {
        let phrase = Int(0.9 * sampleRate)
        let pause = TestSignal.silence(count: Int(0.6 * sampleRate))
        var cache: [String: [Float]] = [:]
        var samples: [Float] = []
        for vowel in vowels {
            let sound = cache[vowel.name] ?? TestSignal.vowel(vowel, sampleRate: sampleRate, count: phrase)
            cache[vowel.name] = sound
            samples += sound + pause
        }
        return AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
    }

    @Test("One voice gives its pitch and formants, and shadowing phrases")
    func singleVoice() throws {
        let audio = clip(Array(repeating: TestVowel.femaleAE, count: 4))
        let report = TargetClipAnalyzer.analyze(audio, range: 0...audio.duration, target: .feminine)
        let pitch = try #require(report.take.medianPitch)
        #expect(abs(pitch - 220) < 4)
        let f2 = try #require(report.take.f2)
        #expect(abs(f2 - 2_050) / 2_050 < 0.15)
        #expect(!report.quality.warnings.contains(.multipleSpeakers))
        #expect(!report.quality.warnings.contains(.noisy))
        #expect(report.quality.voicedSeconds > 2.5)
        #expect(!report.segments.isEmpty)
        #expect(abs(report.duration - audio.duration) < 0.001)
    }

    @Test("Alternating low and high voices are flagged as two speakers")
    func twoVoices() {
        let vowels = (0..<8).map { $0.isMultiple(of: 2) ? TestVowel.maleAH : TestVowel.femaleAH }
        let audio = clip(vowels)
        let report = TargetClipAnalyzer.analyze(audio, range: 0...audio.duration, target: .feminine)
        #expect(report.quality.warnings.contains(.multipleSpeakers))
    }

    @Test("Only the selected range is analyzed")
    func range() {
        let audio = clip(Array(repeating: TestVowel.femaleAE, count: 4))
        let report = TargetClipAnalyzer.analyze(audio, range: 0...1.5, target: .feminine)
        #expect(abs(report.duration - 1.5) < 0.001)
        let section = TargetClipAnalyzer.section(of: audio, range: 1...2)
        #expect(section.samples.count == Int(sampleRate))
        let clamped = TargetClipAnalyzer.section(of: audio, range: 100...200)
        #expect(clamped.samples.isEmpty)
    }

    @Test("Audio files decode to mono at 44.1 kHz")
    func decodeFile() async throws {
        let rate = 44_100.0
        let samples = TestSignal.sine(frequency: 220, sampleRate: rate, count: Int(3 * rate), amplitude: 0.3)
        let url = TargetImportFiles.temporaryURL(pathExtension: "m4a")
        defer { TargetImportFiles.remove(url) }
        try RecordingFileStore.write(AudioClip(samples: samples, sampleRate: rate, startTime: 0), to: url)

        let decoded = try await AudioFileDecoder.decode(url: url)
        #expect(decoded.audio.sampleRate == 44_100)
        #expect(abs(decoded.audio.duration - 3) < 0.15)
        #expect(!decoded.wasShortened)
        let peak = decoded.audio.samples.map { abs($0) }.max() ?? 0
        #expect(abs(peak - 0.3) < 0.08)
    }

    @Test("Missing or unreadable files throw friendly errors")
    func decodeErrors() async {
        let missing = TargetImportFiles.temporaryURL(pathExtension: "mp3")
        await #expect(throws: TargetImportError.self) {
            try await AudioFileDecoder.decode(url: missing)
        }
        let text = TargetImportFiles.temporaryURL(pathExtension: "wav")
        defer { TargetImportFiles.remove(text) }
        try? Data("not audio".utf8).write(to: text)
        await #expect(throws: TargetImportError.self) {
            try await AudioFileDecoder.decode(url: text)
        }
    }
}

// MARK: - Storage

@MainActor
@Suite("Target voice storage", .serialized)
struct TargetVoiceStoreTests {
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    private var context: ModelContext { container.mainContext }

    private func report(pitch: Double = 200) -> TargetClipReport {
        TargetClipReport(
            take: targetTake(pitch: pitch),
            quality: ClipQualityReport(warnings: [], voicedSeconds: 12, signalToNoiseDb: 40, heldNoteShare: 0, speakerSeparationSemitones: nil),
            segments: [],
            duration: 20
        )
    }

    private func audio(seconds: Double = 2) -> AudioClip {
        let rate = 44_100.0
        return AudioClip(samples: TestSignal.sine(frequency: 200, sampleRate: rate, count: Int(seconds * rate), amplitude: 0.3), sampleRate: rate, startTime: 0)
    }

    @Test("Saving keeps the profile and the trimmed clip")
    func save() async throws {
        let store = TargetVoiceStore(context: context)
        let profile = try await store.save(name: "  Podcast host  ", report: report(), clip: audio(seconds: 3), range: 1...2.5)
        #expect(profile.name == "Podcast host")
        #expect(profile.averagePitch == 200)
        #expect(profile.averageF2 == 2_050)
        #expect(profile.pitchHistogram.count == TakeResult.histogramBinCount)
        #expect(profile.clipStart == 1)
        #expect(profile.clipEnd == 2.5)
        let url = try #require(profile.clipFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let saved = try RecordingFileStore.readSamples(from: url)
        #expect(abs(saved.duration - 1.5) < 0.1)

        let unnamed = try await store.save(name: "   ", report: report(), clip: audio(), range: 0...2)
        #expect(unnamed.name == "Target voice 2")
        #expect(store.profiles().count == 2)

        try store.delete(profile, user: nil)
        try store.delete(unnamed, user: nil)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.profiles().isEmpty)
    }

    @Test("Using a profile sets the targets, and only one is active")
    func activate() async throws {
        let user = ProfileStore(context: context).profile()
        let store = TargetVoiceStore(context: context)
        let first = try await store.save(name: "A", report: report(pitch: 200), clip: audio(), range: 0...2)
        let second = try await store.save(name: "B", report: report(pitch: 180), clip: audio(), range: 0...2)

        try store.activate(first, for: user, applyTargets: true)
        #expect(first.isActive)
        #expect(!second.isActive)
        #expect(user.activeTargetVoiceProfileID == first.id)
        #expect(user.targetZone == PitchTargetZone(lowerBound: 180, upperBound: 225))
        #expect(user.goalType == .custom)
        #expect(user.targetF2 == 2_050)
        #expect(user.targetF3 == 2_950)
        #expect(user.targetH1MinusH2 == 10)
        #expect(user.targetIntonationSD == 3.5)

        // Switching without applying keeps the targets.
        try store.activate(second, for: user, applyTargets: false)
        #expect(second.isActive)
        #expect(!first.isActive)
        #expect(user.targetZone == PitchTargetZone(lowerBound: 180, upperBound: 225))

        try store.delete(second, user: user)
        #expect(user.activeTargetVoiceProfileID == nil)
        try store.deactivate(for: user)
        #expect(store.profiles().allSatisfy { !$0.isActive })
        try store.delete(first, user: user)
    }

    @Test("Renaming trims and ignores empty names")
    func rename() async throws {
        let store = TargetVoiceStore(context: context)
        let profile = try await store.save(name: "Old", report: report(), clip: audio(), range: 0...2)
        try store.rename(profile, to: "  New name ")
        #expect(profile.name == "New name")
        try store.rename(profile, to: "   ")
        #expect(profile.name == "New name")
        try store.delete(profile, user: nil)
    }
}
