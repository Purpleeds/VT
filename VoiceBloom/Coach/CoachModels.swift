import Foundation

// MARK: - What the coach is given (text and numbers only, never audio)

/// One session's numbers, as the coach sees them.
nonisolated struct CoachSessionStats: Codable, Sendable, Equatable {
    var minutes: Double
    var averagePitch: Double?
    var percentInTarget: Double?
    var resonance: Double?
    var weight: Double?
    var intonation: Double?
    var slipAlerts: Int = 0
    var strainWarnings: Int = 0
    /// "fine", "tired" or "sore" from the check-in.
    var comfort: String?

    func value(_ metric: ProgressMetric) -> Double? {
        switch metric {
        case .inTarget: percentInTarget
        case .resonance: resonance
        case .weight: weight
        case .intonation: intonation
        }
    }
}

/// An exercise the coach may recommend.
nonisolated struct CoachExerciseOption: Codable, Sendable, Equatable {
    let id: String
    let title: String
    /// An `ExerciseSkill` raw value.
    let skill: String
}

nonisolated struct CoachSessionContext: Sendable, Equatable {
    let session: CoachSessionStats
    /// Up to five earlier sessions, newest first.
    let recent: [CoachSessionStats]
    let target: PitchTargetZone
    let exercises: [CoachExerciseOption]

    /// Average of the recent sessions for a measure.
    func recentAverage(_ metric: ProgressMetric) -> Double? {
        let values = recent.compactMap { $0.value(metric) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The lowest-scoring measure this session.
    var weakestMetric: ProgressMetric? {
        ProgressMetric.allCases
            .compactMap { metric in session.value(metric).map { (metric, $0) } }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - What the coach returns

nonisolated struct CoachFeedback: Codable, Sendable, Equatable {
    let summary: String
    let tips: [String]
    let exerciseID: String?
    let exerciseTitle: String?
    /// Which coach wrote it (`CoachEngine` raw value).
    var engine: String

    /// Stored in `PracticeSession.aiFeedback` as JSON.
    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ text: String?) -> CoachFeedback? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachFeedback.self, from: data)
    }
}

nonisolated struct WeeklyReviewContext: Sendable, Equatable {
    let week: Int
    let weekTitle: String
    let sessionsThisWeek: Int
    let requiredSessions: Int
    let goalMet: Bool
    let goalDescription: String
    /// Minutes practiced in the last 7 days.
    let practiceMinutes: Double
    let dailyGoalMinutes: Int
    /// Averages over the last 7 days and the 7 days before.
    let averages: [ProgressMetric: Double]
    let previousAverages: [ProgressMetric: Double]
    /// "Sore" check-ins in the last 7 days.
    let soreCheckIns: Int
    let isLastWeek: Bool

    var weakestMetric: ProgressMetric? {
        ProgressMetric.allCases.compactMap { metric in averages[metric].map { (metric, $0) } }.min { $0.1 < $1.1 }?.0
    }
}

nonisolated enum WeeklyRecommendation: String, Codable, Sendable, CaseIterable {
    case moveOn
    case repeatWeek
    case extraPractice
    case rest

    var title: String {
        switch self {
        case .moveOn: "Ready to move on"
        case .repeatWeek: "Stay with this week"
        case .extraPractice: "Extra practice"
        case .rest: "Rest first"
        }
    }

    var systemImage: String {
        switch self {
        case .moveOn: "arrow.right.circle.fill"
        case .repeatWeek: "arrow.counterclockwise.circle.fill"
        case .extraPractice: "target"
        case .rest: "bed.double.fill"
        }
    }
}

nonisolated struct WeeklyReview: Codable, Sendable, Equatable {
    let recommendation: WeeklyRecommendation
    /// A `ProgressMetric` raw value to focus on, if any.
    let focus: String?
    let message: String
    var engine: String

    var focusMetric: ProgressMetric? { focus.flatMap(ProgressMetric.init(rawValue:)) }
}

/// What a practice passage should train.
nonisolated enum PracticeFocus: String, CaseIterable, Identifiable, Sendable, Codable {
    case brightVowels
    case sibilants
    case questions
    case longSentences
    case namesAndNumbers
    case everyday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightVowels: "Bright “ee” and “ay” vowels"
        case .sibilants: "S and SH sounds"
        case .questions: "Questions and rising melody"
        case .longSentences: "Long sentences (breath and consistency)"
        case .namesAndNumbers: "Names, dates and numbers"
        case .everyday: "Everyday conversation"
        }
    }

    /// Explains the focus to a language model.
    var promptDescription: String {
        switch self {
        case .brightVowels: "lots of words with bright front vowels like “ee” and “ay” (see, tea, day, play)"
        case .sibilants: "lots of crisp s and sh sounds (sunny, sea shells, special)"
        case .questions: "several questions so the melody rises, mixed with statements"
        case .longSentences: "a few long, flowing sentences that need steady breath"
        case .namesAndNumbers: "names, dates, times, addresses and numbers"
        case .everyday: "natural, everyday conversational sentences"
        }
    }
}

