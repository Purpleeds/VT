import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

private func makeTake(
    pitch: Double? = 200,
    inTarget: Double? = 70,
    resonance: Double? = 60,
    weight: Double? = 55,
    intonation: Double? = 40,
    voiced: Double = 8
) -> TakeResult {
    TakeResult(
        duration: 10,
        voicedDuration: pitch == nil ? 0 : voiced,
        averagePitch: pitch,
        medianPitch: pitch,
        lowPitch: pitch.map { $0 - 20 },
        highPitch: pitch.map { $0 + 25 },
        percentInTarget: inTarget,
        f1: 550,
        f2: 1_900,
        f3: 2_800,
        resonanceScore: resonance,
        brightResonancePercent: 50,
        h1MinusH2: 6,
        spectralTilt: -8,
        weightScore: weight,
        lightWeightPercent: 45,
        intonationSD: 2.5,
        intonationScore: intonation,
        phraseCount: 2,
        contour: [],
        pitchHistogram: []
    )
}

private func exercise(_ id: String, skill: ExerciseSkill, title: String = "Exercise", summary: String = "", quiet: Bool? = nil) -> Exercise {
    Exercise(
        id: id,
        title: title,
        skill: skill,
        kind: .timed,
        durationSeconds: 60,
        summary: summary,
        instructions: ["Breathe in.", "Breathe out."],
        howItShouldFeel: "Easy.",
        quiet: quiet
    )
}

@Suite("Exercise library")
struct ExerciseLibraryTests {
    @Test("Discreet exercises load and are all quiet")
    func discreetCatalog() throws {
        let catalog = try LessonCatalog.load()
        let ids = catalog.discreet.map(\.id)
        #expect(ids.count == 5)
        #expect(ids.contains("whisper-resonance"))
        #expect(ids.contains("silent-larynx"))
        #expect(ids.contains("very-soft-humming"))
        #expect(catalog.discreet.allSatisfy { $0.isQuiet })
        for exercise in catalog.discreet {
            #expect(exercise.instructions.count >= 3, "\(exercise.id) needs detailed instructions")
            #expect(!exercise.howItShouldFeel.isEmpty)
        }
    }

    @Test("The library lists every exercise once, discreet ones included")
    func allExercisesUnique() throws {
        let catalog = try LessonCatalog.load()
        let ids = catalog.allExercises.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 85)
        for discreet in catalog.discreet {
            #expect(ids.contains(discreet.id))
        }
    }

    @Test("Skill filters keep only matching exercises")
    func skillFilters() throws {
        let all = try LessonCatalog.load().allExercises
        let pitch = ExerciseLibrary.filter(all, by: .pitch, query: "")
        #expect(!pitch.isEmpty)
        #expect(pitch.allSatisfy { $0.skill == .pitch })

        let warmUps = ExerciseLibrary.filter(all, by: .warmUp, query: "")
        #expect(warmUps.contains { $0.skill == .breathing })
        #expect(warmUps.allSatisfy { $0.skill == .warmUp || $0.skill == .breathing })

        let quiet = ExerciseLibrary.filter(all, by: .quiet, query: "")
        #expect(quiet.allSatisfy { $0.isQuiet })
        #expect(quiet.count >= 5)

        let everything = ExerciseLibrary.filter(all, by: .all, query: "")
        #expect(everything.count == all.count)

        // Every exercise is reachable from at least one skill chip.
        let chips = ExerciseLibraryFilter.allCases.filter { $0 != .all && $0 != .quiet }
        for item in all {
            #expect(chips.contains { $0.matches(item) }, "\(item.id) has no filter")
        }
    }

    @Test("Search matches every word, ignoring case")
    func search() throws {
        let all = try LessonCatalog.load().allExercises
        let humming = ExerciseLibrary.filter(all, by: .all, query: "HUMMING")
        #expect(humming.contains { $0.id == "very-soft-humming" })
        let twoWords = ExerciseLibrary.filter(all, by: .all, query: "soft  humming")
        #expect(twoWords.contains { $0.id == "very-soft-humming" })
        let quietHumming = ExerciseLibrary.filter(all, by: .quiet, query: "humming")
        #expect(quietHumming.allSatisfy { $0.isQuiet })
        #expect(ExerciseLibrary.filter(all, by: .all, query: "zzqxv").isEmpty)
    }

    @Test("Search looks at the summary and instructions too")
    func searchFields() {
        let items = [
            exercise("a", skill: .pitch, title: "Sirens", summary: "Glide like a siren"),
            exercise("b", skill: .resonance, title: "Big dog", summary: "Pant gently"),
        ]
        #expect(ExerciseLibrary.filter(items, by: .all, query: "glide").map(\.id) == ["a"])
        #expect(ExerciseLibrary.filter(items, by: .all, query: "breathe").map(\.id) == ["a", "b"])
        #expect(ExerciseLibrary.filter(items, by: .all, query: "resonance").map(\.id) == ["b"])
        #expect(ExerciseLibrary.filter(items, by: .all, query: "   ").count == 2)
    }

    @Test("Sections follow the lesson-plan skill order")
    func sections() {
        let items = [
            exercise("c", skill: .coolDown),
            exercise("p1", skill: .pitch),
            exercise("w", skill: .warmUp),
            exercise("p2", skill: .pitch),
        ]
        let sections = ExerciseLibrary.sections(items)
        #expect(sections.map(\.skill) == [.warmUp, .pitch, .coolDown])
        #expect(sections[1].exercises.map(\.id) == ["p1", "p2"])
    }
}

