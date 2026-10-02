import Foundation

// MARK: - Exercise library

/// Filter chips for the exercise library (SPEC section 8: filters by skill).
nonisolated enum ExerciseLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case warmUp
    case pitch
    case resonance
    case weight
    case intonation
    case speech
    case coolDown
    case quiet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .warmUp: "Warm-up"
        case .pitch: "Pitch"
        case .resonance: "Resonance"
        case .weight: "Weight"
        case .intonation: "Intonation"
        case .speech: "Real speech"
        case .coolDown: "Cool-down"
        case .quiet: "Quiet"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .warmUp: ExerciseSkill.warmUp.systemImage
        case .pitch: ExerciseSkill.pitch.systemImage
        case .resonance: ExerciseSkill.resonance.systemImage
        case .weight: ExerciseSkill.weight.systemImage
        case .intonation: ExerciseSkill.intonation.systemImage
        case .speech: ExerciseSkill.carryover.systemImage
        case .coolDown: ExerciseSkill.coolDown.systemImage
        case .quiet: "speaker.slash"
        }
    }

    func matches(_ exercise: Exercise) -> Bool {
        switch self {
        case .all: true
        case .warmUp: exercise.skill == .warmUp || exercise.skill == .breathing
        case .pitch: exercise.skill == .pitch
        case .resonance: exercise.skill == .resonance
        case .weight: exercise.skill == .weight
        case .intonation: exercise.skill == .intonation
        case .speech: exercise.skill == .carryover || exercise.skill == .expression
        case .coolDown: exercise.skill == .coolDown
        case .quiet: exercise.isQuiet
        }
    }
}

/// Exercises of one skill, for a library section.
nonisolated struct ExerciseSection: Identifiable, Sendable, Equatable {
    let skill: ExerciseSkill
    let exercises: [Exercise]

    var id: String { skill.rawValue }
}

/// Search and grouping for the exercise library.
nonisolated enum ExerciseLibrary {
    /// Exercises that pass the filter and contain every word of the search.
    static func filter(_ exercises: [Exercise], by filter: ExerciseLibraryFilter, query: String) -> [Exercise] {
        exercises.filter { filter.matches($0) && matches($0, query: query) }
    }

    /// True when every word of `query` appears somewhere in the exercise
    /// (title, summary, skill, instructions, notes or practice text).
    static func matches(_ exercise: Exercise, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let searchable = [
            exercise.title,
            exercise.summary,
            exercise.skill.title,
            exercise.instructions.joined(separator: " "),
            exercise.howItShouldFeel,
            exercise.commonMistake ?? "",
            exercise.text ?? "",
            (exercise.items ?? []).joined(separator: " "),
        ].joined(separator: " ")
        return words.allSatisfy { searchable.localizedStandardContains($0) }
    }

    /// Groups exercises by skill in the order of the lesson plan, keeping
    /// the catalog order inside each group.
    static func sections(_ exercises: [Exercise]) -> [ExerciseSection] {
        ExerciseSkill.allCases.compactMap { skill in
            let matching = exercises.filter { $0.skill == skill }
            return matching.isEmpty ? nil : ExerciseSection(skill: skill, exercises: matching)
        }
    }
}

// MARK: - Mini piano and tone generator

/// A key of the two-octave mini piano (C3–C5).
nonisolated struct PianoKey: Identifiable, Sendable, Equatable {
    let midiNote: Int

    var id: Int { midiNote }
    var frequency: Double { PitchMath.frequency(forMidiNote: Double(midiNote)) }
    var name: String { PitchMath.noteName(for: frequency) ?? "" }
    var spokenName: String { PitchMath.spokenNoteName(for: frequency) ?? name }

    /// True for the black keys (C♯, D♯, F♯, G♯, A♯).
    var isBlack: Bool { [1, 3, 6, 8, 10].contains(((midiNote % 12) + 12) % 12) }

    /// C3 (MIDI 48, 130.8 Hz) to C5 (MIDI 72, 523.3 Hz).
    static let range: [PianoKey] = (48...72).map(PianoKey.init(midiNote:))
}