nonisolated enum PracticeLength: String, CaseIterable, Identifiable, Sendable, Codable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        }
    }

    var sentenceCount: Int {
        switch self {
        case .short: 2
        case .medium: 4
        case .long: 6
        }
    }
}

nonisolated struct PracticeTextRequest: Sendable, Equatable {
    let focus: PracticeFocus
    let length: PracticeLength
    /// Changes the built-in choice so each request gives a fresh passage.
    var variation: Int = 0
}

nonisolated struct PracticeText: Codable, Sendable, Equatable {
    let title: String
    let text: String
    var engine: String
}

nonisolated struct CoachChatMessage: Identifiable, Sendable, Equatable {
    nonisolated enum Role: String, Sendable {
        case user
        case coach
    }

    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// One exchange in an AI scenario conversation.
nonisolated struct PartnerExchange: Sendable, Equatable {
    let partner: String
    /// What the user said (transcribed on the iPhone), if anything was heard.
    let user: String?
}

nonisolated struct PartnerRequest: Sendable, Equatable {
    let scenarioTitle: String
    let setting: String
    let partnerRole: String
    let difficulty: String
    let turnIndex: Int
    let totalTurns: Int
    let history: [PartnerExchange]
    /// The scripted line for this turn, used as a guide and as the fallback.
    let scriptedLine: String?
    let scriptedPrompt: String
}

nonisolated struct PartnerLine: Codable, Sendable, Equatable {
    let line: String
    /// A short hint for the user's reply.
    let hint: String?
}

// MARK: - Which coach

nonisolated enum CoachEngine: String, Sendable, CaseIterable {
    case onDevice
    case gemini
    case rules

    var title: String {
        switch self {
        case .onDevice: "Apple Intelligence (on this iPhone)"
        case .gemini: "Gemini (your key)"
        case .rules: "Simple tips (no AI)"
        }
    }

    /// Only Gemini sends anything off the iPhone (text only).
    var sendsTextOffDevice: Bool { self == .gemini }

    var isAI: Bool { self != .rules }

    /// Picks the coach (SPEC section 10 priority: on-device, then Gemini only
    /// when on-device AI is unavailable and a key is set, then rules).
    static func choose(enabled: Bool, provider: AICoachProvider, onDeviceAvailable: Bool, hasGeminiKey: Bool) -> CoachEngine {
        guard enabled else { return .rules }
        switch provider {
        case .ruleBased:
            return .rules
        case .onDeviceOnly:
            return onDeviceAvailable ? .onDevice : .rules
        case .automatic:
            if onDeviceAvailable { return .onDevice }
            return hasGeminiKey ? .gemini : .rules
        }
    }
}

nonisolated enum CoachError: LocalizedError, Sendable, Equatable {
    case unavailable
    case badResponse
    case network(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The AI coach isn’t available right now."
        case .badResponse: "The AI coach sent an answer that couldn’t be read."
        case .network(let detail): "Couldn’t reach the AI coach (\(detail))."
        case .server(let detail): "The AI coach returned an error (\(detail))."
        }
    }
}
