import Foundation
import FoundationModels

/// Apple's on-device model (SPEC section 10, option 1): free, private, no
/// key. Structured answers use @Generable types.
nonisolated struct FoundationModelsCoach: AICoachService {
    var engine: CoachEngine { .onDevice }

    /// True when Apple Intelligence is on and the model is ready.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Why it isn't available, for Settings.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn’t support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in the Settings app."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Try again later."
        case .unavailable:
            return "Apple Intelligence isn’t available right now."
        }
    }

    private func session() throws -> LanguageModelSession {
        guard Self.isAvailable else { throw CoachError.unavailable }
        return LanguageModelSession(instructions: CoachSafety.instructions)
    }

    func sessionFeedback(_ context: CoachSessionContext) async throws -> CoachFeedback {
        let response = try await session().respond(to: CoachPrompts.sessionFeedback(context), generating: GeneratedFeedback.self)
        let answer = response.content
        return CoachAnswers.feedback(summary: answer.summary, tips: answer.tips, exerciseID: answer.exerciseID, context: context, engine: engine)
    }

    func weeklyReview(_ context: WeeklyReviewContext) async throws -> WeeklyReview {
        let response = try await session().respond(to: CoachPrompts.weeklyReview(context), generating: GeneratedReview.self)
        let answer = response.content
        return try CoachAnswers.review(recommendation: answer.recommendation, focus: answer.focus, message: answer.message, context: context, engine: engine)
    }

    func practiceText(_ request: PracticeTextRequest) async throws -> PracticeText {
        let response = try await session().respond(to: CoachPrompts.practiceText(request), generating: GeneratedText.self)
        let answer = response.content
        return try CoachAnswers.text(title: answer.title, text: answer.text, engine: engine)
    }

    func partnerLine(_ request: PartnerRequest) async throws -> PartnerLine {
        let response = try await session().respond(to: CoachPrompts.partnerTurn(request), generating: GeneratedPartnerLine.self)
        let answer = response.content
        return try CoachAnswers.partner(line: answer.line, hint: answer.hint)
    }

    func chatReply(_ messages: [CoachChatMessage]) async throws -> String {
        let response = try await session().respond(to: CoachPrompts.chat(messages))
        return response.content
    }
}

@Generable
nonisolated struct GeneratedFeedback {
    @Guide(description: "One encouraging sentence summing up the session")
    var summary: String
    @Guide(description: "Two or three short, specific and safe tips based on the numbers")
    var tips: [String]
    @Guide(description: "The id of exactly one exercise from the list in the prompt")
    var exerciseID: String
}

@Generable
nonisolated struct GeneratedReview {
    @Guide(description: "One of: moveOn, repeatWeek, extraPractice, rest")
    var recommendation: String
    @Guide(description: "One of: inTarget, resonance, weight, intonation, none")
    var focus: String
    @Guide(description: "Two or three supportive sentences explaining the recommendation")
    var message: String
}

@Generable
nonisolated struct GeneratedText {
    @Guide(description: "A short title")
    var title: String
    @Guide(description: "The reading passage")
    var text: String
}

@Generable
nonisolated struct GeneratedPartnerLine {
    @Guide(description: "What the character says next, one or two short sentences")
    var line: String
    @Guide(description: "A hint under 12 words for how the learner could reply")
    var hint: String
}