/// Where keys sit on the keyboard, in white-key widths.
nonisolated struct PianoLayout: Sendable {
    let keys: [PianoKey]

    var whiteKeys: [PianoKey] { keys.filter { !$0.isBlack } }
    var blackKeys: [PianoKey] { keys.filter(\.isBlack) }

    /// The left edge of a white key, or the centre of a black key (which sits
    /// on the line between two white keys).
    func offset(of key: PianoKey) -> Double {
        Double(keys.filter { !$0.isBlack && $0.midiNote < key.midiNote }.count)
    }
}

/// Frequency helpers for the reference tone generator.
nonisolated enum ToneGeneratorMath {
    /// Lowest and highest tone offered (covers speaking voices).
    static let range: ClosedRange<Double> = 80...600

    static func clamp(_ frequency: Double) -> Double {
        min(max(frequency, range.lowerBound), range.upperBound)
    }

    /// Moves by whole semitones, snapping to the nearest note first.
    static func step(_ frequency: Double, semitones: Int) -> Double {
        guard frequency > 0 else { return range.lowerBound }
        let note = PitchMath.midiNote(for: frequency).rounded() + Double(semitones)
        return clamp(PitchMath.frequency(forMidiNote: note))
    }

    /// Slider position (0…1) on a log scale, so each octave takes the same room.
    static func sliderValue(for frequency: Double) -> Double {
        let clamped = clamp(frequency)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func frequency(forSliderValue value: Double) -> Double {
        let position = min(max(value, 0), 1)
        return clamp(range.lowerBound * pow(range.upperBound / range.lowerBound, position))
    }

    /// Low, middle and high of a target zone, for quick presets.
    static func presets(for zone: PitchTargetZone) -> [TonePreset] {
        [
            TonePreset(title: "Low", frequency: clamp(zone.lowerBound)),
            TonePreset(title: "Middle", frequency: clamp(zone.center)),
            TonePreset(title: "High", frequency: clamp(zone.upperBound)),
        ]
    }
}

/// A one-tap tone frequency.
nonisolated struct TonePreset: Identifiable, Sendable, Equatable {
    let title: String
    let frequency: Double

    var id: String { title }
}

// MARK: - Daily Sentence Journal

/// One journal day, copied out of SwiftData for the timeline.
nonisolated struct JournalPoint: Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let pitch: Double?
    let resonance: Double?
    let weight: Double?
    let intonation: Double?
    let hasAudio: Bool
}

/// Timeline maths for the journal: the scrubber, streaks and highlights.
nonisolated enum JournalTimeline {
    /// The entry under a scrubber position (0…1).
    static func index(forPosition position: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let clamped = min(max(position, 0), 1)
        return (clamped * Double(count - 1)).roundedInt
    }

    /// Days in a row with an entry, ending today (or yesterday, so the
    /// streak doesn't look broken before today's recording).
    static func streak(dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        guard var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Up to `maximum` entries spread evenly from the first to the latest,
    /// for "play my progress".
    static func highlights(count: Int, maximum: Int) -> [Int] {
        guard count > 0, maximum > 0 else { return [] }
        guard count > maximum else { return Array(0..<count) }
        guard maximum > 1 else { return [count - 1] }
        var result: [Int] = []
        for step in 0..<maximum {
            let index = (Double(step) * Double(count - 1) / Double(maximum - 1)).roundedInt
            if result.last != index {
                result.append(index)
            }
        }
        return result
    }

    /// Pitch change from the first entry with a pitch to `point`.
    static func pitchChange(in points: [JournalPoint], to point: JournalPoint) -> Double? {
        guard let first = points.first(where: { $0.pitch != nil })?.pitch, let pitch = point.pitch else { return nil }
        return pitch - first
    }
}

// MARK: - Quick Check

nonisolated enum QuickCheckMetric: String, CaseIterable, Identifiable, Sendable {
    case pitch
    case inTarget
    case resonance
    case weight
    case intonation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pitch: "Pitch"
        case .inTarget: "In target"
        case .resonance: "Resonance"
        case .weight: "Weight"
        case .intonation: "Intonation"
        }
    }

    /// Smaller changes count as "about the same".
    var threshold: Double { 3 }

    func formatted(_ value: Double) -> String {
        switch self {
        case .pitch: "\(value.roundedInt) Hz"
        case .inTarget: "\(value.roundedInt)%"
        case .resonance, .weight, .intonation: "\(value.roundedInt)"
        }
    }

    func formattedChange(_ difference: Double) -> String {
        let sign = difference >= 0 ? "+" : "−"
        let amount = abs(difference).roundedInt
        switch self {
        case .pitch: return "\(sign)\(amount) Hz"
        case .inTarget: return "\(sign)\(amount) pts"
        case .resonance, .weight, .intonation: return "\(sign)\(amount)"
        }
    }
}