@Suite("Mini piano and tone generator")
struct PianoAndToneTests {
    @Test("Two octaves from C3 to C5")
    func keyboardRange() {
        let keys = PianoKey.range
        #expect(keys.count == 25)
        #expect(keys.first?.name == "C3")
        #expect(keys.last?.name == "C5")
        let layout = PianoLayout(keys: keys)
        #expect(layout.whiteKeys.count == 15)
        #expect(layout.blackKeys.count == 10)
        #expect(layout.blackKeys.map(\.name).contains("C♯3"))
        #expect(!layout.whiteKeys.contains { $0.name.contains("♯") })
    }

    @Test("Key frequencies use equal temperament")
    func frequencies() throws {
        let a3 = try #require(PianoKey.range.first { $0.midiNote == 57 })
        #expect(abs(a3.frequency - 220) < 0.001)
        let c4 = try #require(PianoKey.range.first { $0.midiNote == 60 })
        #expect(abs(c4.frequency - 261.626) < 0.01)
        #expect(c4.name == "C4")
        #expect(!c4.isBlack)
        #expect(PianoKey(midiNote: 61).isBlack)
    }

    @Test("Black keys sit between their white neighbours")
    func layoutOffsets() {
        let layout = PianoLayout(keys: PianoKey.range)
        #expect(layout.offset(of: PianoKey(midiNote: 48)) == 0)
        #expect(layout.offset(of: PianoKey(midiNote: 49)) == 1)
        #expect(layout.offset(of: PianoKey(midiNote: 51)) == 2)
        #expect(layout.offset(of: PianoKey(midiNote: 54)) == 4)
        #expect(layout.offset(of: PianoKey(midiNote: 58)) == 6)
        #expect(layout.offset(of: PianoKey(midiNote: 60)) == 7)
        #expect(layout.offset(of: PianoKey(midiNote: 72)) == 14)
    }

    @Test("Keys inside a 180–220 Hz target")
    func targetKeys() {
        let zone = PitchTargetZone(lowerBound: 180, upperBound: 220)
        let inside = PianoKey.range.filter { zone.contains($0.frequency) }.map(\.midiNote)
        #expect(inside == [54, 55, 56, 57])
    }

    @Test("Semitone steps snap to notes and stay in range")
    func steps() {
        #expect(abs(ToneGeneratorMath.step(220, semitones: 1) - 233.082) < 0.01)
        #expect(abs(ToneGeneratorMath.step(205, semitones: -1) - 196.0) < 0.01)
        #expect(ToneGeneratorMath.step(590, semitones: 2) == 600)
        #expect(ToneGeneratorMath.step(85, semitones: -3) == 80)
        #expect(ToneGeneratorMath.step(0, semitones: 1) == 80)
    }

