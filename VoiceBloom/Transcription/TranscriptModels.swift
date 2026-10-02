import Foundation

/// One recognized word, placed on the session's audio timeline.
nonisolated struct TimedWord: Sendable, Equatable {
    let text: String
    /// Audio time (same clock as `VoiceFrame.time`) where the word starts.
    let start: Double
    let duration: Double
}

/// The latest result for one recognition request.
nonisolated struct TranscriptChunk: Sendable, Equatable {
    /// Which transcriber produced it. A new transcriber starts every time
    /// listening resumes, so later transcribers continue the text.
    let transcriberID: Int
    /// Requests are numbered in order within a transcriber.
    let requestID: Int
    /// Punctuated text of the whole request so far.
    let text: String
    let words: [TimedWord]
    /// True when the recognizer won't change this request's text any more.
    let isFinal: Bool
}

nonisolated enum TranscriberEvent: Sendable, Equatable {
    case result(TranscriptChunk)
    /// The transcriber stopped and can't continue (message is user-facing).
    case failed(transcriberID: Int, message: String)
}

nonisolated enum TranscriptionStatus: Sendable, Equatable {
    case off
    case waitingForAudio
    case listening
    case unavailable(String)
}

/// Assembles the running transcript from per-request results.
///
/// Each recognition request covers up to about a minute of audio. Partial
/// results replace earlier ones for the same request until it becomes final;
/// late partial results for a finished request are ignored. Chunks are put in
/// order by transcriber, then request.
nonisolated struct TranscriptAccumulator: Sendable, Equatable {
    nonisolated struct Key: Hashable, Comparable, Sendable {
        let transcriberID: Int
        let requestID: Int

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.transcriberID != rhs.transcriberID {
                return lhs.transcriberID < rhs.transcriberID
            }
            return lhs.requestID < rhs.requestID
        }
    }

    private(set) var chunks: [Key: TranscriptChunk] = [:]

    mutating func apply(_ chunk: TranscriptChunk) {
        let key = Key(transcriberID: chunk.transcriberID, requestID: chunk.requestID)
        if let existing = chunks[key], existing.isFinal {
            return
        }
        chunks[key] = chunk
    }

    private var orderedChunks: [TranscriptChunk] {
        chunks.keys.sorted().compactMap { chunks[$0] }
    }

    /// The whole transcript so far, oldest first.
    var text: String {
        orderedChunks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Words spoken between two audio times (for saving with a clip).
    func text(from start: Double, through end: Double) -> String? {
        let words = orderedChunks
            .flatMap(\.words)
            .filter { $0.start >= start - 0.1 && $0.start <= end }
            .map(\.text)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    var isEmpty: Bool { text.isEmpty }

    mutating func reset() {
        chunks.removeAll()
    }
}
