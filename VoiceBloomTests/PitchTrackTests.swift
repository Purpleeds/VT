import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

// MARK: - Synthetic material

/// A standard normal value (Box–Muller) from the seeded generator.
private func gaussian(_ generator: inout SeededGenerator) -> Double {
    let u1 = max(Double.random(in: 0..<1, using: &generator), 1e-12)
    let u2 = Double.random(in: 0..<1, using: &generator)
    return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
}

/// A sung contour on the 10 ms grid: notes (MIDI, seconds) with vibrato,
/// short glides between notes, slight noise and optional gaps after notes.
private func sungContour(
    _ notes: [(Double, Double)],
    offset: Double = 0,
    vibrato: Double = 0.3,
    gaps: [Int: Double] = [:],
    seed: UInt64 = 1
) -> [Double?] {
    var generator = SeededGenerator(seed: seed)
    var grid: [Double?] = []
    var time = 0.0
    var previous: Double?
    for (index, note) in notes.enumerated() {
        let count = Int((note.1 / PitchGrid.step).rounded())
        for step in 0..<count {
            let local = Double(step) * PitchGrid.step
            var base = note.0 + offset
            if let previous, local < 0.04 {
                base = previous + offset + (note.0 - previous) * (local / 0.04)
            }
            let value = base + vibrato * sin(2 * Double.pi * 5.5 * (time + local)) + 0.05 * gaussian(&generator)
            grid.append(value)
        }
        time += Double(count) * PitchGrid.step
        previous = note.0
        if let gap = gaps[index] {
            let steps = Int((gap / PitchGrid.step).rounded())
            grid.append(contentsOf: [Double?](repeating: nil, count: steps))
            time += Double(steps) * PitchGrid.step
            previous = nil
        }
    }
    return grid
}

/// A spoken contour: phrases of 4–9 gliding syllables with short gaps,
/// drifting down, separated by pauses.
private func spokenContour(seconds: Double = 12, base: Double = 55, seed: UInt64) -> [Double?] {
    var generator = SeededGenerator(seed: seed)
    var grid: [Double?] = []
    while Double(grid.count) * PitchGrid.step < seconds {
        let syllables = Int.random(in: 4...9, using: &generator)
        let start = base + Double.random(in: 1...4, using: &generator)
        for syllable in 0..<syllables {
            let duration = Double.random(in: 0.12...0.28, using: &generator)
            let count = Int(duration / PitchGrid.step)
            let first = start - Double(syllable) * 0.4 + Double.random(in: -1.5...1.5, using: &generator)
            let slope = Double.random(in: -12...12, using: &generator)
            for step in 0..<count {
                grid.append(first + slope * Double(step) * PitchGrid.step + 0.08 * gaussian(&generator))
            }
            let gap = Int(Double.random(in: 0.03...0.12, using: &generator) / PitchGrid.step)
            grid.append(contentsOf: [Double?](repeating: nil, count: gap))
        }
        let pause = Int(Double.random(in: 0.3...0.6, using: &generator) / PitchGrid.step)
        grid.append(contentsOf: [Double?](repeating: nil, count: pause))
    }
    return grid
}

/// Sawtooth notes (MIDI, seconds) with silence between them, as audio.
private func sungAudio(_ notes: [(Double, Double)], gap: Double, lead: Double = 0.2, sampleRate: Double = 44_100) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(lead * sampleRate))
    for note in notes {
        let count = Int(note.1 * sampleRate)
        samples += TestSignal.sawtooth(frequency: PitchMath.frequency(forMidiNote: note.0), sampleRate: sampleRate, count: count, amplitude: 0.3)
        samples += [Float](repeating: 0, count: Int(gap * sampleRate))
    }
    return samples
}

/// The bars from the scoring prototype: nine half-second notes.
private let scaleBars: [TrackBar] = [60.0, 62, 64, 65, 67, 65, 64, 62, 60].enumerated().map { index, midi in
    TrackBar(index: index, start: 0.5 + Double(index) * 0.6, duration: 0.5, midi: midi)
}

private let sampleInterval = 0.0107

private func targetMidi(at time: Double) -> Double? {
    scaleBars.first { time >= $0.start && time < $0.end }?.midi
}

/// Scores a voice described by `pitch(time)` against the scale bars.
private func score(
    difficulty: TrackDifficulty,
    bars: [TrackBar] = scaleBars,
    scoresResonanceAndWeight: Bool = false,
    voice: (Double) -> TrackVoiceSample
) -> TrackScoreResult {
    var scorer = PitchTrackScorer(bars: bars, difficulty: difficulty, scoresResonanceAndWeight: scoresResonanceAndWeight, sampleInterval: sampleInterval)
    let end = (bars.map(\.end).max() ?? 0) + 0.5
    var time = 0.0
    while time < end {
        scorer.add(voice(time))
        _ = scorer.advance(to: time - 0.3)
        time += sampleInterval
    }
    return scorer.result()
}

private func pitchVoice(_ pitch: @escaping (Double) -> Double?) -> (Double) -> TrackVoiceSample {
    { time in TrackVoiceSample(time: time, midi: pitch(time)) }
}

// MARK: - Note segmentation (SPEC 22.9)

