import Foundation
import Testing
@testable import VoiceBloom

@Suite("IntonationAnalyzer")
struct IntonationAnalyzerTests {
    private let frameInterval = 512.0 / 48_000

    /// Pitch contour frames: `voiced(t)` says whether to voice the frame at time t.
    private func phrases(
        duration: Double,
        voiced: (Double) -> Bool,
        pitch: (Double) -> Double
    ) -> [PhraseIntonation] {
        var analyzer = IntonationAnalyzer(frameInterval: frameInterval)
        var completed: [PhraseIntonation] = []
        let frameCount = Int((duration / frameInterval).rounded())
        for index in 0..<frameCount {
            let time = Double(index) * frameInterval
            if let phrase = analyzer.process(time: time, frequency: voiced(time) ? pitch(time) : nil) {
                completed.append(phrase)
            }
        }
        return completed
    }

    @Test("A monotone phrase has no variability and no movements")
    func monotone() throws {
        let count = Int((1.5 / frameInterval).rounded())
        let times = (0..<count).map { Double($0) * frameInterval }
        let phrase = try #require(IntonationAnalyzer.summarize(
            times: times,
            frequencies: [Double](repeating: 200, count: count),
            frameInterval: frameInterval
        ))
        #expect(phrase.standardDeviationSemitones < 1e-9)
        #expect(phrase.rises == 0)
        #expect(phrase.falls == 0)
        #expect(abs(phrase.meanFrequency - 200) < 1e-6)
        #expect(abs(phrase.voicedDuration - 1.5) < 0.02)
    }

    @Test("A ±3 semitone melody: SD ≈ 3/√2, range 6, 3 rises and 2 falls")
    func sinusoidalMelody() throws {
        let count = Int((2.0 / frameInterval).rounded())
        let times = (0..<count).map { Double($0) * frameInterval }
        let frequencies = times.map { 200 * pow(2, 3 * sin(2 * Double.pi * $0) / 12) }
        let phrase = try #require(IntonationAnalyzer.summarize(times: times, frequencies: frequencies, frameInterval: frameInterval))
        #expect(abs(phrase.standardDeviationSemitones - 3 / 2.0.squareRoot()) < 0.05)
        #expect(abs(phrase.rangeSemitones - 6) < 0.05)
        // Up, down, up, down, then up again from the last low point.
        #expect(phrase.rises == 3)
        #expect(phrase.falls == 2)
        #expect(abs(phrase.meanFrequency - 200) < 0.5)
    }

    @Test("Wider melody scores higher than flatter melody")
    func widerIsMoreMelodic() throws {
        let count = Int((2.0 / frameInterval).rounded())
        let times = (0..<count).map { Double($0) * frameInterval }
        let narrow = try #require(IntonationAnalyzer.summarize(
            times: times,
            frequencies: times.map { 200 * pow(2, 1.5 * sin(2 * Double.pi * $0) / 12) },
            frameInterval: frameInterval
        ))
        let wide = try #require(IntonationAnalyzer.summarize(
            times: times,
            frequencies: times.map { 200 * pow(2, 6 * sin(2 * Double.pi * $0) / 12) },
            frameInterval: frameInterval
        ))
        let reference = IntonationReference.standard
        #expect(reference.score(standardDeviationSemitones: wide.standardDeviationSemitones)
            > reference.score(standardDeviationSemitones: narrow.standardDeviationSemitones))
    }

    @Test("A long pause splits phrases")
    func splitsAtPauses() {
        let completed = phrases(
            duration: 3.0,
            voiced: { $0 < 1.0 || ($0 >= 1.5 && $0 < 2.5) },
            pitch: { 200 * pow(2, 2 * sin(2 * Double.pi * $0) / 12) }
        )
        #expect(completed.count == 2)
        #expect(completed.first?.startTime == 0)
        if completed.count == 2 {
            #expect(abs(completed[1].startTime - 1.5) < 0.02)
            #expect(abs(completed[0].voicedDuration - 1.0) < 0.02)
        }
    }

    @Test("A short gap between words does not split the phrase")
    func shortGapKeepsPhrase() {
        let completed = phrases(
            duration: 2.5,
            voiced: { $0 < 1.0 || ($0 >= 1.2 && $0 < 2.0) },
            pitch: { _ in 200 }
        )
        #expect(completed.count == 1)
        #expect(abs((completed.first?.voicedDuration ?? 0) - 1.8) < 0.03)
    }

    @Test("Phrases shorter than 0.6 s of voicing are ignored")
    func shortPhraseIgnored() {
        let completed = phrases(duration: 1.0, voiced: { $0 < 0.3 }, pitch: { _ in 200 })
        #expect(completed.isEmpty)
    }

    @Test("finishPhrase flushes the phrase in progress")
    func flush() throws {
        var analyzer = IntonationAnalyzer(frameInterval: frameInterval)
        for index in 0..<100 {
            _ = analyzer.process(time: Double(index) * frameInterval, frequency: 180)
        }
        #expect(analyzer.isInPhrase)
        let result1 = analyzer.finishPhrase()
        let phrase = try #require(result1)
        #expect(abs(phrase.voicedDuration - 100 * frameInterval) < 1e-9)
        #expect(!analyzer.isInPhrase)
        let result2 = analyzer.finishPhrase()
        #expect(result2 == nil)
    }

    @Test("Movement counting uses hysteresis")
    func movements() {
        let result = IntonationAnalyzer.countMovements([0, 1, 2.5, 1, 0, -0.5, 1.6, 3], threshold: 2)
        #expect(result.rises == 2)
        #expect(result.falls == 1)
        // Small wobbles never count.
        let wobble = IntonationAnalyzer.countMovements([0, 1, 0, 1, 0, 1, 0], threshold: 2)
        #expect(wobble.rises == 0)
        #expect(wobble.falls == 0)
        let empty = IntonationAnalyzer.countMovements([], threshold: 2)
        #expect(empty.rises == 0 && empty.falls == 0)
    }
}

@Suite("VoiceStabilityTracker")
struct VoiceStabilityTrackerTests {
    @Test("Needs three steady voiced frames")
    func needsThreeFrames() {
        var tracker = VoiceStabilityTracker()
        let result3 = tracker.process(200)
        #expect(!result3)
        let result4 = tracker.process(201)
        #expect(!result4)
        let result5 = tracker.process(200)
        #expect(result5)
        let result6 = tracker.process(202)
        #expect(result6)
    }

    @Test("Unvoiced frames and pitch jumps reset stability")
    func resets() {
        var tracker = VoiceStabilityTracker()
        _ = tracker.process(200)
        _ = tracker.process(200)
        let result7 = tracker.process(200)
        #expect(result7)
        let result8 = tracker.process(nil)
        #expect(!result8)
        let result9 = tracker.process(200)
        #expect(!result9)
        let result10 = tracker.process(200)
        #expect(!result10)
        let result11 = tracker.process(200)
        #expect(result11)
        // A 2-semitone jump within the window is not stable.
        let result12 = tracker.process(224.5)
        #expect(!result12)
    }

    @Test("Slow glides still count as stable")
    func glide() {
        var tracker = VoiceStabilityTracker()
        var results: [Bool] = []
        for index in 0..<20 {
            // One octave per second ≈ 0.13 semitones per frame.
            results.append(tracker.process(150 * pow(2, Double(index) * 0.0107)))
        }
        #expect(results.dropFirst(2).allSatisfy { $0 })
    }
}
