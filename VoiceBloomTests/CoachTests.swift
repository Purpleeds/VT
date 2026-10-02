import Foundation
import Testing
@testable import VoiceBloom

private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

private let exercises = [
    CoachExerciseOption(id: "lip-trills", title: "Lip trills", skill: "warmUp"),
    CoachExerciseOption(id: "glide-up", title: "Glide up", skill: "pitch"),
    CoachExerciseOption(id: "ee-hold", title: "Bright ee hold", skill: "resonance"),
    CoachExerciseOption(id: "soft-onsets", title: "Soft onsets", skill: "weight"),
]

private func stats(
    pitch: Double? = 200,
    inTarget: Double? = 60,
    resonance: Double? = 60,
    weight: Double? = 60,
    intonation: Double? = 60,
    slips: Int = 0,
    strain: Int = 0,
    comfort: String? = nil
) -> CoachSessionStats {
    CoachSessionStats(
        minutes: 12,
        averagePitch: pitch,
        percentInTarget: inTarget,
        resonance: resonance,
        weight: weight,
        intonation: intonation,
        slipAlerts: slips,
        strainWarnings: strain,
        comfort: comfort
    )
}

private func weekly(
    sessions: Int = 3,
    goalMet: Bool = false,
    minutes: Double = 80,
    averages: [ProgressMetric: Double] = [.inTarget: 60, .resonance: 55, .weight: 60, .intonation: 50],
    sore: Int = 0
) -> WeeklyReviewContext {
    WeeklyReviewContext(
        week: 4,
        weekTitle: "Bright vowels",
        sessionsThisWeek: sessions,
        requiredSessions: 5,
        goalMet: goalMet,
        goalDescription: "Hold a bright ee 70% of the time.",
        practiceMinutes: minutes,
        dailyGoalMinutes: 15,
        averages: averages,
        previousAverages: [:],
        soreCheckIns: sore,
        isLastWeek: false
    )
}

@Suite("Rule-based coach")
struct RuleBasedCoachTests {
    @Test("Feedback: low pitch, the weakest measure and the trend")
    func feedback() {
        let context = CoachSessionContext(
            session: stats(pitch: 165, inTarget: 35, resonance: 60, weight: 50, intonation: 45, slips: 6),
            recent: [stats(inTarget: 30, resonance: 50, weight: 55, intonation: 40), stats(inTarget: 30, resonance: 50, weight: 55, intonation: 40)],
            target: target,
            exercises: exercises
        )
        let feedback = RuleBasedCoach().feedback(context)
        #expect(feedback.tips.count == 3)
        #expect(feedback.tips[0].contains("165 Hz"))
        #expect(feedback.tips[1].hasPrefix("Pitch was your lowest measure"))
        #expect(feedback.tips[2].hasPrefix("Resonance is up 10 points"))
        #expect(feedback.summary == "Solid practice: 35% of the time in your target over 12 min.")
        #expect(feedback.exerciseID == "glide-up")
        #expect(feedback.engine == "rules")
    }

    @Test("Strain or a sore throat always comes first")
    func strainFirst() {
        let context = CoachSessionContext(session: stats(strain: 1, comfort: "sore"), recent: [], target: target, exercises: exercises)
        let feedback = RuleBasedCoach().feedback(context)
        #expect(feedback.tips.first?.hasPrefix("Your voice showed signs of strain") == true)
        #expect((2...3).contains(feedback.tips.count))
    }

    @Test("There are always at least two tips and an exercise")
    func minimums() {
        let context = CoachSessionContext(session: CoachSessionStats(minutes: 5), recent: [], target: target, exercises: exercises)
        let feedback = RuleBasedCoach().feedback(context)
        #expect(feedback.tips.count >= 2)
        #expect(feedback.exerciseID == "lip-trills")
        #expect(feedback.summary.contains("5 min"))
    }

    @Test("Weekly review recommendations")
    func weeklyReview() {
        let coach = RuleBasedCoach()
        #expect(coach.review(weekly(sore: 2)).recommendation == .rest)
        #expect(coach.review(weekly(sessions: 5, goalMet: true)).recommendation == .moveOn)
        #expect(coach.review(weekly(minutes: 20)).recommendation == .repeatWeek)
        let weak = coach.review(weekly(averages: [.inTarget: 60, .resonance: 30]))
        #expect(weak.recommendation == .extraPractice)
        #expect(weak.focusMetric == .resonance)
        #expect(coach.review(weekly()).recommendation == .repeatWeek)
    }

    @Test("Practice texts vary and have the requested length")
    func practiceTexts() {
        let coach = RuleBasedCoach()
        let first = coach.text(PracticeTextRequest(focus: .sibilants, length: .medium, variation: 0))
        let second = coach.text(PracticeTextRequest(focus: .sibilants, length: .medium, variation: 1))
        #expect(first.text != second.text)
        #expect(first.text.components(separatedBy: ". ").count >= 2)
        for focus in PracticeFocus.allCases {
            let text = coach.text(PracticeTextRequest(focus: focus, length: .long))
            #expect(text.text.count > 100, "\(focus.rawValue)")
        }
    }