@Suite("Pitch Track: note segmentation")
struct NoteSegmentationTests {
    @Test("Sung notes become flat bars snapped to semitones, equal notes across tiny gaps merge")
    func melody() throws {
        let notes: [(Double, Double)] = [(60, 0.5), (62, 0.5), (64, 0.5), (65, 0.4), (67, 0.8), (67, 0.3), (64, 0.5)]
        let grid = PitchGrid(midi: sungContour(notes, gaps: [4: 0.06, 5: 0.2]))
        let result = NoteSegmenter.notes(grid)
        let pitches = result.bars.map { $0.midi.rounded() }
        try #require(pitches == [60, 62, 64, 65, 67, 64])
        #expect(abs(result.tuningOffset) < 0.05)
        let merged = result.bars[4]
        // 0.8 s + 0.06 s gap + 0.3 s, give or take the glide frames.
        #expect(abs(merged.duration - 1.16) < 0.08)
        #expect(abs(result.bars[0].start) < 0.03)
        #expect(abs(result.bars[1].start - 0.5) < 0.05)
    }

    @Test("A detuned recording keeps its own tuning", arguments: [0.3, -0.35])
    func tuningOffset(offset: Double) {
        let notes: [(Double, Double)] = [(57, 0.6), (59, 0.6), (60, 0.6), (62, 0.6)]
        let result = NoteSegmenter.notes(PitchGrid(midi: sungContour(notes, offset: offset, gaps: [0: 0.2, 1: 0.2, 2: 0.2], seed: 3)))
        #expect(abs(result.tuningOffset - offset) < 0.05)
        let snapped = result.bars.map { $0.midi - result.tuningOffset }
        #expect(snapped.map { $0.rounded() } == [57, 59, 60, 62])
        for bar in result.bars {
            #expect(abs((bar.midi - offset) - (bar.midi - offset).rounded()) < 0.06)
        }
    }

    @Test("Notes shorter than 80 ms are dropped")
    func shortBlips() {
        var grid: [Double?] = [Double?](repeating: 62, count: 40)
        grid += [Double?](repeating: nil, count: 10)
        grid += [Double?](repeating: 66, count: 5)
        grid += [Double?](repeating: nil, count: 10)
        grid += [Double?](repeating: 64, count: 40)
        let result = NoteSegmenter.notes(PitchGrid(midi: grid))
        #expect(result.bars.map { $0.midi.rounded() } == [62, 64])
    }

    @Test("Separate notes are split by a pause; the same note across a tiny gap stays one bar")
    func gaps() {
        let tiny = [Double?](repeating: 60, count: 30) + [Double?](repeating: nil, count: 4) + [Double?](repeating: 60, count: 30)
        let tinyBars = NoteSegmenter.notes(PitchGrid(midi: tiny)).bars
        #expect(tinyBars.count == 1)
        let long = [Double?](repeating: 60, count: 30) + [Double?](repeating: nil, count: 20) + [Double?](repeating: 60, count: 30)
        let longBars = NoteSegmenter.notes(PitchGrid(midi: long)).bars
        #expect(longBars.count == 2)
    }

    @Test("Generated audio with known notes and gaps gives the right bars")
    func fromAudio() throws {
        let notes: [(Double, Double)] = [(57, 0.5), (59, 0.5), (60, 0.6), (62, 0.4), (64, 0.7)]
        let audio = sungAudio(notes, gap: 0.15)
        let clip = AudioClip(samples: audio, sampleRate: 44_100, startTime: 0)
        let analysis = try PitchTrackBuilder.analyze(clip, references: .none)
        #expect(analysis.detection.kind == .singing)
        let content = analysis.content(as: .singing, references: .none)
        try #require(content.bars.count == notes.count)
        var expectedStart = 0.2
        for (bar, note) in zip(content.bars, notes) {
            #expect(abs(bar.midi - note.0) < 0.15)
            #expect(abs(bar.start - expectedStart) < 0.08)
            #expect(abs(bar.duration - note.1) < 0.12)
            expectedStart += note.1 + 0.15
        }
        #expect(content.range.map { $0.lowerBound.rounded() } == 57)
        #expect(content.range.map { $0.upperBound.rounded() } == 64)
    }

    @Test("Silence isn't a track")
    func silence() {
        let clip = AudioClip(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100, startTime: 0)
        var thrown: PitchTrackError?
        do {
            _ = try PitchTrackBuilder.analyze(clip, references: .none)
        } catch {
            thrown = error as? PitchTrackError
        }
        #expect(thrown == .noVoice)
    }
}

// MARK: - Speech segments

@Suite("Pitch Track: speech segments")
struct SpeechSegmentTests {
    @Test("Words separated by short pauses become curved bars")
    func words() throws {
        var grid: [Double?] = []
        for word in 0..<3 {
            grid += (0..<30).map { step in 58 + Double(word) - 0.05 * Double(step) }
            grid += [Double?](repeating: nil, count: 10)
        }
        let bars = SpeechSegmenter.segments(PitchGrid(midi: grid))
        try #require(bars.count == 3)
        for (index, bar) in bars.enumerated() {
            #expect(bar.isCurved)
            #expect(abs(bar.start - Double(index) * 0.4) < 0.03)
            #expect(abs(bar.duration - 0.3) < 0.03)
        }
        // The curve follows the falling pitch.
        let first = bars[0]
        #expect(first.targetMidi(at: first.start) > first.targetMidi(at: first.end - 0.02))
    }

