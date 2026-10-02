import Foundation

/// Safety rules for every coach (SPEC section 10): never encourage straining
/// or pushing through pain, point to a speech-language pathologist for pain
/// or lasting problems, keep answers short and supportive.
nonisolated enum CoachSafety {
    /// System instructions shared by the on-device model and Gemini.
    static let instructions = """
    You are the voice coach inside VoiceBloom, an app for people practicing voice feminization (pitch, resonance, vocal weight and intonation).
    Rules you must always follow:
    - Give safe, general voice-training advice only. You are not a doctor and you never diagnose.
    - Never encourage straining, forcing pitch, long falsetto, shouting, whispering for long periods, or pushing through pain or hoarseness.
    - If the person mentions pain, soreness, burning, hoarseness that lasts, losing their voice, or blood, tell them to stop practicing, rest their voice, and see a speech-language pathologist (SLP) or doctor.
    - Recommend short, frequent practice (5–20 minutes), hydration, warm-ups and rest days.
    - Keep answers short (under 120 words), warm, encouraging and specific. No guilt-tripping.
    - Stay on the topic of voice training and vocal health; politely decline anything else.
    """

    /// Shown (and added to replies) when someone mentions pain or lasting problems.
    static let medicalAdvice = "Please stop practicing for now and rest your voice. Pain, burning or hoarseness that lasts more than a couple of weeks should be checked by a speech-language pathologist (SLP) or a doctor. Training should never hurt."

    private static let medicalWords = [
        "pain", "painful", "hurt", "hurts", "hurting", "sore", "burning", "burns", "hoarse", "hoarseness",
        "lost my voice", "losing my voice", "can't speak", "cannot speak", "can’t speak", "blood", "bleeding",
        "lump", "swallowing", "raw throat", "voice cracks all the time",
    ]

    private static let unsafePhrases = [
        "push through", "through the pain", "ignore the pain", "even if it hurts", "despite the pain",
        "no pain, no gain", "no pain no gain", "keep going if it hurts", "it's normal for it to hurt",
        "it’s normal for it to hurt", "force your voice", "strain your voice",
    ]

    /// True when a message mentions pain or a lasting problem.
    static func needsMedicalAdvice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return medicalWords.contains { lowered.contains($0) }
    }

    /// True when a reply breaks the safety rules.
    static func isUnsafe(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        return unsafePhrases.contains { lowered.contains($0) }
    }

    /// Makes a chat reply safe: replaces unsafe replies, adds the SLP advice
    /// when the question was about pain, and keeps it short.
    static func checkedReply(_ reply: String, question: String, fallback: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || isUnsafe(text) {
            text = fallback
        }
        if needsMedicalAdvice(question) {
            let lowered = text.lowercased()
            let mentionsHelp = lowered.contains("speech-language") || lowered.contains("slp") || lowered.contains("doctor")
            if !mentionsHelp {
                text = medicalAdvice + "\n\n" + text
            }
        }
        return shortened(text, limit: 1_200)
    }

    /// Cuts long text at a sentence end near `limit` characters.
    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        if let end = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...end])
        }
        return prefix + "…"
    }

    /// Tips from any coach that would be unsafe are dropped.
    static func safeTips(_ tips: [String]) -> [String] {
        tips.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !isUnsafe($0) }
    }
}