/// How today's Quick Check compares with the previous one.
nonisolated struct QuickCheckComparison: Sendable, Equatable {
    nonisolated struct Change: Sendable, Equatable, Identifiable {
        let metric: QuickCheckMetric
        let value: Double
        let previous: Double?
        /// True when it moved the right way, false the wrong way, nil when
        /// about the same or there's nothing to compare with.
        let isBetter: Bool?

        var id: String { metric.rawValue }
        var difference: Double? { previous.map { value - $0 } }
    }

    let changes: [Change]
    let hasPrevious: Bool

    init(current: TakeResult, previous: QuickCheckValues?, target: PitchTargetZone) {
        let pairs: [(QuickCheckMetric, Double?, Double?)] = [
            (.pitch, current.medianPitch, previous?.pitch),
            (.inTarget, current.percentInTarget, previous?.percentInTarget),
            (.resonance, current.resonanceScore, previous?.resonance),
            (.weight, current.weightScore, previous?.weight),
            (.intonation, current.intonationScore, previous?.intonation),
        ]
        var changes: [Change] = []
        for (metric, value, before) in pairs {
            guard let value else { continue }
            changes.append(Change(
                metric: metric,
                value: value,
                previous: before,
                isBetter: QuickCheckComparison.isBetter(metric, value: value, previous: before, target: target)
            ))
        }
        self.changes = changes
        hasPrevious = previous != nil
    }

    /// One line for the top of the result.
    var headline: String {
        guard hasPrevious else {
            return "Your first Quick Check. Next time you’ll see how today compares."
        }
        let compared = changes.filter { $0.previous != nil }
        let better = compared.filter { $0.isBetter == true }.count
        let worse = compared.filter { $0.isBetter == false }.count
        if better == 0, worse == 0 {
            return "About the same as last time. Steady is good."
        }
        if worse == 0 {
            return "Better than last time in \(better) of \(compared.count)."
        }
        if better == 0 {
            return "A little off your last check. Tired voices vary; that’s normal."
        }
        return "Better in \(better), lower in \(worse) than last time."
    }

    static func isBetter(_ metric: QuickCheckMetric, value: Double, previous: Double?, target: PitchTargetZone) -> Bool? {
        guard let previous, abs(value - previous) >= metric.threshold else { return nil }
        switch metric {
        case .pitch:
            // Closer to the target zone is better; inside it is all the same.
            let before = distance(previous, from: target)
            let now = distance(value, from: target)
            if before == now { return nil }
            return now < before
        case .inTarget, .resonance, .weight, .intonation:
            return value > previous
        }
    }

    static func distance(_ frequency: Double, from zone: PitchTargetZone) -> Double {
        if frequency < zone.lowerBound { return zone.lowerBound - frequency }
        if frequency > zone.upperBound { return frequency - zone.upperBound }
        return 0
    }
}

/// The numbers of a saved Quick Check (copied out of SwiftData).
nonisolated struct QuickCheckValues: Sendable, Equatable {
    var pitch: Double?
    var percentInTarget: Double?
    var resonance: Double?
    var weight: Double?
    var intonation: Double?
    var date: Date?
}