    @Test("A tiny gap inside a word is bridged, and the curve is filled in")
    func bridge() throws {
        let grid: [Double?] = [Double?](repeating: 60, count: 20) + [nil, nil, nil] + [Double?](repeating: 62, count: 20)
        let bars = SpeechSegmenter.segments(PitchGrid(midi: grid))
        try #require(bars.count == 1)
        let middle = bars[0].targetMidi(at: 0.215)
        #expect(middle > 60.2 && middle < 61.8)
    }

    @Test("Long stretches are split at the quietest moment")
    func longStretch() {
        let midi: [Double?] = [Double?](repeating: 60, count: 200)
        var levels = [Double](repeating: -20, count: 200)
        levels[100] = -50
        let bars = SpeechSegmenter.segments(PitchGrid(midi: midi, levels: levels))
        #expect(bars.count >= 3)
        #expect(bars.allSatisfy { $0.duration <= SpeechSegmenter.maximumDuration + 0.001 })
        #expect(bars.contains { abs($0.start - 1.0) < 0.001 })
        let covered = bars.reduce(0.0) { $0 + $1.duration }
        #expect(abs(covered - 2.0) < 0.001)
    }
}

// MARK: - Speech or singing (SPEC 22.9)

@Suite("Pitch Track: speech or singing")
struct ClipTypeDetectionTests {
    @Test("Synthetic speech is detected as speech", arguments: [UInt64(1), 2, 3, 4, 5])
    func speech(seed: UInt64) {
        let detection = ClipTypeDetector.detect(PitchGrid(midi: spokenContour(seed: seed)))
        #expect(detection.kind == .speech)
        #expect(detection.singingScore < 0.3)
        #expect(detection.heldShare < 0.3)
    }

    @Test("Synthetic singing is detected as singing, with or without vibrato and detuning", arguments: [0.1, 0.4])
    func singing(vibrato: Double) {
        let melodies: [[(Double, Double)]] = [
            Array(repeating: [(60, 0.5), (62, 0.5), (64, 0.5), (65, 0.4), (67, 0.8), (67, 0.3), (64, 0.5)], count: 3).flatMap { $0 },
            Array(repeating: [(57, 0.3), (57, 0.3), (59, 0.6), (57, 0.3), (62, 0.3), (61, 1.0)], count: 3).flatMap { $0 },
        ]
        for (index, melody) in melodies.enumerated() {
            for offset in [0, 0.25] {
                let grid = PitchGrid(midi: sungContour(melody, offset: offset, vibrato: vibrato, gaps: [2: 0.3, 5: 0.4], seed: UInt64(index + 1)))
                let detection = ClipTypeDetector.detect(grid)
                #expect(detection.kind == .singing)
                #expect(detection.singingScore > 0.45)
                #expect(detection.snapStrength > 0.6)
            }
        }
    }

    @Test("Too little voice counts as speech with no confidence")
    func tooLittle() {
        let detection = ClipTypeDetector.detect(PitchGrid(midi: [60, 60, nil, 61]))
        #expect(detection.kind == .speech)
        #expect(detection.singingScore == 0)
    }
}

// MARK: - Scoring (SPEC 22.9)

@Suite("Pitch Track: scoring")
struct PitchTrackScoringTests {
    @Test("A perfect voice scores about 100 at every difficulty", arguments: TrackDifficulty.allCases)
    func perfect(difficulty: TrackDifficulty) {
        let result = score(difficulty: difficulty, voice: pitchVoice { time in
            targetMidi(at: time).map { $0 + 0.06 * sin(time * 13) }
        })
        #expect(result.pitchAccuracy >= 98)
        #expect(result.overall >= 95)
        #expect(result.stars == 5)
        #expect(result.percentBarsHit == 100)
        #expect(result.longestCombo == scaleBars.count)
        #expect((result.timing ?? 0) >= 95)
        #expect(result.highestComfortableMidi == 67)
        #expect(result.lowestComfortableMidi == 60)
    }

    @Test("40 cents flat: fine on Easy, marked down on Medium, mostly missed on Hard")
    func flat() {
        let voice = pitchVoice { time in targetMidi(at: time).map { $0 - 0.4 + 0.03 * sin(time * 11) } }
        let easy = score(difficulty: .easy, voice: voice)
        let medium = score(difficulty: .medium, voice: voice)
        let hard = score(difficulty: .hard, voice: voice)
        #expect(easy.pitchAccuracy >= 99)
        #expect(medium.pitchAccuracy > 70 && medium.pitchAccuracy < 90)
        #expect(hard.pitchAccuracy < 40)
        // The bars know the voice was flat.
        let signed = medium.bars.compactMap(\.averageSignedCents)
        #expect(signed.allSatisfy { $0 < -30 && $0 > -50 })
    }

