import Foundation

/// Google Gemini (free tier) with the user's own API key, used only when
/// on-device AI isn't available (SPEC section 10, option 2). Only text
/// (stats, transcripts, chat messages) is sent; never audio.
nonisolated struct GeminiCoach: AICoachService {
    let apiKey: String
    var model = "gemini-2.5-flash"

    var engine: CoachEngine { .gemini }

    // MARK: Requests

    nonisolated struct Part: Codable, Sendable, Equatable {
        let text: String
    }

    nonisolated struct Content: Codable, Sendable, Equatable {
        var role: String?
        let parts: [Part]
    }

    nonisolated struct ThinkingConfig: Codable, Sendable, Equatable {
        let thinkingBudget: Int
    }

    nonisolated struct GenerationConfig: Codable, Sendable, Equatable {
        var temperature: Double
        var maxOutputTokens: Int
        var responseMimeType: String?
        var thinkingConfig: ThinkingConfig?
    }

    nonisolated struct RequestBody: Codable, Sendable, Equatable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    nonisolated struct ResponseBody: Codable, Sendable {
        nonisolated struct Candidate: Codable, Sendable {
            let content: Content?
        }

        nonisolated struct APIError: Codable, Sendable {
            let code: Int?
            let message: String?
        }

        let candidates: [Candidate]?
        let error: APIError?
    }

    /// The HTTPS request. The key goes in a header, not the URL.
    func makeRequest(prompt: String, json: Bool, history: [Content] = []) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw CoachError.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body = RequestBody(
            systemInstruction: Content(role: nil, parts: [Part(text: CoachSafety.instructions)]),
            contents: history + [Content(role: "user", parts: [Part(text: prompt)])],
            generationConfig: GenerationConfig(
                temperature: 0.7,
                maxOutputTokens: 900,
                responseMimeType: json ? "application/json" : nil,
                thinkingConfig: ThinkingConfig(thinkingBudget: 0)
            )
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// The text of the first candidate.
    static func text(from data: Data) throws -> String {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw CoachError.badResponse
        }
        if let error = body.error {
            throw CoachError.server(error.message ?? "code \(error.code ?? 0)")
        }
        let text = body.candidates?.first?.content?.parts.map(\.text).joined() ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.badResponse
        }
        return text
    }

    /// Decodes a JSON answer (ignoring ``` fences).
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = CoachPrompts.jsonBody(text).data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data)
        else { throw CoachError.badResponse }
        return value
    }

    private func send(prompt: String, json: Bool, history: [Content] = []) async throws -> String {
        let request = try makeRequest(prompt: prompt, json: json, history: history)
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw CoachError.network(error.localizedDescription)
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let message = try? Self.text(from: data) {
                throw CoachError.server(message)
            }
            throw CoachError.server("HTTP \(http.statusCode)")
        }
        return try Self.text(from: data)
    }

    // MARK: JSON answer shapes

    nonisolated struct FeedbackAnswer: Codable, Sendable {
        let summary: String
        let tips: [String]
        let exerciseID: String?
    }

    nonisolated struct ReviewAnswer: Codable, Sendable {
        let recommendation: String
        let focus: String?
        let message: String
    }

    nonisolated struct TextAnswer: Codable, Sendable {
        let title: String
        let text: String
    }

    nonisolated struct PartnerAnswer: Codable, Sendable {
        let line: String
        let hint: String?
    }

    // MARK: AICoachService

    func sessionFeedback(_ context: CoachSessionContext) async throws -> CoachFeedback {
        let prompt = CoachPrompts.sessionFeedback(context) + "\nAnswer as JSON: {\"summary\": string, \"tips\": [string], \"exerciseID\": string}"
        let raw = try await send(prompt: prompt, json: true)
        let answer = try Self.decode(FeedbackAnswer.self, from: raw)
        return CoachAnswers.feedback(summary: answer.summary, tips: answer.tips, exerciseID: answer.exerciseID, context: context, engine: engine)
    }

    func weeklyReview(_ context: WeeklyReviewContext) async throws -> WeeklyReview {
        let prompt = CoachPrompts.weeklyReview(context) + "\nAnswer as JSON: {\"recommendation\": string, \"focus\": string, \"message\": string}"
        let raw = try await send(prompt: prompt, json: true)
        let answer = try Self.decode(ReviewAnswer.self, from: raw)
        return try CoachAnswers.review(recommendation: answer.recommendation, focus: answer.focus, message: answer.message, context: context, engine: engine)
    }

    func practiceText(_ request: PracticeTextRequest) async throws -> PracticeText {
        let prompt = CoachPrompts.practiceText(request) + "\nAnswer as JSON: {\"title\": string, \"text\": string}"
        let raw = try await send(prompt: prompt, json: true)
        let answer = try Self.decode(TextAnswer.self, from: raw)
        return try CoachAnswers.text(title: answer.title, text: answer.text, engine: engine)
    }

    func partnerLine(_ request: PartnerRequest) async throws -> PartnerLine {
        let prompt = CoachPrompts.partnerTurn(request) + "\nAnswer as JSON: {\"line\": string, \"hint\": string}"
        let raw = try await send(prompt: prompt, json: true)
        let answer = try Self.decode(PartnerAnswer.self, from: raw)
        return try CoachAnswers.partner(line: answer.line, hint: answer.hint)
    }

    func chatReply(_ messages: [CoachChatMessage]) async throws -> String {
        // Earlier messages go as the conversation; the last one as the prompt.
        let earlier = messages.dropLast().suffix(10).map { message in
            Content(role: message.role == .user ? "user" : "model", parts: [Part(text: message.text)])
        }
        let question = messages.last { $0.role == .user }?.text ?? ""
        return try await send(prompt: question, json: false, history: Array(earlier))
    }
}