    @Test("Chat answers by topic, and pain gets the SLP advice")
    func chat() {
        let coach = RuleBasedCoach()
        #expect(coach.reply(to: "How do I warm up?").contains("lip trills"))
        #expect(coach.reply(to: "My throat hurts after practice").contains("speech-language pathologist"))
        #expect(coach.reply(to: "What's the weather?").contains("I can help with"))
    }

    @Test("The rule-based partner uses the script")
    func partner() async throws {
        let request = PartnerRequest(scenarioTitle: "Coffee", setting: "Café", partnerRole: "Barista", difficulty: "Easy", turnIndex: 1, totalTurns: 4, history: [], scriptedLine: "Any milk?", scriptedPrompt: "Choose a milk.")
        let line = try await RuleBasedCoach().partnerLine(request)
        #expect(line.line == "Any milk?")
        #expect(line.hint == "Choose a milk.")
    }
}

@Suite("Coach safety and choice")
struct CoachSafetyTests {
    @Test("Pain and lasting problems are spotted")
    func medical() {
        #expect(CoachSafety.needsMedicalAdvice("My throat HURTS when I talk"))
        #expect(CoachSafety.needsMedicalAdvice("I've been hoarse for a month"))
        #expect(!CoachSafety.needsMedicalAdvice("How do I sound brighter?"))
    }

    @Test("Unsafe replies are replaced and pain questions get SLP advice")
    func checkedReplies() {
        #expect(CoachSafety.isUnsafe("Just push through it and keep going."))
        #expect(CoachSafety.checkedReply("Just push through it.", question: "Tips?", fallback: "Rest.") == "Rest.")
        let pain = CoachSafety.checkedReply("Try humming gently.", question: "It hurts when I practice", fallback: "Rest.")
        #expect(pain.hasPrefix(CoachSafety.medicalAdvice))
        let already = CoachSafety.checkedReply("Please see a speech-language pathologist.", question: "It hurts", fallback: "Rest.")
        #expect(already == "Please see a speech-language pathologist.")
        #expect(CoachSafety.checkedReply("  ", question: "Tips?", fallback: "Rest.") == "Rest.")
    }

    @Test("Long text is cut at a sentence end")
    func shortening() {
        #expect(CoachSafety.shortened("One. Two. Three.", limit: 9) == "One. Two.")
        #expect(CoachSafety.shortened("Short.", limit: 100) == "Short.")
        #expect(CoachSafety.safeTips(["Push through the pain.", " Rest well. ", ""]) == ["Rest well."])
    }

    @Test("The instructions carry the safety rules")
    func instructions() {
        #expect(CoachSafety.instructions.contains("speech-language pathologist"))
        #expect(CoachSafety.instructions.contains("Never encourage straining"))
        #expect(CoachSafety.instructions.contains("short"))
    }

    @Test("Coach priority: on-device, then Gemini, then rules")
    func engineChoice() {
        #expect(CoachEngine.choose(enabled: false, provider: .automatic, onDeviceAvailable: true, hasGeminiKey: true) == .rules)
        #expect(CoachEngine.choose(enabled: true, provider: .automatic, onDeviceAvailable: true, hasGeminiKey: true) == .onDevice)
        #expect(CoachEngine.choose(enabled: true, provider: .automatic, onDeviceAvailable: false, hasGeminiKey: true) == .gemini)
        #expect(CoachEngine.choose(enabled: true, provider: .automatic, onDeviceAvailable: false, hasGeminiKey: false) == .rules)
        #expect(CoachEngine.choose(enabled: true, provider: .onDeviceOnly, onDeviceAvailable: false, hasGeminiKey: true) == .rules)
        #expect(CoachEngine.choose(enabled: true, provider: .ruleBased, onDeviceAvailable: true, hasGeminiKey: true) == .rules)
        #expect(CoachEngine.gemini.sendsTextOffDevice)
        #expect(!CoachEngine.onDevice.sendsTextOffDevice)
    }
}

@Suite("Coach prompts and answers")
struct CoachPromptTests {
    @Test("Session prompts hold the stats, the trend and the exercise ids")
    func sessionPrompt() {
        let context = CoachSessionContext(session: stats(pitch: 190, strain: 1, comfort: "tired"), recent: [stats()], target: target, exercises: exercises)
        let prompt = CoachPrompts.sessionFeedback(context)
        #expect(prompt.contains("average pitch 190 Hz"))
        #expect(prompt.contains("180–220 Hz"))
        #expect(prompt.contains("1 strain warnings"))
        #expect(prompt.contains("throat felt tired"))
        #expect(prompt.contains("The last 1 sessions"))
        #expect(prompt.contains("glide-up: Glide up (pitch)"))
    }