/// Builds the text prompts. Only numbers and words are included; audio is
/// never sent anywhere.
nonisolated enum CoachPrompts {
    static func describe(_ stats: CoachSessionStats) -> String {
        var parts = ["\(Int(stats.minutes.rounded())) min"]
        if let pitch = stats.averagePitch { parts.append("average pitch \(Int(pitch.rounded())) Hz") }
        if let value = stats.percentInTarget { parts.append("\(Int(value.rounded()))% of the time in the target range") }
        if let value = stats.resonance { parts.append("resonance \(Int(value.rounded()))/100") }
        if let value = stats.weight { parts.append("lightness \(Int(value.rounded()))/100") }
        if let value = stats.intonation { parts.append("intonation \(Int(value.rounded()))/100") }
        if stats.slipAlerts > 0 { parts.append("\(stats.slipAlerts) slip alerts") }
        if stats.strainWarnings > 0 { parts.append("\(stats.strainWarnings) strain warnings") }
        if let comfort = stats.comfort { parts.append("throat felt \(comfort)") }
        return parts.joined(separator: ", ")
    }

    static func sessionFeedback(_ context: CoachSessionContext) -> String {
        var lines = [
            "Write feedback for this voice practice session.",
            "Target pitch range: \(context.target.formatted). Scores run 0–100 (higher is closer to the target).",
            "This session: \(describe(context.session)).",
        ]
        if context.recent.isEmpty {
            lines.append("There are no earlier sessions yet.")
        } else {
            lines.append("The last \(context.recent.count) sessions, newest first:")
            for stats in context.recent {
                lines.append("- \(describe(stats))")
            }
        }
        lines.append("Give a one-sentence summary, 2 or 3 specific tips based on these numbers and the trend, and recommend exactly one exercise by its id from this list:")
        for exercise in context.exercises {
            lines.append("- \(exercise.id): \(exercise.title) (\(exercise.skill))")
        }
        return lines.joined(separator: "\n")
    }

    static func weeklyReview(_ context: WeeklyReviewContext) -> String {
        var lines = [
            "Review this person's week of voice training and recommend what to do next.",
            "Current lesson: week \(context.week), “\(context.weekTitle)”. Goal: \(context.goalDescription)",
            "Lesson sessions this week: \(context.sessionsThisWeek) of \(context.requiredSessions) needed. Goal met: \(context.goalMet ? "yes" : "no").",
            "Practice in the last 7 days: \(Int(context.practiceMinutes.rounded())) minutes (daily goal \(context.dailyGoalMinutes) min).",
            "Sore-throat check-ins in the last 7 days: \(context.soreCheckIns).",
        ]
        for metric in ProgressMetric.allCases {
            let now = context.averages[metric].map { "\(Int($0.rounded()))" } ?? "no data"
            let before = context.previousAverages[metric].map { "\(Int($0.rounded()))" } ?? "no data"
            lines.append("\(metric.title): this week \(now), the week before \(before).")
        }
        lines.append("Recommendation must be one of: moveOn, repeatWeek, extraPractice, rest. Use rest if there were 2 or more sore check-ins. Focus must be one of: inTarget, resonance, weight, intonation, none.")
        return lines.joined(separator: "\n")
    }

    static func practiceText(_ request: PracticeTextRequest) -> String {
        """
        Write a fresh, original reading passage for voice practice with \(request.length.sentenceCount) sentences.
        It should contain \(request.focus.promptDescription).
        Keep it friendly, everyday and easy to read aloud. No quotes from books, songs or films. Give it a short title.
        """
    }

    static func partnerTurn(_ request: PartnerRequest) -> String {
        var lines = [
            "You are playing the \(request.partnerRole) in a voice-practice role play: \(request.scenarioTitle).",
            "Setting: \(request.setting). Difficulty: \(request.difficulty).",
            "Stay in character, speak naturally in one or two short sentences, and keep the conversation going. This is turn \(request.turnIndex + 1) of \(request.totalTurns).",
        ]
        if request.turnIndex + 1 >= request.totalTurns {
            lines.append("This is the last turn: wrap up the conversation politely.")
        }
        if let scripted = request.scriptedLine {
            lines.append("For reference, the scripted line for this turn was: \(scripted)")
        }
        if !request.history.isEmpty {
            lines.append("Conversation so far:")
            for exchange in request.history {
                lines.append("\(request.partnerRole): \(exchange.partner)")
                lines.append("Learner: \(exchange.user ?? "(not transcribed)")")
            }
        }
        lines.append("Also give a short hint (under 12 words) for how the learner could reply.")
        return lines.joined(separator: "\n")
    }

    /// The chat history as plain text for a single prompt.
    static func chat(_ messages: [CoachChatMessage]) -> String {
        let recent = messages.suffix(10)
        var lines = ["Conversation with the learner (answer their last message):"]
        for message in recent {
            lines.append("\(message.role == .user ? "Learner" : "Coach"): \(message.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Strips ``` fences around JSON some models add.
    static func jsonBody(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            if let newline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: newline)...])
            }
            if body.hasSuffix("```") {
                body = String(body.dropLast(3))
            }
        }
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end {
            body = String(body[start...end])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A coach (SPEC section 10). Every method must be safe to fall back from:
/// callers use `RuleBasedCoach` when one throws.
nonisolated protocol AICoachService: Sendable {
    var engine: CoachEngine { get }
    func sessionFeedback(_ context: CoachSessionContext) async throws -> CoachFeedback
    func weeklyReview(_ context: WeeklyReviewContext) async throws -> WeeklyReview
    func practiceText(_ request: PracticeTextRequest) async throws -> PracticeText
    func partnerLine(_ request: PartnerRequest) async throws -> PartnerLine
    /// Answers the last user message.
    func chatReply(_ messages: [CoachChatMessage]) async throws -> String
}
