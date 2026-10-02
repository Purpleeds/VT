import Foundation

/// Preset tips from the numbers, so the app always has a coach without AI
/// (SPEC section 10, option 3). Deterministic and fully on-device.
nonisolated struct RuleBasedCoach: AICoachService {
    var engine: CoachEngine { .rules }

    // MARK: Post-session feedback

    func sessionFeedback(_ context: CoachSessionContext) async throws -> CoachFeedback {
        feedback(context)
    }

    func feedback(_ context: CoachSessionContext) -> CoachFeedback {
        let stats = context.session
        var tips: [String] = []

        if stats.strainWarnings > 0 || stats.comfort == ComfortRating.sore.rawValue {
            tips.append("Your voice showed signs of strain today. Rest it for the rest of the day, sip water, and keep the next session short and gentle.")
        }

        if let pitch = stats.averagePitch, pitch < context.target.lowerBound * pow(2, -1.0 / 12) {
            tips.append("You averaged \(Int(pitch.rounded())) Hz, a little under your target (\(context.target.formatted)). Before each sentence, hum your target note for a second and start speaking from it.")
        }

        if let weakest = context.weakestMetric, tips.count < 3 {
            let tip = Self.metricTip(weakest)
            if !tips.contains(tip) {
                tips.append(tip)
            }
        }

        if let trend = Self.trendTip(context), tips.count < 3 {
            tips.append(trend)
        }

        if stats.slipAlerts >= 5, tips.count < 3 {
            tips.append("You had \(stats.slipAlerts) slip alerts. Shorter phrases with a quick breath in between make it easier to stay in your target voice.")
        }

        for general in Self.generalTips where tips.count < 2 {
            if !tips.contains(general) {
                tips.append(general)
            }
        }

        let exercise = Self.exercise(for: context.weakestMetric, in: context.exercises)
        return CoachFeedback(
            summary: Self.summary(stats),
            tips: Array(tips.prefix(3)),
            exerciseID: exercise?.id,
            exerciseTitle: exercise?.title,
            engine: CoachEngine.rules.rawValue
        )
    }

    static func summary(_ stats: CoachSessionStats) -> String {
        let minutes = max(1, Int(stats.minutes.rounded()))
        if let inTarget = stats.percentInTarget {
            let word = inTarget >= 70 ? "Great session" : (inTarget >= 40 ? "Good session" : "Solid practice")
            return "\(word): \(Int(inTarget.rounded()))% of the time in your target over \(minutes) min."
        }
        return "You practiced for \(minutes) min. Every session counts."
    }

    static func metricTip(_ metric: ProgressMetric) -> String {
        switch metric {
        case .inTarget:
            "Pitch was your lowest measure. Glide up into your target on “mm-hmm” before speaking, and check the graph at the start of each sentence."
        case .resonance:
            "Resonance was your lowest measure. Keep a slight smile and the tongue high and forward, as in a bright “ee”, while you talk."
        case .weight:
            "Vocal weight was your lowest measure. Start phrases softly, with a little more air, as if you were talking to someone sitting close to you."
        case .intonation:
            "Intonation was your lowest measure. Let your melody move: lift on questions and on the words that matter most."
        }
    }

    /// Praise for the biggest gain on recent sessions, or reassurance for a dip.
    static func trendTip(_ context: CoachSessionContext) -> String? {
        var best: (ProgressMetric, Double)?
        var worst: (ProgressMetric, Double)?
        for metric in ProgressMetric.allCases {
            guard let now = context.session.value(metric), let before = context.recentAverage(metric) else { continue }
            let change = now - before
            if change >= 5, change > (best?.1 ?? 0) { best = (metric, change) }
            if change <= -8, change < (worst?.1 ?? 0) { worst = (metric, change) }
        }
        if let best {
            return "\(best.0.title) is up \(Int(best.1.rounded())) points on your last \(context.recent.count) sessions. Keep doing what you did today."
        }
        if let worst {
            return "\(worst.0.title) was lower than usual today. Tired days happen; a short, easy session tomorrow is better than pushing now."
        }
        return nil
    }

    static let generalTips = [
        "Short, frequent practice works best: two or three 10-minute sessions beat one long one.",
        "Warm up with a few lip trills or gentle hums before you practice, and sip water during it.",
        "Record a clip now and then. Hearing yourself later shows progress the meters can’t.",
    ]

    static func exercise(for metric: ProgressMetric?, in options: [CoachExerciseOption]) -> CoachExerciseOption? {
        let skill: String
        switch metric {
        case .inTarget: skill = ExerciseSkill.pitch.rawValue
        case .resonance: skill = ExerciseSkill.resonance.rawValue
        case .weight: skill = ExerciseSkill.weight.rawValue
        case .intonation: skill = ExerciseSkill.intonation.rawValue
        case nil: skill = ExerciseSkill.warmUp.rawValue
        }
        return options.first { $0.skill == skill } ?? options.first
    }

    // MARK: Weekly review

    func weeklyReview(_ context: WeeklyReviewContext) async throws -> WeeklyReview {
        review(context)
    }

    func review(_ context: WeeklyReviewContext) -> WeeklyReview {
        let engine = CoachEngine.rules.rawValue
        if context.soreCheckIns >= 2 {
            return WeeklyReview(
                recommendation: .rest,
                focus: nil,
                message: "You reported a sore throat \(context.soreCheckIns) times this week. Take a day or two off, drink water, and come back with short, gentle sessions. If it doesn’t settle, see a speech-language pathologist.",
                engine: engine
            )
        }
        if context.goalMet && context.sessionsThisWeek >= context.requiredSessions {
            let next = context.isLastWeek ? "maintenance mode" : "week \(context.week + 1)"
            return WeeklyReview(
                recommendation: .moveOn,
                focus: nil,
                message: "You finished week \(context.week) and reached its goal. You’re ready for \(next). Keep the warm-ups going.",
                engine: engine
            )
        }
        let goalMinutes = Double(context.dailyGoalMinutes * 7)
        if context.practiceMinutes < goalMinutes * 0.4 {
            return WeeklyReview(
                recommendation: .repeatWeek,
                focus: nil,
                message: "You practiced \(Int(context.practiceMinutes.rounded())) minutes this week. Stay with week \(context.week) and aim for a few short sessions; consistency matters more than length.",
                engine: engine
            )
        }
        if let weakest = context.weakestMetric, let value = context.averages[weakest], value < 45 {
            return WeeklyReview(
                recommendation: .extraPractice,
                focus: weakest.rawValue,
                message: "\(weakest.title) is your weakest area right now (\(Int(value.rounded()))). Add one extra exercise for it each day while you finish week \(context.week).",
                engine: engine
            )
        }
        let remaining = max(0, context.requiredSessions - context.sessionsThisWeek)
        let detail = context.goalMet
            ? "\(remaining) more session\(remaining == 1 ? "" : "s") and you can move on."
            : "Keep working toward the goal: \(context.goalDescription)"
        return WeeklyReview(
            recommendation: .repeatWeek,
            focus: context.weakestMetric?.rawValue,
            message: "You’re making steady progress on week \(context.week). \(detail)",
            engine: engine
        )
    }

    // MARK: Practice texts

    func practiceText(_ request: PracticeTextRequest) async throws -> PracticeText {
        text(request)
    }

    func text(_ request: PracticeTextRequest) -> PracticeText {
        let bank = Self.sentences[request.focus] ?? []
        guard !bank.isEmpty else {
            return PracticeText(title: request.focus.title, text: ReadingPassages.quickCheck, engine: CoachEngine.rules.rawValue)
        }
        let count = min(request.length.sentenceCount, bank.count)
        // Rotate through the bank so each request gives a different passage.
        let start = ((request.variation * count) % bank.count + bank.count) % bank.count
        let chosen = (0..<count).map { bank[(start + $0) % bank.count] }
        return PracticeText(title: request.focus.title, text: chosen.joined(separator: " "), engine: CoachEngine.rules.rawValue)
    }

    static let sentences: [PracticeFocus: [String]] = [
        .brightVowels: [
            "We sat by the sea and ate peaches in the evening breeze.",
            "Please keep the green key safe until Friday.",
            "Jay made a cake today and gave me a piece on a plate.",
            "The bees weave between the trees in the meadow.",
            "Stay a little longer and play one more game with me.",
            "Each week I feel freer and see real changes.",
            "May I take the train to the bay later today?",
            "She needs three sheets of paper and a pencil, please.",
        ],
        .sibilants: [
            "Sam sells sea shells at the seaside on sunny Saturdays.",
            "She sees six small swans swimming past the shore.",
            "This special sauce is sweet, sour and slightly spicy.",
            "Should we share the shortbread or save it for Sunday?",
            "The sunshine sparkles on the silver surface of the stream.",
            "Sasha sent a short, sincere message to her sister.",
            "Several sailors sang softly as the ship set sail.",
            "Sip slowly; the soup is still steaming.",
        ],
        .questions: [
            "Are you coming to the picnic on Saturday?",
            "I think it starts at noon. Should I bring some lemonade?",
            "Have you ever tried the new bakery on Elm Street?",
            "Really? I had no idea they made croissants too!",
            "Which one would you choose, the blue scarf or the yellow one?",
            "Could you tell me where the library is, please?",
            "That sounds lovely. What time should we meet?",
            "Is it far from here, or can we walk?",
        ],
        .longSentences: [
            "When the rain finally stopped, we wandered down the lane, past the bakery and the little bookshop, all the way to the river where the ducks were waiting.",
            "My plan for the weekend is simple: sleep in a little, call my grandmother, cook something new, and spend the evening reading by the window.",
            "If you follow the path through the park and keep the pond on your left, you’ll reach the café with the green door in about ten minutes.",
            "Every morning I water the plants, open the curtains, make a cup of tea and take a moment to breathe before the day begins.",
            "The concert was wonderful, and even though it ran late and the bus was crowded, I hummed the melody the whole way home.",
            "Learning something new takes patience, practice and kindness to yourself, especially on the days when it feels harder than usual.",
        ],
        .namesAndNumbers: [
            "My name is Morgan Lee, and my number is 555 0142.",
            "The appointment is on Tuesday the 14th at half past three.",
            "Please send it to 27 Willow Lane, apartment 4B.",
            "Order number 8 3 6 2 should arrive by the 21st.",
            "Ask for Priya or Daniel at the front desk on the second floor.",
            "The train leaves platform 9 at 6:45 and arrives at 8:10.",
            "It costs twelve dollars and fifty cents, plus tax.",
            "My birthday is the 3rd of March, and I’ll be thirty-two.",
        ],
        .everyday: [
            "Hi! Thanks so much for waiting, I’m just running a minute late.",
            "Could I get a small coffee with oat milk, please?",
            "Oh, that’s so kind of you. I really appreciate it.",
            "I’m doing well, thanks. How was your weekend?",
            "Sorry, could you say that again? It’s a bit loud in here.",
            "Let’s catch up properly next week. I’ll send you a message.",
            "No worries at all, it happens to everyone.",
            "Have a lovely evening, and see you tomorrow!",
        ],
    ]

    // MARK: Scenario partner

    func partnerLine(_ request: PartnerRequest) async throws -> PartnerLine {
        PartnerLine(line: request.scriptedLine ?? "Go ahead, I’m listening.", hint: request.scriptedPrompt)
    }

    // MARK: Ask the Coach

    func chatReply(_ messages: [CoachChatMessage]) async throws -> String {
        reply(to: messages.last { $0.role == .user }?.text ?? "")
    }

    func reply(to question: String) -> String {
        let lowered = question.lowercased()
        if CoachSafety.needsMedicalAdvice(question) {
            return CoachSafety.medicalAdvice
        }
        for (keywords, answer) in Self.answers where keywords.contains(where: { lowered.contains($0) }) {
            return answer
        }
        return "I can help with pitch, resonance, vocal weight, intonation, warm-ups, practice routines and vocal health. Try asking something like “How do I make my voice brighter?” or “How long should I practice each day?”"
    }

    static let answers: [([String], String)] = [
        (["warm", "warm-up", "warmup"], "Start with a minute of easy breathing, then lip trills or gentle humming sliding up and down, and a few yawn-sighs. Two or three minutes is enough. Warm-ups should feel easy, never effortful."),
        (["resonance", "bright", "dark", "muffled"], "For brighter resonance, think of a small, forward space: a slight smile, the tongue high and forward like in “ee”, and the sound buzzing behind your front teeth. Practice on “ee” words first, then short phrases."),
        (["pitch", "higher", "hz", "low"], "Raise pitch gradually and comfortably. Hum your target note, then speak a short phrase starting from it. Pitch alone isn’t enough; bright resonance and a light voice matter just as much. Never force or squeeze."),
        (["weight", "heavy", "thick", "breathy", "light"], "To lighten vocal weight, start phrases softly with a little more air, like a gentle sigh, and avoid pressing. Speaking as if to someone close to you helps. If it gets very breathy, add a little more clarity."),
        (["intonation", "melody", "monotone", "flat"], "Let your melody move: lift on questions and on the important words, and glide rather than jump. Reading a short story aloud with feeling is great practice."),
        (["how long", "how often", "minutes", "every day", "daily"], "Short and often works best: 10–20 minutes a day, ideally split into a few sessions. Take a rest day each week, and stop if your voice feels tired."),
        (["water", "hydrat", "drink"], "Sip water through the day, more when you practice. Steam or a humid room helps a dry throat. Caffeine and alcohol can dry the voice, so balance them with water."),
        (["falsetto", "squeak", "head voice"], "Falsetto can feel like a shortcut, but it often sounds strained and tires the voice. Aim for a light, comfortable speaking voice in your target range instead, built up slowly."),
        (["tired", "fatigue", "strain"], "If your voice feels tired, stop for the day and rest it. Fatigue means it’s time for a break, not more effort. Come back tomorrow with a short, gentle session."),
        (["phone", "call"], "On calls, smile while you talk and keep the resonance bright and forward: phones cut low frequencies, so a bright voice carries better."),
        (["laugh", "cough", "sneeze", "surprise"], "Reflex sounds like laughing and coughing are the last to change. Practice them gently: light, airy laughs on “ha” and “hee” in your target voice."),
        (["progress", "plateau", "stuck", "not improving"], "Plateaus are normal. Record a clip and compare it with your Day 1 recording; the change is often bigger than it feels. Switch to a different skill for a week, then come back."),
    ]
}
