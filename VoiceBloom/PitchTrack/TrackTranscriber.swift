import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Words with timestamps for a Pitch Track (SPEC section 22.1: transcribe
/// with SpeechAnalyzer, word timestamps), always on device.
nonisolated enum TrackTranscriber {
    /// The words in an audio file, or an empty list when transcription isn't
    /// available (no permission, unsupported language, no model).
    static func words(in url: URL) async -> [TranscribedWord] {
        guard await SpeechAuthorization.request() else { return [] }
        if let words = try? await analyzerWords(in: url), !words.isEmpty {
            return words
        }
        // Older path: the on-device SFSpeechRecognizer.
        return (try? await recognizerWords(in: url)) ?? []
    }

    /// SpeechAnalyzer + SpeechTranscriber with audio time ranges.
    private static func analyzerWords(in url: URL) async throws -> [TranscribedWord] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return [] }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        // The language model is downloaded once by the system (on device).
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installation {
            try await installation.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task<[TranscribedWord], any Error> {
            var words: [TranscribedWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(from: result.text))
            }
            return words
        }
        do {
            let end = try await analyzer.analyzeSequence(from: file)
            if let end {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// One word per run that carries a time range.
    static func words(from text: AttributedString) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { continue }
            words.append(TranscribedWord(text: word, start: start, duration: max(0, duration), confidence: run.transcriptionConfidence))
        }
        return words
    }

    private static func recognizerWords(in url: URL) async throws -> [TranscribedWord] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            return []
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let state = RecognitionState()
        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if state.claim() {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.map { segment in
                    TranscribedWord(
                        text: segment.substring,
                        start: segment.timestamp,
                        duration: segment.duration,
                        confidence: Double(segment.confidence)
                    )
                }
                if state.claim() {
                    continuation.resume(returning: words)
                }
            }
            state.keep(task)
        }
    }
}

/// Resumes the continuation once and keeps the recognition task alive.
private nonisolated final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false
    private var task: SFSpeechRecognitionTask?

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        task = nil
        return true
    }

    func keep(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        defer { lock.unlock() }
        if !isClaimed {
            self.task = task
        }
    }
}