    @Test("The slider is logarithmic and round-trips")
    func slider() {
        #expect(abs(ToneGeneratorMath.sliderValue(for: 80)) < 1e-9)
        #expect(abs(ToneGeneratorMath.sliderValue(for: 600) - 1) < 1e-9)
        #expect(abs(ToneGeneratorMath.sliderValue(for: (80.0 * 600).squareRoot()) - 0.5) < 1e-9)
        #expect(abs(ToneGeneratorMath.frequency(forSliderValue: ToneGeneratorMath.sliderValue(for: 200)) - 200) < 1e-6)
        #expect(ToneGeneratorMath.frequency(forSliderValue: 2) == 600)
        #expect(ToneGeneratorMath.sliderValue(for: 20) == 0)
    }

    @Test("Target presets: low, middle and high")
    func presets() {
        let presets = ToneGeneratorMath.presets(for: PitchTargetZone(lowerBound: 180, upperBound: 220))
        #expect(presets.map(\.title) == ["Low", "Middle", "High"])
        #expect(presets[0].frequency == 180)
        #expect(abs(presets[1].frequency - 198.997) < 0.01)
        #expect(presets[2].frequency == 220)
    }
}

@Suite("Journal timeline")
struct JournalTimelineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// 2026-03-10 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_773_154_800)

    private func daysAgo(_ days: Int, hour: Int = 9) -> Date {
        let start = calendar.startOfDay(for: now)
        return start.addingTimeInterval(Double(-days * 86_400 + hour * 3_600))
    }

    @Test("The scrubber picks the nearest entry")
    func scrubber() {
        #expect(JournalTimeline.index(forPosition: 0.5, count: 5) == 2)
        #expect(JournalTimeline.index(forPosition: 1, count: 5) == 4)
        #expect(JournalTimeline.index(forPosition: -1, count: 3) == 0)
        #expect(JournalTimeline.index(forPosition: 0.49, count: 2) == 0)
        #expect(JournalTimeline.index(forPosition: 0.5, count: 0) == nil)
    }

    @Test("Streaks count days in a row up to today or yesterday")
    func streaks() {
        #expect(JournalTimeline.streak(dates: [daysAgo(0), daysAgo(1), daysAgo(2)], now: now, calendar: calendar) == 3)
        #expect(JournalTimeline.streak(dates: [daysAgo(1), daysAgo(2)], now: now, calendar: calendar) == 2)
        #expect(JournalTimeline.streak(dates: [daysAgo(0), daysAgo(0, hour: 20), daysAgo(1)], now: now, calendar: calendar) == 2)
        #expect(JournalTimeline.streak(dates: [daysAgo(0), daysAgo(2)], now: now, calendar: calendar) == 1)
        #expect(JournalTimeline.streak(dates: [daysAgo(3)], now: now, calendar: calendar) == 0)
        #expect(JournalTimeline.streak(dates: [], now: now, calendar: calendar) == 0)
    }

    @Test("Highlights spread from the first entry to the latest")
    func highlights() {
        #expect(JournalTimeline.highlights(count: 10, maximum: 4) == [0, 3, 6, 9])
        #expect(JournalTimeline.highlights(count: 3, maximum: 8) == [0, 1, 2])
        #expect(JournalTimeline.highlights(count: 20, maximum: 8) == [0, 3, 5, 8, 11, 14, 16, 19])
        #expect(JournalTimeline.highlights(count: 5, maximum: 1) == [4])
        #expect(JournalTimeline.highlights(count: 0, maximum: 8).isEmpty)
    }

    @Test("Pitch change is measured from the first entry with a pitch")
    func pitchChange() {
        let points = [nil, 180.0, 200.0, nil].enumerated().map { index, pitch in
            JournalPoint(id: UUID(), date: daysAgo(3 - index), pitch: pitch, resonance: nil, weight: nil, intonation: nil, hasAudio: true)
        }
        #expect(JournalTimeline.pitchChange(in: points, to: points[2]) == 20)
        #expect(JournalTimeline.pitchChange(in: points, to: points[1]) == 0)
        #expect(JournalTimeline.pitchChange(in: points, to: points[3]) == nil)
    }
}

