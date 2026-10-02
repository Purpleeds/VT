import Foundation

/// What an exercise trains (used for filters and the lesson plan).
nonisolated enum ExerciseSkill: String, Codable, CaseIterable, Identifiable, Sendable {
    case breathing
    case warmUp
    case pitch
    case resonance
    case weight
    case intonation
    case expression
    case carryover
    case coolDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breathing: "Breathing"
        case .warmUp: "Warm-up"
        case .pitch: "Pitch"
        case .resonance: "Resonance"
        case .weight: "Vocal weight"
        case .intonation: "Intonation"
        case .expression: "Expression"
        case .carryover: "Real speech"
        case .coolDown: "Cool-down"
        }
    }

    var systemImage: String {
        switch self {
        case .breathing: "wind"
        case .warmUp: "flame"
        case .pitch: "music.note"
        case .resonance: "speaker.wave.2"
        case .weight: "leaf"
        case .intonation: "waveform.path"
        case .expression: "face.smiling"
        case .carryover: "bubble.left.and.bubble.right"
        case .coolDown: "moon"
        }
    }
}

/// How an exercise runs in the player.
nonisolated enum ExerciseKind: String, Codable, Sendable {
    /// Follow the instructions for the set time, with live meters.
    case timed
    /// Like `timed`, with the live pitch graph emphasized.
    case glide
    /// Listen to reference tones and hum them back.
    case pitchMatch
    /// Hold a vowel for the set time; measures bright resonance.
    case hold
    /// Read a passage; measured.
    case reading
    /// Say a list of words or phrases; measured.
    case phrases
    /// A scenario conversation (see Scenarios).
    case scenario

    /// True when the player records and scores the exercise.
    var isMeasured: Bool {
        switch self {
        case .hold, .reading, .phrases, .pitchMatch: true
        case .timed, .glide, .scenario: false
        }
    }
}

/// Where pitch-match tones come from.
nonisolated enum ToneMode: String, Codable, Sendable {
    /// Spread between the user's usual pitch and the middle of the target.
    case comfortable
    /// 10–20 Hz above the user's usual pitch.
    case stepUp
    /// Inside the target zone.
    case target
}

nonisolated struct Exercise: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let skill: ExerciseSkill
    let kind: ExerciseKind
    let durationSeconds: Int
    let summary: String
    let instructions: [String]
    let howItShouldFeel: String
    var commonMistake: String?
    /// Vowel for holds: "ee", "ih", "ay" or "ah" (a `ResonanceMode` raw value).
    var vowel: String?
    /// Passage for readings.
    var text: String?
    /// Words or phrases, shown one at a time.
    var items: [String]?
    var toneCount: Int?
    var toneMode: ToneMode?
    /// Suitable for Discreet Mode (quiet, or no voice at all).
    var quiet: Bool?

    var resonanceMode: ResonanceMode {
        vowel.flatMap(ResonanceMode.init(rawValue:)) ?? .speech
    }

    var isQuiet: Bool { quiet ?? false }
}

/// A week's measurable goal.
nonisolated struct LessonGoal: Codable, Sendable, Equatable {
    nonisolated enum Kind: String, Codable, Sendable {
        /// Complete `count` lesson sessions.
        case sessions
        /// Match `count` of `total` pitch-match tones in one go.
        case pitchMatch
        /// A held vowel in the bright zone `threshold`% of the time.
        case brightHold
        /// A reading or phrase set bright `threshold`% of the time.
        case brightReading
        /// A reading's median pitch at least `threshold` Hz above the baseline.
        case pitchRaise
        /// A reading `threshold`% in target and bright `secondaryThreshold`%.
        case targetAndBright
        /// A reading with light weight `threshold`% of the time.
        case lightWeight
        /// A reading with an intonation score of at least `threshold`.
        case intonation
        /// Complete `count` scenario practices.
        case scenarios
        /// Re-record the baseline.
        case baseline
    }

    let kind: Kind
    let description: String
    var threshold: Double?
    var secondaryThreshold: Double?
    var count: Int?
    var total: Int?
    var requiresNoStrain: Bool?
}

nonisolated struct LessonWeek: Codable, Sendable, Identifiable, Hashable {
    let week: Int
    let phase: Int
    let phaseTitle: String
    let title: String
    let summary: String
    let explanation: String
    let whyItMatters: String
    let steps: [String]
    let goal: LessonGoal
    let commonMistakes: [String]
    let howItShouldFeel: [String]
    let exercises: [Exercise]
    let carryover: [Exercise]

    var id: Int { week }
    var lessonID: String { "week-\(week)" }

    static func == (lhs: LessonWeek, rhs: LessonWeek) -> Bool { lhs.week == rhs.week }
    func hash(into hasher: inout Hasher) { hasher.combine(week) }
}

nonisolated struct MaintenanceRoutine: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    /// Matches a `ProgressMetric` raw value, so a weak area can pick it.
    let focus: String
    let summary: String
    let exercises: [Exercise]

    static func == (lhs: MaintenanceRoutine, rhs: MaintenanceRoutine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated struct MaintenancePlan: Codable, Sendable {
    let title: String
    let explanation: String
    let dailyMinutes: Int
    let routines: [MaintenanceRoutine]
    let weeklyChallenges: [String]

    /// The routine for a focus area (the weakest measure this week), or a
    /// rotating routine when there's no data.
    func routine(focus: ProgressMetric?, dayOfYear: Int) -> MaintenanceRoutine? {
        if let focus, let match = routines.first(where: { $0.focus == focus.rawValue && $0.id != "balanced" }) {
            return match
        }
        guard !routines.isEmpty else { return nil }
        return routines[((dayOfYear % routines.count) + routines.count) % routines.count]
    }

    func weeklyChallenge(weekOfYear: Int) -> String? {
        guard !weeklyChallenges.isEmpty else { return nil }
        return weeklyChallenges[((weekOfYear % weeklyChallenges.count) + weeklyChallenges.count) % weeklyChallenges.count]
    }
}

/// All lesson content, loaded from Lessons.json (SPEC section 6: "Store all
/// lessons in a JSON file for easy editing").
nonisolated struct LessonCatalog: Codable, Sendable {
    let version: Int
    let warmups: [Exercise]
    let cooldowns: [Exercise]
    let weeks: [LessonWeek]
    let maintenance: MaintenancePlan

    static let fileName = "Lessons"

    nonisolated enum LoadError: LocalizedError {
        case missingFile
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingFile: "The lesson plan is missing from the app."
            case .unreadable(let detail): "The lesson plan couldn’t be read (\(detail))."
            }
        }
    }

    static func load(from bundle: Bundle = .main) throws -> LessonCatalog {
        guard let url = bundle.url(forResource: fileName, withExtension: "json") else {
            throw LoadError.missingFile
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
    }

    static func decode(_ data: Data) throws -> LessonCatalog {
        do {
            return try JSONDecoder().decode(LessonCatalog.self, from: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
    }

    func week(_ number: Int) -> LessonWeek? {
        weeks.first { $0.week == number }
    }

    var totalWeeks: Int { weeks.map(\.week).max() ?? 0 }

    /// Every distinct exercise (lessons, warm-ups, cool-downs, maintenance),
    /// for the exercise library.
    var allExercises: [Exercise] {
        var seen = Set<String>()
        var result: [Exercise] = []
        let everything = warmups + weeks.flatMap { $0.exercises + $0.carryover } + maintenance.routines.flatMap(\.exercises) + cooldowns
        for exercise in everything where !seen.contains(exercise.id) {
            seen.insert(exercise.id)
            result.append(exercise)
        }
        return result
    }
}