/// Checks and tidies answers from either AI coach.
nonisolated enum CoachAnswers {
    static func feedback(summary: String, tips: [String], exerciseID: String?, context: CoachSessionContext, engine: CoachEngine) -> CoachFeedback {
        let rules = RuleBasedCoach().feedback(context)
        var safe = Array(CoachSafety.safeTips(tips).prefix(3))
        // Strain always comes first, whatever the model said.
        if let strain = rules.tips.first, strain.hasPrefix("Your voice showed signs of strain"), !safe.contains(strain) {
            safe.insert(strain, at: 0)
            safe = Array(safe.prefix(3))
        }
        if safe.count < 2 {
            safe = rules.tips
        }
        let exercise = context.exercises.first { $0.id == exerciseID }
            ?? rules.exerciseID.flatMap { id in context.exercises.first { $0.id == id } }
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachFeedback(
            summary: cleanSummary.isEmpty || CoachSafety.isUnsafe(cleanSummary) ? rules.summary : CoachSafety.shortened(cleanSummary, limit: 200),
            tips: safe.map { CoachSafety.shortened($0, limit: 300) },
            exerciseID: exercise?.id,
            exerciseTitle: exercise?.title,
            engine: engine.rawValue
        )
    }

    static func review(recommendation: String, focus: String?, message: String, context: WeeklyReviewContext, engine: CoachEngine) throws -> WeeklyReview {
        guard var kind = WeeklyRecommendation(rawValue: recommendation) else { throw CoachError.badResponse }
        // Sore throats always mean rest, whatever the model suggested.
        if context.soreCheckIns >= 2 {
            kind = .rest
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !CoachSafety.isUnsafe(text) else { throw CoachError.badResponse }
        let metric = focus.flatMap(ProgressMetric.init(rawValue:))
        return WeeklyReview(recommendation: kind, focus: metric?.rawValue, message: CoachSafety.shortened(text, limit: 500), engine: engine.rawValue)
    }

    static func text(title: String, text: String, engine: CoachEngine) throws -> PracticeText {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 20 else { throw CoachError.badResponse }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return PracticeText(title: cleanTitle.isEmpty ? "Practice passage" : CoachSafety.shortened(cleanTitle, limit: 60), text: CoachSafety.shortened(body, limit: 1_200), engine: engine.rawValue)
    }

    static func partner(line: String, hint: String?) throws -> PartnerLine {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CoachError.badResponse }
        let cleanHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PartnerLine(line: CoachSafety.shortened(text, limit: 300), hint: (cleanHint?.isEmpty ?? true) ? nil : cleanHint)
    }
}