    @Test("Weekly and partner prompts")
    func otherPrompts() {
        let review = CoachPrompts.weeklyReview(weekly(sore: 1))
        #expect(review.contains("week 4"))
        #expect(review.contains("Sore-throat check-ins in the last 7 days: 1"))
        let request = PartnerRequest(
            scenarioTitle: "Ordering coffee", setting: "A café", partnerRole: "Barista", difficulty: "Medium",
            turnIndex: 3, totalTurns: 4,
            history: [PartnerExchange(partner: "Hi!", user: "A latte, please."), PartnerExchange(partner: "Name?", user: nil)],
            scriptedLine: "That’s seven fifty.", scriptedPrompt: "Pay."
        )
        let partner = CoachPrompts.partnerTurn(request)
        #expect(partner.contains("Learner: A latte, please."))
        #expect(partner.contains("Learner: (not transcribed)"))
        #expect(partner.contains("last turn"))
    }

    @Test("JSON is found inside code fences and extra text")
    func jsonBody() {
        #expect(CoachPrompts.jsonBody("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
        #expect(CoachPrompts.jsonBody("Sure! {\"a\": 1} Hope that helps") == "{\"a\": 1}")
    }

    @Test("Model answers are checked and fall back to safe values")
    func answers() throws {
        let context = CoachSessionContext(session: stats(strain: 1), recent: [], target: target, exercises: exercises)
        let feedback = CoachAnswers.feedback(summary: "Nice work!", tips: ["Push through the pain", "Smile while you talk."], exerciseID: "ee-hold", context: context, engine: .onDevice)
        #expect(feedback.tips.first?.hasPrefix("Your voice showed signs of strain") == true)
        #expect(!feedback.tips.contains { $0.contains("Push through") })
        #expect(feedback.exerciseID == "ee-hold")
        #expect(feedback.engine == "onDevice")

        let unknown = CoachAnswers.feedback(summary: "", tips: ["One tip."], exerciseID: "nope", context: context, engine: .gemini)
        #expect(unknown.tips.count >= 2)
        #expect(unknown.exerciseID != "nope")

        let forcedRest = try CoachAnswers.review(recommendation: "moveOn", focus: "resonance", message: "Great week!", context: weekly(sore: 3), engine: .gemini)
        #expect(forcedRest.recommendation == .rest)
        #expect(forcedRest.focusMetric == .resonance)
        #expect(throws: CoachError.self) {
            _ = try CoachAnswers.review(recommendation: "party", focus: nil, message: "Hi", context: weekly(), engine: .gemini)
        }
        #expect(throws: CoachError.self) {
            _ = try CoachAnswers.text(title: "T", text: "Too short", engine: .gemini)
        }
    }

    @Test("Feedback round-trips through the session's text field")
    func storage() {
        let feedback = CoachFeedback(summary: "Good", tips: ["A", "B"], exerciseID: "x", exerciseTitle: "X", engine: "rules")
        #expect(CoachFeedback.decode(feedback.encoded()) == feedback)
        #expect(CoachFeedback.decode("not json") == nil)
        #expect(CoachFeedback.decode(nil) == nil)
    }
}

@Suite("Gemini requests")
struct GeminiCoachTests {
    @Test("The key goes in a header and only text is sent")
    func request() throws {
        let coach = GeminiCoach(apiKey: "test-key")
        let request = try coach.makeRequest(prompt: "Hello", json: true)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.absoluteString.contains("test-key") == false)
        #expect(request.url?.absoluteString.contains("gemini-2.5-flash:generateContent") == true)
        let data = try #require(request.httpBody)
        let body = try JSONDecoder().decode(GeminiCoach.RequestBody.self, from: data)
        #expect(body.contents.last?.parts.first?.text == "Hello")
        #expect(body.contents.last?.role == "user")
        #expect(body.systemInstruction.parts.first?.text == CoachSafety.instructions)
        #expect(body.generationConfig.responseMimeType == "application/json")
    }

    @Test("Answers and errors are read from the response")
    func responses() throws {
        let ok = Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hi "},{"text":"there"}]}}]}"#.utf8)
        #expect(try GeminiCoach.text(from: ok) == "Hi there")
        let error = Data(#"{"error":{"code":400,"message":"API key not valid"}}"#.utf8)
        #expect(throws: CoachError.server("API key not valid")) {
            _ = try GeminiCoach.text(from: error)
        }
        #expect(throws: CoachError.badResponse) {
            _ = try GeminiCoach.text(from: Data("nonsense".utf8))
        }
        let answer = try GeminiCoach.decode(GeminiCoach.TextAnswer.self, from: "```json\n{\"title\": \"Sun\", \"text\": \"Sunny days.\"}\n```")
        #expect(answer.title == "Sun")
    }
}