    @Test("Singing 0.2 s late costs timing and some accuracy")
    func late() {
        let voice = pitchVoice { time in targetMidi(at: time - 0.2) }
        let result = score(difficulty: .medium, voice: voice)
        let perfect = score(difficulty: .medium, voice: pitchVoice { targetMidi(at: $0) })
        #expect((result.timing ?? 100) < 60)
        #expect(result.pitchAccuracy < 80)
        #expect(result.overall < perfect.overall - 15)
        let offsets = result.bars.compactMap(\.timingOffset)
        let typical = PitchMath.median(of: offsets) ?? 0
        #expect(typical > 0.15 && typical < 0.25)
    }

    @Test("Off-key singing scores low")
    func offKey() {
        let shifts: [Double] = [2, -2, 1, 3, -1, 2, -3, 1, 2]
        let voice = pitchVoice { time in
            guard let index = scaleBars.firstIndex(where: { time >= $0.start && time < $0.end }) else { return nil }
            return scaleBars[index].midi + shifts[index]
        }
        let result = score(difficulty: .medium, voice: voice)
        #expect(result.pitchAccuracy < 25)
        #expect(result.percentBarsHit < 20)
        #expect(result.stars <= 2)
    }

    @Test("Silence scores zero")
    func silence() {
        let result = score(difficulty: .medium, voice: pitchVoice { _ in nil })
        #expect(result.pitchAccuracy == 0)
        #expect(result.longestCombo == 0)
        #expect(result.stars == 1)
    }

    @Test("Bars fill as they're sung and finish with a combo")
    func fillAndCombo() {
        var scorer = PitchTrackScorer(bars: scaleBars, difficulty: .medium, scoresResonanceAndWeight: false, sampleInterval: sampleInterval)
        var time = 0.5
        while time < 0.75 {
            scorer.add(TrackVoiceSample(time: time, midi: 60))
            time += sampleInterval
        }
        let halfway = scorer.fill(forBar: 0)
        #expect(halfway > 0.45 && halfway < 0.7)
        let feedback = scorer.latest
        #expect(feedback?.zone == .on)
        while time < 1.0 {
            scorer.add(TrackVoiceSample(time: time, midi: 60))
            time += sampleInterval
        }
        let finished = scorer.advance(to: 1.3)
        #expect(finished.count == 1)
        #expect(scorer.combo == 1)
        #expect(scorer.fill(forBar: 0) > 0.95)
    }

    @Test("Live feedback says go higher when flat and lower when sharp")
    func hints() {
        var scorer = PitchTrackScorer(bars: scaleBars, difficulty: .medium, scoresResonanceAndWeight: false, sampleInterval: sampleInterval)
        scorer.add(TrackVoiceSample(time: 0.6, midi: 58.5))
        let flat = scorer.latest
        #expect(flat?.zone == .off)
        #expect(flat?.hintGoesHigher == true)
        scorer.add(TrackVoiceSample(time: 0.62, midi: 60.7))
        let sharp = scorer.latest
        #expect(sharp?.zone == .close)
        #expect(sharp?.hintGoesHigher == false)
    }

    @Test("Resonance and weight match their targets when enabled")
    func resonanceAndWeight() {
        let bars = scaleBars.map { bar in
            var copy = bar
            copy.resonance = BarResonance(f1: nil, f2: 1_800, f3: 2_900, score: 80)
            copy.weightScore = 70
            return copy
        }
        let matched = score(difficulty: .medium, bars: bars, scoresResonanceAndWeight: true) { time in
            TrackVoiceSample(time: time, midi: bars.first { time >= $0.start && time < $0.end }?.midi, f2: 1_800, f3: 2_900, weightScore: 70)
        }
        #expect((matched.resonanceMatch ?? 0) > 99)
        #expect((matched.weightMatch ?? 0) > 99)
        let dark = score(difficulty: .medium, bars: bars, scoresResonanceAndWeight: true) { time in
            TrackVoiceSample(time: time, midi: bars.first { time >= $0.start && time < $0.end }?.midi, f2: 1_440, f3: 2_320, weightScore: 20)
        }
        #expect((dark.resonanceMatch ?? 100) < 5)
        #expect((dark.weightMatch ?? 100) < 5)
        #expect(dark.overall < matched.overall)
    }

    @Test("Stars follow the overall score")
    func stars() {
        #expect(TrackScoreResult.stars(for: 95) == 5)
        #expect(TrackScoreResult.stars(for: 80) == 4)
        #expect(TrackScoreResult.stars(for: 65) == 3)
        #expect(TrackScoreResult.stars(for: 45) == 2)
        #expect(TrackScoreResult.stars(for: 10) == 1)
    }

    @Test("Stopping early scores only what was played")
    func early() {
        var scorer = PitchTrackScorer(bars: scaleBars, difficulty: .medium, scoresResonanceAndWeight: false, sampleInterval: sampleInterval)
        var time = 0.0
        while time < 2.0 {
            scorer.add(TrackVoiceSample(time: time, midi: targetMidi(at: time)))
            time += sampleInterval
        }
        let partial = scorer.result(through: 2.0)
        #expect(partial.bars.count == 3)
        #expect(partial.pitchAccuracy > 85)
    }

