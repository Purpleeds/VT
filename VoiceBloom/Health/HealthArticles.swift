import Foundation

/// A short article in the Vocal Health Center (SPEC section 14).
nonisolated struct HealthArticle: Identifiable, Sendable, Equatable {
    nonisolated struct Part: Sendable, Equatable {
        let heading: String
        let paragraphs: [String]
        var bullets: [String] = []
    }

    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let parts: [Part]

    /// About 200 words a minute.
    var readingMinutes: Int {
        let words = parts.reduce(summary.split(separator: " ").count) { total, part in
            total + (part.paragraphs + part.bullets).reduce(0) { $0 + $1.split(separator: " ").count }
        }
        return max(1, Int((Double(words) / 200).rounded()))
    }
}

/// General education, not medical advice. Written to be calm and practical.
nonisolated enum HealthLibrary {
    static let disclaimer = "These articles are general information, not medical advice. If something hurts or doesn’t feel right, stop and talk to a doctor or a speech-language pathologist."

    static let articles: [HealthArticle] = [
        HealthArticle(
            id: "how-the-voice-works",
            title: "How your voice works",
            summary: "Breath, vibration and the shape of your throat and mouth work together. Knowing the parts makes training make sense.",
            systemImage: "waveform.path",
            parts: [
                .init(heading: "Three parts", paragraphs: [
                    "Your voice has a power source, a sound source and a filter. Air from your lungs is the power. Your vocal folds, two small bands of tissue in your larynx (voice box), are the sound source: air makes them vibrate many times a second. The spaces above them, your throat, mouth and nose, are the filter that shapes that buzz into the voice people hear.",
                ]),
                .init(heading: "Pitch", paragraphs: [
                    "Pitch is how fast your vocal folds vibrate. Faster vibration sounds higher. Small muscles in the larynx stretch and thin the folds to raise pitch. Pitch is only one part of how a voice is perceived, and pushing it higher on its own often sounds strained.",
                ]),
                .init(heading: "Resonance", paragraphs: [
                    "Resonance is how the filter shapes the sound. A smaller, brighter space (a slightly higher larynx, the tongue forward) makes some frequencies stronger, which listeners hear as brighter or more forward. Chirp measures this through formants, the peaks the filter creates.",
                ]),
                .init(heading: "Weight", paragraphs: [
                    "Vocal weight is how thick and pressed the vibrating folds are. Heavier phonation sounds buzzy and full; lighter phonation sounds softer and smoother. Weight is changed by how the folds close, not by squeezing the throat.",
                ]),
                .init(heading: "Why it takes practice", paragraphs: [
                    "These are small muscles doing fine work, and new habits take weeks to become automatic. Short, frequent, relaxed practice builds them safely, much like learning an instrument.",
                ]),
            ]
        ),
        HealthArticle(
            id: "safe-habits",
            title: "Safe training habits",
            summary: "Short sessions, warm-ups, and stopping at the first sign of discomfort keep training sustainable.",
            systemImage: "checkmark.shield",
            parts: [
                .init(heading: "Little and often", paragraphs: [
                    "Several short sessions spread through the day work better than one long one. Chirp suggests no more than about 45 minutes of focused practice a day, with a short break every 15 minutes.",
                ]),
                .init(heading: "Every session", paragraphs: [], bullets: [
                    "Start with a gentle warm-up: lip trills, humming, easy sighs.",
                    "Keep your jaw, tongue, neck and shoulders relaxed. Check for tension often.",
                    "Use comfortable volume. Training never needs shouting.",
                    "End with a cool-down: gentle humming slides back to your comfortable voice.",
                    "Do the check-in afterwards so the app can spot trouble early.",
                ]),
                .init(heading: "Stop if", paragraphs: [], bullets: [
                    "It hurts, burns or feels tight.",
                    "Your voice gets hoarse, breathy or cracks more than usual.",
                    "You need to clear your throat or cough a lot.",
                ]),
                .init(heading: "Progress safely", paragraphs: [
                    "Ease is the goal. A voice that sounds right but feels effortful isn’t ready to use all day yet. Go back a step, make it easy, and build up again.",
                ]),
            ]
        ),
        HealthArticle(
            id: "hydration",
            title: "Hydration",
            summary: "Vocal folds vibrate best when they’re well hydrated, from the inside and from the air you breathe.",
            systemImage: "drop.fill",
            parts: [
                .init(heading: "Why it matters", paragraphs: [
                    "The vocal folds are covered with a thin layer of mucus that helps them vibrate smoothly. When you’re dehydrated it gets thicker and stickier, so the folds need more effort and tire sooner.",
                ]),
                .init(heading: "Simple habits", paragraphs: [], bullets: [
                    "Sip water through the day and during practice. Pale yellow urine is a good sign you’re drinking enough.",
                    "Breathing steam (a shower, or a bowl of warm water) moistens the folds directly.",
                    "Use a humidifier if the air is dry, for example with heating or air conditioning.",
                    "Caffeine and alcohol can dry you out; balance them with extra water.",
                    "Smoking and vaping irritate and dry the folds. Avoiding them helps your voice in every way.",
                ]),
                .init(heading: "Throat clearing", paragraphs: [
                    "Clearing your throat slams the folds together. Try a sip of water, a swallow, or a gentle hum instead.",
                ]),
            ]
        ),
        HealthArticle(
            id: "rest",
            title: "Rest and recovery",
            summary: "Muscles get stronger between sessions, not during them. Rest days are part of training.",
            systemImage: "bed.double.fill",
            parts: [
                .init(heading: "Daily rest", paragraphs: [
                    "Take short breaks of a few minutes every 15 minutes of practice. Stop for the day at around 45 minutes of focused work. Chirp shows a gentle reminder when you get close.",
                ]),
                .init(heading: "Rest days", paragraphs: [
                    "If your throat feels sore, or after a lot of voice use (a long day of talking, a party, singing), take a day off training. If you report a sore throat twice in three days, Chirp suggests a rest day; your streak has a weekly freeze so a rest day doesn’t break it.",
                ]),
                .init(heading: "What vocal rest means", paragraphs: [
                    "On a rest day, talk in your easy, comfortable voice and keep it short. Avoid shouting, talking over noise and long phone calls.",
                    "Whispering isn’t restful; it can strain the voice more than soft speech. Use a quiet, relaxed voice instead.",
                ]),
                .init(heading: "Sleep", paragraphs: [
                    "Tiredness shows in the voice. Good sleep makes control easier and practice more effective.",
                ]),
            ]
        ),
        HealthArticle(
            id: "signs-of-strain",
            title: "Signs of strain",
            summary: "Learn the early warnings so you can ease off before a small problem becomes a bigger one.",
            systemImage: "exclamationmark.triangle",
            parts: [
                .init(heading: "Early signs", paragraphs: [], bullets: [
                    "Throat tightness, aching or a feeling of effort while speaking.",
                    "A hoarse, rough or breathy sound, especially later in the day.",
                    "Voice breaks or losing the top of your range.",
                    "Needing to clear your throat often, or a lump-in-the-throat feeling.",
                    "Tension in the jaw, tongue, neck or shoulders.",
                ]),
                .init(heading: "What the app watches", paragraphs: [
                    "During practice Chirp compares the roughness of your voice (jitter, shimmer and noise) with your own usual values and warns you if it stays higher than normal. It also asks how your throat felt after each session. These are hints, not a diagnosis.",
                ]),
                .init(heading: "What to do", paragraphs: [
                    "Stop the exercise, sip water and rest your voice. Next time, go back to an easier step and lower the effort. If symptoms last more than two weeks, or you notice pain or sudden changes, see a professional.",
                ]),
            ]
        ),
        HealthArticle(
            id: "falsetto-forcing",
            title: "Why forcing pitch or falsetto is risky",
            summary: "Pitch pushed up by squeezing, or a thin falsetto used all day, tires the voice and rarely sounds natural.",
            systemImage: "arrow.up.to.line",
            parts: [
                .init(heading: "Forcing pitch", paragraphs: [
                    "It’s tempting to reach a target pitch by tightening the throat and pushing. That squeezes the muscles around the larynx and makes the folds work against tension. Over time it can cause fatigue, hoarseness and sometimes injury, and the result usually sounds strained.",
                    "A modest pitch change with good resonance and lighter weight often sounds more natural than a big pitch change on its own. That’s why Chirp works on all of them.",
                ]),
                .init(heading: "Falsetto", paragraphs: [
                    "Falsetto uses only the thin edges of the vocal folds, often with air leaking through. It’s fine as a short exercise, but speaking in it all day is breathy, tiring and hard to control. Training aims for a light but fully connected voice instead.",
                ]),
                .init(heading: "Better ways", paragraphs: [], bullets: [
                    "Raise pitch in small steps and only as far as it stays easy.",
                    "Work on resonance (brightness) and lighter weight together with pitch.",
                    "Keep the volume comfortable and the breath steady.",
                    "If it feels like effort, it’s too much for now.",
                ]),
            ]
        ),
        HealthArticle(
            id: "see-an-slp",
            title: "When to see a speech-language pathologist",
            summary: "An SLP (speech therapist) can check your voice and coach you in person. Here’s when it’s worth it.",
            systemImage: "stethoscope",
            parts: [
                .init(heading: "See a doctor or SLP if", paragraphs: [], bullets: [
                    "Hoarseness or voice changes last more than two weeks.",
                    "Speaking or swallowing hurts.",
                    "You lose your voice, or it suddenly changes, without a clear reason.",
                    "Your throat feels sore again and again after practice.",
                    "You cough up blood, or have a lump in your neck. See a doctor promptly.",
                ]),
                .init(heading: "What they can do", paragraphs: [
                    "A laryngologist (an ear, nose and throat doctor specializing in the voice) can look at your vocal folds. A speech-language pathologist can assess how you use your voice, find habits that cause strain, and give you exercises tailored to you. Many SLPs offer voice training for gender affirmation and understand your goals.",
                ]),
                .init(heading: "Using the app alongside", paragraphs: [
                    "Chirp is a practice tool, not a replacement for professional care. Your progress charts and recordings can be useful to show a clinician. They stay on your iPhone unless you choose to share them.",
                ]),
            ]
        ),
    ]

    static func article(id: String) -> HealthArticle? {
        articles.first { $0.id == id }
    }
}
