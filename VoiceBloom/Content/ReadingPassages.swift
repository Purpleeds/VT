import Foundation

/// Original reading texts (written for VoiceBloom, not quoted from anywhere).
nonisolated enum ReadingPassages {
    /// The Day 1 baseline passage, re-read in week 16 for "Then vs Now".
    static let baseline = """
    The morning market was already busy when Maya arrived. She wandered past baskets of bright oranges, warm bread fresh from the oven, and a little stall hung with paper lanterns. A friendly vendor waved and offered her a slice of peach. She laughed, said yes, and decided this was going to be a very good day.
    """

    /// Reading part of the placement test.
    static let placement = """
    Every Sunday my neighbor waters her garden while humming the same cheerful tune. Her sunflowers have grown taller than the fence, and the bees seem to love them. Yesterday she handed me a bag of tomatoes and told me the secret is patience, a little sunshine, and talking kindly to your plants.
    """

    /// Prompts for the 30 seconds of free speech in the baseline.
    static let freeSpeechPrompts = [
        "Describe what you did this morning, step by step.",
        "Tell a friend about your favorite meal and how it’s made.",
        "What would a perfect day off look like for you?",
        "Talk about a place you’d love to visit, and why.",
    ]

    /// The 10-second Quick Check sentence.
    static let quickCheck = "Hi there! I’m just checking in on my voice today, and it feels light, bright and easy."

    /// The default Daily Sentence Journal sentence.
    static let journalSentence = "Today I’m speaking gently, and my voice is growing a little every day."
}