@Suite("Quick Check comparison")
struct QuickCheckComparisonTests {
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

    @Test("Changes are judged per measure")
    func mixedChanges() throws {
        let previous = QuickCheckValues(pitch: 170, percentInTarget: 50, resonance: 62, weight: 45, intonation: nil)
        let comparison = QuickCheckComparison(current: makeTake(), previous: previous, target: target)
        let byMetric = Dictionary(uniqueKeysWithValues: comparison.changes.map { ($0.metric, $0) })
        #expect(comparison.changes.count == 5)
        #expect(byMetric[.pitch]?.isBetter == true)
        #expect(byMetric[.pitch]?.difference == 30)
        #expect(byMetric[.inTarget]?.isBetter == true)
        #expect(byMetric[.resonance]?.isBetter == nil)
        #expect(byMetric[.weight]?.isBetter == true)
        let intonation = try #require(byMetric[.intonation])
        #expect(intonation.isBetter == nil)
        #expect(intonation.difference == nil)
        #expect(comparison.headline == "Better than last time in 3 of 4.")
    }

    @Test("Pitch is better when it moves toward the target zone")
    func pitchDirection() {
        #expect(QuickCheckComparison.isBetter(.pitch, value: 190, previous: 210, target: target) == nil)
        #expect(QuickCheckComparison.isBetter(.pitch, value: 230, previous: 215, target: target) == false)
        #expect(QuickCheckComparison.isBetter(.pitch, value: 175, previous: 160, target: target) == true)
        #expect(QuickCheckComparison.isBetter(.pitch, value: 240, previous: 260, target: target) == true)
        #expect(QuickCheckComparison.isBetter(.pitch, value: 201, previous: 199, target: target) == nil)
        #expect(QuickCheckComparison.isBetter(.resonance, value: 50, previous: 60, target: target) == false)
    }

    @Test("The first check has nothing to compare with")
    func firstCheck() {
        let comparison = QuickCheckComparison(current: makeTake(), previous: nil, target: target)
        #expect(!comparison.hasPrevious)
        #expect(comparison.changes.allSatisfy { $0.isBetter == nil && $0.difference == nil })
        #expect(comparison.headline.hasPrefix("Your first Quick Check"))
    }

    @Test("Headlines for steady and lower checks")
    func headlines() {
        let same = QuickCheckValues(pitch: 201, percentInTarget: 69, resonance: 61, weight: 54, intonation: 41)
        #expect(QuickCheckComparison(current: makeTake(), previous: same, target: target).headline.hasPrefix("About the same"))
        let better = QuickCheckValues(pitch: 200, percentInTarget: 90, resonance: 80, weight: 70, intonation: 60)
        #expect(QuickCheckComparison(current: makeTake(), previous: better, target: target).headline.hasPrefix("A little off"))
        let mixed = QuickCheckValues(pitch: 200, percentInTarget: 90, resonance: 40, weight: 55, intonation: 40)
        #expect(QuickCheckComparison(current: makeTake(), previous: mixed, target: target).headline == "Better in 1, lower in 1 than last time.")
    }

    @Test("Silence gives no measures")
    func silence() {
        let take = makeTake(pitch: nil, inTarget: nil, resonance: nil, weight: nil, intonation: nil)
        #expect(QuickCheckComparison(current: take, previous: nil, target: target).changes.isEmpty)
    }

    @Test("Values and changes are formatted for display")
    func formatting() {
        #expect(QuickCheckMetric.pitch.formatted(203.4) == "203 Hz")
        #expect(QuickCheckMetric.inTarget.formatted(71.6) == "72%")
        #expect(QuickCheckMetric.pitch.formattedChange(-6.2) == "−6 Hz")
        #expect(QuickCheckMetric.resonance.formattedChange(4) == "+4")
        #expect(QuickCheckMetric.inTarget.formattedChange(10) == "+10 pts")
    }
}