    @Test("The simulated perfect voice scores about 100 on every built-in track (Debug check)", arguments: BuiltInTrack.allCases)
    func perfectVoiceOnBuiltIns(track: BuiltInTrack) {
        let content = track.content(target: .feminine, references: .none)
        let result = score(difficulty: .hard, bars: content.bars, scoresResonanceAndWeight: true) { time in
            PerfectVoice.sample(at: time, bars: content.bars)
        }
        #expect(result.overall >= 99)
        #expect(result.percentBarsHit == 100)
    }
}

// MARK: - Ranges, settings, built-ins

@Suite("Pitch Track: ranges and settings")
struct PitchTrackRangeTests {
    @Test("A track above the comfortable range is transposed down to fit")
    func transposeDown() {
        let comfort = 55.0...67.0
        let track = 67.0...79.0
        #expect(TrackRange.bestFit(track, comfort: comfort) == -12)
        #expect(TrackRange.suggestion(track, comfort: comfort, current: 0) == -12)
        #expect(TrackRange.suggestion(track, comfort: comfort, current: -12) == nil)
    }

    @Test("A track that already fits needs no advice")
    func fits() {
        #expect(TrackRange.suggestion(58...64, comfort: 55...67, current: 0) == nil)
        #expect(TrackRange.overshoot(58...64, comfort: 55...67) == 0)
        #expect(TrackRange.overshoot(50...64, comfort: 55...67) == 5)
    }

    @Test("Transposition stays within ±12")
    func clamped() {
        #expect(TrackRange.bestFit(90...95, comfort: 50...60) == -12)
        #expect(TrackRange.bestFit(20...25, comfort: 50...60) == 12)
    }

    @Test("Comfortable range comes from recent sessions and covers the target zone")
    func comfort() {
        let sessions = [
            SessionPitchRange(low: 150, high: 230, voicedDuration: 60),
            SessionPitchRange(low: 160, high: 240, voicedDuration: 60),
            SessionPitchRange(low: 170, high: 250, voicedDuration: 60),
            SessionPitchRange(low: 90, high: 400, voicedDuration: 5),
        ]
        let range = ComfortRange.estimate(sessions: sessions, baselineLow: nil, baselineHigh: nil, target: .feminine)
        #expect(range.contains(PitchMath.midiNote(for: 160)))
        #expect(range.contains(PitchMath.midiNote(for: 240)))
        #expect(!range.contains(PitchMath.midiNote(for: 400)))
        #expect(abs((range.upperBound - range.lowerBound) - 12) < 0.001)

        let fallback = ComfortRange.estimate(sessions: [], baselineLow: nil, baselineHigh: nil, target: .feminine)
        #expect(fallback.contains(PitchMath.midiNote(for: 180)))
        #expect(fallback.contains(PitchMath.midiNote(for: 220)))
    }

    @Test("Settings clamp transpose, step speed and default by kind")
    func settings() {
        var settings = TrackSettings()
        settings.setTranspose(20)
        #expect(settings.transpose == 12)
        settings.setTranspose(-30)
        #expect(settings.transpose == -12)
        settings.setSpeed(0.72)
        #expect(abs(settings.speed - 0.7) < 0.0001)
        settings.setSpeed(0.2)
        #expect(settings.speed == 0.5)

        let speech = TrackSettings.defaults(kind: .speech, hasOriginalAudio: true, hasSplit: false)
        #expect(speech.scoresResonanceAndWeight)
        #expect(speech.audioMode == .original)
        let song = TrackSettings.defaults(kind: .singing, hasOriginalAudio: true, hasSplit: true)
        #expect(!song.scoresResonanceAndWeight)
        #expect(song.audioMode == .backingOnly)
        let exercise = TrackSettings.defaults(kind: .builtIn, hasOriginalAudio: false, hasSplit: false, isSpeechPattern: true)
        #expect(exercise.audioMode == .guideTones)
        #expect(exercise.scoresResonanceAndWeight)
    }

    @Test("Loops stay inside the track and at least two seconds long")
    func loops() {
        let loop = TrackLoop(start: 9, end: 9.5, trackDuration: 10)
        #expect(loop.start == 8)
        #expect(loop.end == 10)
        let swapped = TrackLoop(start: 6, end: 2, trackDuration: 10)
        #expect(swapped.start == 2)
        #expect(swapped.end == 6)
        let settings = TrackSettings(loop: TrackLoop(start: 1, end: 3, trackDuration: 10))
        #expect(settings.playRange(trackDuration: 10) == 1...3)
    }

    @Test("Playable bars are transposed and limited to the play range")
    func playable() {
        let content = PitchTrackContent(kind: .singing, duration: 6, bars: scaleBars)
        let bars = content.playableBars(transpose: -2, range: 1.0...3.0)
        #expect(bars.map(\.midi) == [60, 62, 63, 65])
        #expect(bars.map(\.index) == [1, 2, 3, 4])
    }

    @Test("Audio modes depend on what the track has")
    func modes() {
        #expect(TrackAudioMode.available(hasOriginalAudio: false, hasSplit: false) == [.guideTones, .silent])
        #expect(TrackAudioMode.available(hasOriginalAudio: true, hasSplit: false) == [.original, .guideTones, .silent])
        #expect(TrackAudioMode.available(hasOriginalAudio: true, hasSplit: true) == TrackAudioMode.allCases)
    }
}

