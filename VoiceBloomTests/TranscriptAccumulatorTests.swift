import Foundation
import Testing
@testable import VoiceBloom

@Suite("TranscriptAccumulator")
struct TranscriptAccumulatorTests {
    private func chunk(
        transcriber: Int = 1,
        request: Int,
        _ text: String,
        final isFinal: Bool = false,
        wordsStartingAt start: Double = 0
    ) -> TranscriptChunk {
        // One word every 0.5 s from `start`.
        let words = text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: String(word), start: start + Double(index) * 0.5, duration: 0.4)
        }
        return TranscriptChunk(transcriberID: transcriber, requestID: request, text: text, words: words, isFinal: isFinal)
    }

    @Test("Partial results replace each other until the request is final")
    func partialsReplace() {
        var transcript = TranscriptAccumulator()
        transcript.apply(chunk(request: 1, "Hello"))
        transcript.apply(chunk(request: 1, "Hello there"))
        #expect(transcript.text == "Hello there")
        transcript.apply(chunk(request: 1, "Hello there.", final: true))
        #expect(transcript.text == "Hello there.")
    }

    @Test("A late partial result can't overwrite the final text")
    func lateResultsIgnored() {
        var transcript = TranscriptAccumulator()
        transcript.apply(chunk(request: 1, "Good morning.", final: true))
        transcript.apply(chunk(request: 1, "Good mor"))
        #expect(transcript.text == "Good morning.")
    }

    @Test("Requests and transcribers are joined in order")
    func ordering() {
        var transcript = TranscriptAccumulator()
        transcript.apply(chunk(transcriber: 2, request: 1, "after the pause"))
        transcript.apply(chunk(transcriber: 1, request: 2, "second minute"))
        transcript.apply(chunk(transcriber: 1, request: 1, "first minute", final: true))
        #expect(transcript.text == "first minute second minute after the pause")
    }

    @Test("Empty results don't add extra spaces")
    func emptyChunks() {
        var transcript = TranscriptAccumulator()
        transcript.apply(chunk(request: 1, "One"))
        transcript.apply(chunk(request: 2, "  "))
        transcript.apply(chunk(request: 3, "two"))
        #expect(transcript.text == "One two")
        #expect(!transcript.isEmpty)
    }

    @Test("Words are picked by audio time for a saved clip")
    func wordsInRange() {
        var transcript = TranscriptAccumulator()
        // Words at 10.0, 10.5, 11.0, 11.5
        transcript.apply(chunk(request: 1, "the quick brown fox", wordsStartingAt: 10))
        // Words at 70.0, 70.5
        transcript.apply(chunk(request: 2, "jumps over", wordsStartingAt: 70))
        #expect(transcript.text(from: 10.5, through: 11.2) == "quick brown")
        // A word starting just before the clip (by < 0.1 s) is kept.
        #expect(transcript.text(from: 10.55, through: 10.6) == "quick")
        #expect(transcript.text(from: 11.2, through: 70.2) == "fox jumps")
        #expect(transcript.text(from: 20, through: 30) == nil)
    }

    @Test("Reset clears everything")
    func reset() {
        var transcript = TranscriptAccumulator()
        transcript.apply(chunk(request: 1, "Hello", final: true))
        transcript.reset()
        #expect(transcript.isEmpty)
        #expect(transcript.chunks.isEmpty)
    }
}
