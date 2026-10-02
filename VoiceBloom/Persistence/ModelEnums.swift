import Foundation

// Enums stored in SwiftData models as their String raw values (raw values are
// robust to schema changes and work in predicates and with CloudKit).

/// What the user is training toward.
nonisolated enum GoalType: String, CaseIterable, Identifiable, Sendable, Codable {
    case feminine
    case androgynous
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feminine: "Feminine"
        case .androgynous: "Androgynous"
        case .custom: "Custom"
        }
    }

    /// Default pitch target for the goal (custom starts from feminine).
    var defaultTarget: PitchTargetZone {
        switch self {
        case .feminine, .custom: .feminine
        case .androgynous: .androgynous
        }
    }
}

nonisolated enum ExperienceLevel: String, CaseIterable, Identifiable, Sendable, Codable {
    case beginner
    case someTraining
    case experienced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beginner: "Beginner"
        case .someTraining: "Some training"
        case .experienced: "Experienced"
        }
    }
}

nonisolated enum SessionLength: String, CaseIterable, Identifiable, Sendable, Codable {
    case quick
    case standard
    case deep

    var id: String { rawValue }

    var minutes: Int {
        switch self {
        case .quick: 5
        case .standard: 15
        case .deep: 25
        }
    }
}

nonisolated enum DisplayUnits: String, CaseIterable, Identifiable, Sendable, Codable {
    case hertz
    case noteNames
    case both

    var id: String { rawValue }
}

nonisolated enum AppTheme: String, CaseIterable, Identifiable, Sendable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// What kind of practice a session was.
nonisolated enum PracticeSessionKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case freePractice
    case lesson
    case quickCheck
    case scenario
    case journal
    case baseline
    case placement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freePractice: "Free practice"
        case .lesson: "Lesson"
        case .quickCheck: "Quick Check"
        case .scenario: "Scenario"
        case .journal: "Daily journal"
        case .baseline: "Baseline"
        case .placement: "Placement test"
        }
    }
}

/// "How did your throat feel?" after a session.
nonisolated enum ComfortRating: String, CaseIterable, Identifiable, Sendable, Codable {
    case fine
    case tired
    case sore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fine: "Fine"
        case .tired: "A bit tired"
        case .sore: "Sore"
        }
    }

    var systemImage: String {
        switch self {
        case .fine: "checkmark.circle"
        case .tired: "moon.zzz"
        case .sore: "exclamationmark.triangle"
        }
    }
}

nonisolated enum RecordingKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case clip
    case baseline
    case journal
    case quickCheck
    case scenario
    case placement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clip: "Practice clip"
        case .baseline: "Baseline"
        case .journal: "Journal"
        case .quickCheck: "Quick Check"
        case .scenario: "Scenario"
        case .placement: "Placement"
        }
    }
}

nonisolated enum ScenarioDifficulty: String, CaseIterable, Identifiable, Sendable, Codable {
    case easy
    case medium
    case hard

    var id: String { rawValue }
}

/// Scores for one turn of a scenario (stored as JSON in `ScenarioResult`).
nonisolated struct ScenarioTurnScore: Codable, Sendable, Equatable {
    var pitch: Double?
    var resonance: Double?
    var weight: Double?
    var intonation: Double?
    var consistency: Double?
    var text: String?
}