@Suite("Pitch Track: built-in tracks")
struct BuiltInTrackTests {
    @Test("Every built-in track has ordered bars inside its length", arguments: BuiltInTrack.allCases)
    func shape(track: BuiltInTrack) {
        let content = track.content(target: .feminine, references: .none)
        #expect(!content.bars.isEmpty)
        #expect(content.kind == .builtIn)
        let starts = content.bars.map(\.start)
        #expect(starts == starts.sorted())
        #expect(content.bars.allSatisfy { $0.duration > 0 && $0.end <= content.duration })
        #expect(content.bars.allSatisfy { $0.weightScore == 100 && $0.resonance?.score == 100 })
        if track.isSpeechPattern {
            #expect(content.bars.allSatisfy { $0.isCurved && $0.word != nil })
        }
    }

    @Test("Held notes sit in the target zone")
    func heldNotes() {
        let content = BuiltInTrack.heldNotes.content(target: .feminine, references: .none)
        let low = PitchMath.midiNote(for: PitchTargetZone.feminine.lowerBound)
        let high = PitchMath.midiNote(for: PitchTargetZone.feminine.upperBound)
        #expect(content.bars.allSatisfy { $0.midi >= low - 0.6 && $0.midi <= high + 0.6 })
    }

    @Test("Questions rise and statements fall at the end")
    func intonation() throws {
        let questions = BuiltInTrack.risingQuestions.content(target: .feminine, references: .none)
        try #require(questions.bars.count > 4)
        let lastWord = questions.bars[3]
        #expect(lastWord.word == "tonight?")
        #expect(lastWord.targetMidi(at: lastWord.end) > lastWord.targetMidi(at: lastWord.start) + 3)
        let statements = BuiltInTrack.fallingStatements.content(target: .feminine, references: .none)
        let lastStatement = statements.bars[3]
        #expect(lastStatement.targetMidi(at: lastStatement.end) < lastStatement.targetMidi(at: lastStatement.start) - 3)
    }

    @Test("Built-in ids are unique and stable")
    func ids() {
        let ids = BuiltInTrack.allCases.map(\.trackID)
        #expect(Set(ids).count == ids.count)
        for track in BuiltInTrack.allCases {
            #expect(BuiltInTrack.track(id: track.trackID) == track)
        }
        #expect(BuiltInTrack.siren.trackID.uuidString == "B0117000-0000-4000-8000-000000000001")
    }
}

// MARK: - Timing

@Suite("Pitch Track: clock and latency")
struct PitchTrackTimingTests {
    @Test("The clock follows speed and pauses")
    func clock() {
        var clock = TrackClock(range: 2...10, speed: 0.5, loops: false, startHost: 100)
        #expect(clock.trackTime(atHost: 100) == 2)
        #expect(clock.trackTime(atHost: 104) == 4)
        #expect(clock.trackTime(atHost: 99) == 1.5)
        #expect(!clock.isFinished(atHost: 115.9))
        #expect(clock.isFinished(atHost: 116))
        clock.pause(atHost: 104)
        #expect(clock.trackTime(atHost: 108) == 4)
        clock.resume(atHost: 110)
        #expect(clock.trackTime(atHost: 110) == 4)
        #expect(clock.trackTime(atHost: 112) == 5)
    }

    @Test("A looping clock wraps and counts passes")
    func loop() {
        let clock = TrackClock(range: 0...4, speed: 1, loops: true, startHost: 0)
        #expect(abs(clock.trackTime(atHost: 5) - 1) < 1e-9)
        #expect(clock.pass(atHost: 5) == 1)
        #expect(clock.pass(atHost: 3.9) == 0)
        #expect(!clock.isFinished(atHost: 100))
    }

    @Test("Frame times are mapped with the smallest arrival delay")
    func aligner() {
        var aligner = FrameTimeAligner()
        for index in 0..<400 {
            let time = Double(index) * 0.01
            let jitter = Double((index * 7) % 10) * 0.003
            aligner.observe(frameTime: time, arrivalHost: 1_000 + time + 0.05 + jitter)
        }
        let offset = aligner.offset ?? 0
        #expect(abs(offset - 1_000.05) < 0.0001)
        let host = aligner.hostTime(ofFrameTime: 1, fixedDelay: 0.02) ?? 0
        #expect(abs(host - 1_001.03) < 0.0001)
    }

    @Test("Tap-along calibration takes the median delay and ignores stray taps")
    func calibration() {
        let interval = LatencyCalibration.beatInterval
        let beats = (0..<LatencyCalibration.beatCount).map { 10 + Double($0) * interval }
        var taps = beats.dropFirst(2).enumerated().map { index, beat in
            beat + 0.15 + (index.isMultiple(of: 2) ? 0.01 : -0.01)
        }
        taps.append(beats[5] + interval / 2)
        let offset = LatencyCalibration.offset(beats: beats, taps: taps) ?? 0
        #expect(abs(offset - 0.15) < 0.011)
        let tooFew = LatencyCalibration.offset(beats: beats, taps: Array(taps.prefix(3)))
        #expect(tooFew == nil)
    }