/// Journal entries and Quick Checks in an in-memory store.
@MainActor
@Suite("Journal and Quick Check storage", .serialized)
struct ToolsStoreTests {
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    private var context: ModelContext { container.mainContext }
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)
    /// 2026-03-10 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_773_144_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    @Test("One journal entry per day; recording again replaces it")
    func journalReplacesSameDay() async throws {
        let store = JournalStore(context: context)
        try await store.save(take: makeTake(pitch: 190), audio: nil, sentence: "First", target: target, now: noon, calendar: utc)
        try await store.save(take: makeTake(pitch: 205), audio: nil, sentence: "Second", target: target, now: noon.addingTimeInterval(3_600), calendar: utc)
        let sameDay = store.entries()
        #expect(sameDay.count == 1)
        #expect(sameDay.first?.sentence == "Second")
        #expect(sameDay.first?.averagePitch == 205)

        try await store.save(take: makeTake(pitch: 210), audio: nil, sentence: "Second", target: target, now: noon.addingTimeInterval(86_400), calendar: utc)
        let entries = store.entries()
        #expect(entries.count == 2)
        #expect(entries.map(\.averagePitch) == [205, 210])
        #expect(store.entry(on: noon, calendar: utc)?.averagePitch == 205)
        #expect(store.points().map(\.pitch) == [205, 210])
        #expect(store.points().allSatisfy { !$0.hasAudio })

        let first = try #require(entries.first)
        try store.delete(first)
        #expect(store.entries().count == 1)
    }

    @Test("A journal take with audio saves a linked recording")
    func journalWithAudio() async throws {
        let store = JournalStore(context: context)
        let sampleRate = 44_100.0
        let samples = (0..<Int(sampleRate / 2)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / sampleRate)) }
        let clip = AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
        let entry = try await store.save(take: makeTake(), audio: clip, sentence: "Hello", target: target, now: noon, calendar: utc)
        let recording = try #require(entry.recording)
        #expect(recording.kind == .journal)
        #expect(recording.transcript == "Hello")
        #expect(recording.averagePitch == 200)
        #expect(abs(recording.duration - 0.5) < 0.01)
        let url = try #require(recording.fileURL)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        try store.delete(entry)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
    }

    @Test("The journal sentence is trimmed and falls back to the default")
    func journalSentence() {
        let saved = UserDefaults.standard.string(forKey: JournalStore.sentenceKey)
        defer { UserDefaults.standard.set(saved, forKey: JournalStore.sentenceKey) }

        JournalStore.sentence = "  Hello there.  "
        #expect(JournalStore.sentence == "Hello there.")
        JournalStore.sentence = "   "
        #expect(JournalStore.sentence == ReadingPassages.journalSentence)
    }

    @Test("Quick Checks are saved as their own sessions")
    func quickCheckSessions() async throws {
        let store = QuickCheckStore(context: context)
        #expect(store.latestValues() == nil)

        try await store.save(take: makeTake(pitch: 190, resonance: 50), audio: nil, target: target, now: noon)
        try await store.save(take: makeTake(pitch: 205, resonance: 64), audio: nil, target: target, now: noon.addingTimeInterval(86_400))

        let latest = try #require(store.latestValues())
        #expect(latest.pitch == 205)
        #expect(latest.resonance == 64)
        let recent = store.recent(limit: 5)
        #expect(recent.count == 2)
        #expect(recent.allSatisfy { $0.kind == .quickCheck && $0.isFinished })
        #expect(recent.first?.targetPitchLow == 180)
        #expect(recent.first?.duration == 10)

        // Free practice isn't mistaken for a Quick Check.
        context.insert(PracticeSession(startDate: noon.addingTimeInterval(200_000)))
        try context.save()
        #expect(store.latestValues()?.pitch == 205)
    }
}
