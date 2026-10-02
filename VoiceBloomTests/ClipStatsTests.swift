import Foundation
import Testing
@testable import VoiceBloom

@Suite("ClipStats")
struct ClipStatsTests {
    private let interval = 0.01
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

    /// Two phrases separated by pauses:
    /// 0.0–1.0 s at 180 Hz (resonance 40, weight 60 on every other frame),
    /// 1.0–1.5 s silence, 1.5–2.5 s at 240 Hz (resonance 80), 2.5–3.0 s silence.
    private var twoPhrases: [FrameRecord] {
        (0..<300).map { index in
            let time = Double(index) * interval
            switch index {
            case 0..<100:
                return FrameRecord(time: time, pitch: 180, resonanceScore: 40, weightScore: index.isMultiple(of: 2) ? 60 : nil)
            case 150..<250:
                return FrameRecord(time: time, pitch: 240, resonanceScore: 80, weightScore: nil)
            default:
                return FrameRecord(time: time, pitch: nil, resonanceScore: nil, weightScore: nil)
            }
        }
    }

    @Test("Averages pitch, resonance and weight over the clip")
    func averages() throws {
        let stats = ClipStats.compute(records: twoPhrases, from: 0, through: 3, target: target, frameInterval: interval)
        let average = try #require(stats.averagePitch)
        let inTarget = try #require(stats.percentInTarget)
        let resonance = try #require(stats.resonanceScore)
        let weight = try #require(stats.weightScore)
        #expect(abs(average - 210) < 1e-9)
        #expect(abs(inTarget - 50) < 1e-9)
        #expect(abs(resonance - 60) < 1e-9)
        #expect(abs(weight - 60) < 1e-9)
        #expect(abs(stats.voicedDuration - 2) < 1e-9)
        #expect(stats.target == target)
    }

    @Test("Intonation scores each phrase like the live meter, not the clip as one phrase")
    func intonationPerPhrase() throws {
        let stats = ClipStats.compute(records: twoPhrases, from: 0, through: 3, target: target, frameInterval: interval)
        let intonation = try #require(stats.intonationScore)

        // Each phrase holds one steady pitch, so each is as flat as it gets.
        let flat = IntonationReference.standard.score(standardDeviationSemitones: 0)
        #expect(abs(intonation - flat) < 1e-9)

        // Treating the whole clip as one phrase would wrongly count the jump
        // between phrases as melody.
        let voiced = twoPhrases.filter { $0.pitch != nil }
        let wholeClip = try #require(IntonationAnalyzer.summarize(
            times: voiced.map(\.time),
            frequencies: voiced.compactMap(\.pitch),
            frameInterval: interval
        ))
        let wholeClipScore = IntonationReference.standard.score(standardDeviationSemitones: wholeClip.standardDeviationSemitones)
        #expect(wholeClipScore > intonation + 10)
    }

    @Test("Only frames inside the clip count")
    func timeRange() throws {
        let stats = ClipStats.compute(records: twoPhrases, from: 1.45, through: 2.55, target: target, frameInterval: interval)
        let average = try #require(stats.averagePitch)
        let inTarget = try #require(stats.percentInTarget)
        let resonance = try #require(stats.resonanceScore)
        #expect(abs(average - 240) < 1e-9)
        #expect(inTarget == 0)
        #expect(abs(resonance - 80) < 1e-9)
        #expect(stats.weightScore == nil)
        #expect(abs(stats.voicedDuration - 1) < 1e-9)
        #expect(stats.intonationScore != nil)
    }

    @Test("A clip without voice has no averages")
    func silentClip() {
        let silence = (0..<100).map { FrameRecord(time: Double($0) * interval, pitch: nil, resonanceScore: nil, weightScore: nil) }
        let stats = ClipStats.compute(records: silence, from: 0, through: 1, target: target, frameInterval: interval)
        #expect(stats.averagePitch == nil)
        #expect(stats.percentInTarget == nil)
        #expect(stats.resonanceScore == nil)
        #expect(stats.weightScore == nil)
        #expect(stats.intonationScore == nil)
        #expect(stats.voicedDuration == 0)
    }

    @Test("The frame log keeps its time window")
    func frameLogTrims() throws {
        var log = FrameLog(duration: 10)
        for index in 0..<300 {
            log.append(FrameRecord(time: Double(index) * 0.1, pitch: nil, resonanceScore: nil, weightScore: nil))
        }
        let first = try #require(log.records.first)
        let last = try #require(log.records.last)
        #expect(abs(last.time - 29.9) < 1e-9)
        // At least the last 10 s are kept, and never more than 15 s.
        #expect(first.time <= last.time - 10 + 1e-9)
        #expect(first.time >= last.time - 15 - 1e-9)
        log.removeAll()
        #expect(log.records.isEmpty)
    }
}