    @Test("Custom latency wins over automatic, within limits")
    func latency() {
        var latency = PitchTrackLatency()
        #expect(latency.offsetSeconds(automatic: 0.18) == 0.18)
        latency.customMilliseconds = 120
        #expect(abs(latency.offsetSeconds(automatic: 0.18) - 0.12) < 1e-9)
        latency.customMilliseconds = 2_000
        #expect(abs(latency.offsetSeconds(automatic: 0.18) - 0.5) < 1e-9)
        #expect(PitchTrackLatency.automaticSeconds(outputLatency: 0.2, playsSound: false) == 0.03)
        #expect(PitchTrackLatency.automaticSeconds(outputLatency: 0.2, playsSound: true) == 0.2)
    }
}

// MARK: - Building blocks

@Suite("Pitch Track: grid, words, music, guide tones")
struct PitchTrackBuildingBlockTests {
    @Test("Frames are resampled onto a 10 ms grid")
    func resample() throws {
        let hop = 512.0 / 44_100
        let frames = (0..<200).map { index -> TrackFeatureFrame in
            let time = 0.023 + Double(index) * hop
            let voiced = index < 100 || index >= 150
            return TrackFeatureFrame(time: time, midi: voiced ? 60 + time : nil, levelDb: -20)
        }
        let grid = PitchGrid.resample(frames, duration: 2)
        try #require(grid.count == 200)
        let value = grid.midi[50] ?? 0
        #expect(abs(value - 60.5) < 0.01)
        #expect(grid.midi[0] == nil)
        // Frames 100–149 (about 1.19–1.75 s) are unvoiced.
        #expect(grid.midi[140] == nil)
        #expect(grid.midi[190] != nil)
    }

    @Test("Words go under the bar they overlap most")
    func words() {
        let bars = [
            TrackBar(index: 0, start: 0, duration: 1, midi: 60),
            TrackBar(index: 1, start: 1.2, duration: 0.8, midi: 62),
        ]
        let words = [
            TranscribedWord(text: "hello", start: 0.1, duration: 0.4, confidence: 0.9),
            TranscribedWord(text: "big", start: 0.8, duration: 0.5, confidence: 0.9),
            TranscribedWord(text: "world", start: 1.3, duration: 0.5, confidence: 0.9),
        ]
        let attached = PitchTrackBuilder.attach(words, to: bars)
        #expect(attached[0].word == "hello big")
        #expect(attached[1].word == "world")

        let unsure = words.map { TranscribedWord(text: $0.text, start: $0.start, duration: $0.duration, confidence: 0.3) }
        #expect(PitchTrackBuilder.shouldShowWords(unsure, kind: .speech))
        #expect(!PitchTrackBuilder.shouldShowWords(unsure, kind: .singing))
        #expect(PitchTrackBuilder.shouldShowWords(words, kind: .singing))
        #expect(!PitchTrackBuilder.shouldShowWords([], kind: .speech))
    }

    @Test("Background music: wide stereo, no pauses, or held notes under speech")
    func music() {
        let song = SplitAssessment(sideToMidDb: -12, pauseShare: 0.01, peakDb: -1)
        let speechStereo = SplitAssessment(sideToMidDb: -60, pauseShare: 0.2, peakDb: -3)
        #expect(BackgroundMusicCheck.hasMusic(kind: .singing, pauseShare: 0.2, duration: 30, heldNoteShare: 0.8, stereo: song))
        #expect(!BackgroundMusicCheck.hasMusic(kind: .speech, pauseShare: 0.2, duration: 30, heldNoteShare: 0.05, stereo: speechStereo))
        #expect(BackgroundMusicCheck.hasMusic(kind: .speech, pauseShare: 0.01, duration: 30, heldNoteShare: 0.05, stereo: nil))
        #expect(BackgroundMusicCheck.hasMusic(kind: .speech, pauseShare: 0.2, duration: 30, heldNoteShare: 0.4, stereo: nil))
        // A cappella singing holds notes but still pauses to breathe.
        #expect(!BackgroundMusicCheck.hasMusic(kind: .singing, pauseShare: 0.15, duration: 30, heldNoteShare: 0.8, stereo: nil))
    }

    @Test("Guide tones play the bar's pitch and stay silent between bars")
    func guideTones() {
        let bar = TrackBar(index: 0, start: 0.2, duration: 0.6, midi: 69)
        let samples = GuideToneRenderer.render(bars: [bar], range: 0...1)
        #expect(samples.count == 44_100)
        let before = samples[0..<8_000].map { abs($0) }.max() ?? 1
        #expect(before == 0)
        let during = samples[10_000..<30_000].map { abs($0) }.max() ?? 0
        #expect(during > 0.1)
        let pipeline = VoiceAnalysisPipeline(configuration: AnalysisConfiguration(sampleRate: 44_100))
        let pitches = pipeline.process(samples).compactMap { $0.isVoiced ? $0.filteredFrequency : nil }
        let median = PitchMath.median(of: pitches) ?? 0
        #expect(abs(median - 440) < 3)
    }

    @Test("Guide tones follow a curved bar")
    func curvedGuide() {
        let bar = TrackBar(
            index: 0,
            start: 0,
            duration: 1,
            midi: 60,
            contour: [TrackContourPoint(time: 0, midi: 57), TrackContourPoint(time: 1, midi: 64)]
        )
        let samples = GuideToneRenderer.render(bars: [bar], range: 0...1)
        let pipeline = VoiceAnalysisPipeline(configuration: AnalysisConfiguration(sampleRate: 44_100))
        let frames = pipeline.process(samples).filter(\.isVoiced)
        let early = frames.filter { $0.time < 0.3 }.compactMap(\.filteredFrequency)
        let late = frames.filter { $0.time > 0.7 }.compactMap(\.filteredFrequency)
        let earlyMedian = PitchMath.median(of: early) ?? 0
        let lateMedian = PitchMath.median(of: late) ?? 0
        #expect(lateMedian > earlyMedian * 1.2)
    }

    @Test("Calibration clicks land on the beats")
    func clicks() {
        let samples = GuideToneRenderer.clicks(count: 3, interval: 0.5)
        #expect(samples.count == 66_150)
        for beat in 0..<3 {
            let start = beat * 22_050
            let click = samples[start..<(start + 1_000)].map { abs($0) }.max() ?? 0
            let quiet = samples[(start + 4_000)..<(start + 20_000)].map { abs($0) }.max() ?? 1
            #expect(click > 0.3)
            #expect(quiet < 0.001)
        }
    }

    @Test("Track audio sections are mixed sample by sample")
    func mixing() {
        let first = StereoBuffer(left: [0.1, 0.2], right: [0.1, 0.2])
        let second = StereoBuffer(left: [0.3, 0.3, 0.3], right: [0, 0, 0])
        let mixed = TrackAudioLoader.mixed(first, second)
        #expect(mixed.count == 3)
        #expect(abs(mixed.left[1] - 0.5) < 1e-6)
        #expect(abs(mixed.right[2]) < 1e-6)
    }
}

// MARK: - Storage

@MainActor
@Suite("Pitch Track: storage", .serialized)
struct PitchTrackStoreTests {
    /// Kept as a property so the store lives as long as the test.
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    @Test("Tracks keep their bars, curves, words and settings")
    func roundTrip() async throws {
        let context = container.mainContext
        let store = PitchTrackStore(context: context)
        let curved = TrackBar(
            index: 1,
            start: 1,
            duration: 0.5,
            midi: 61,
            contour: [TrackContourPoint(time: 1, midi: 60), TrackContourPoint(time: 1.5, midi: 62)],
            resonance: BarResonance(f1: 500, f2: 1_700, f3: 2_800, score: 60),
            weightScore: 55,
            loudnessDb: -18,
            word: "hello"
        )
        let content = PitchTrackContent(kind: .speech, duration: 3, bars: [TrackBar(index: 0, start: 0.2, duration: 0.5, midi: 59), curved])
        let settings = TrackSettings(
            transpose: -3,
            speed: 0.75,
            loop: TrackLoop(start: 0.5, end: 2.5, trackDuration: 3),
            difficulty: .hard,
            scoresResonanceAndWeight: true,
            audioMode: .original
        )
        let saved = try await store.save(
            name: " My_Clip ",
            content: content,
            detectedKind: .singing,
            settings: settings,
            audio: nil,
            separatedTrackID: nil,
            splitOffset: 0,
            hasBackgroundMusic: true,
            hasMultipleSpeakers: false
        )
        #expect(saved.name == "My Clip")
        #expect(saved.kind == .speech)
        #expect(saved.detectedKindRawValue == PitchTrackKind.singing.rawValue)
        #expect(saved.hasBackgroundMusic)

        let loaded = PitchTrackStore.content(of: saved)
        try #require(loaded.bars.count == 2)
        #expect(loaded.bars[1].contour == curved.contour)
        #expect(loaded.bars[1].word == "hello")
        #expect(loaded.bars[1].resonance == curved.resonance)
        #expect(loaded.bars[0].noteName == "B3")
        let loadedSettings = PitchTrackStore.settings(of: saved)
        #expect(loadedSettings == settings)

        let found = store.track(id: saved.id)
        #expect(found?.id == saved.id)
        let sources = store.audioSources(for: saved)
        #expect(sources.original == nil)
        #expect(sources.availableModes == [.guideTones, .silent])

        try store.delete(saved)
        let tracks = try context.fetch(FetchDescriptor<PitchTrack>())
        let segments = try context.fetch(FetchDescriptor<TrackSegment>())
        #expect(tracks.isEmpty)
        #expect(segments.isEmpty)
    }

    @Test("Saved data from version 2 opens in version 3")
    func migration() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "VoiceBloom.store", directoryHint: .notDirectory)

        do {
            let schema = Schema(versionedSchema: VoiceBloomSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let old = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(old)
            let profile = UserProfile()
            profile.targetPitchLow = 170
            context.insert(profile)
            try context.save()
        }

        let schema = Schema(versionedSchema: VoiceBloomSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let upgraded = try ModelContainer(for: schema, migrationPlan: VoiceBloomMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(upgraded)
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.targetPitchLow == 170)
        context.insert(PitchTrack(name: "New", kind: .singing))
        try context.save()
        let tracks = try context.fetch(FetchDescriptor<PitchTrack>())
        #expect(tracks.count == 1)
    }
}
