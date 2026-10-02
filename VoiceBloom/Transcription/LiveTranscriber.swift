import AVFoundation
import Foundation
import Speech

/// Speech recognition permission and availability.
nonisolated enum SpeechAuthorization {
    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Asking for permission without this Info.plist entry would crash the
    /// app, so it's checked first (see README: Xcode setup).
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// Asks for speech recognition permission if needed (system prompt once).
    @concurrent
    static func request() async -> Bool {
        guard hasUsageDescription else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    /// Why on-device transcription can't run right now, or nil if it can.
    /// Recognition never uses Apple's servers: audio stays on the iPhone.
    static func unavailableReason() -> String? {
        guard let recognizer = SFSpeechRecognizer() else {
            return "Transcription isn’t available for your device language."
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return "On-device transcription isn’t available for \(languageName(recognizer.locale)) yet. Turn on Dictation for this language in Settings › General › Keyboard, then try again."
        }
        guard recognizer.isAvailable else {
            return "Transcription is temporarily unavailable. Try again in a moment."
        }
        return nil
    }

    private static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Live, on-device speech-to-text fed with the app's own microphone samples
/// (it never opens the microphone itself).
///
/// Uses `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, so audio never
/// leaves the device. Each request covers up to ~55 s of audio; a new request
/// starts automatically when one ends, so transcripts can run for a whole session.
///
/// Thread-safety: `append` is called from the analysis task and the
/// recognizer calls back on its own queue. All mutable state is guarded by
/// `lock`, and recognizer calls are made outside the lock.
nonisolated final class LiveTranscriber: @unchecked Sendable {
    /// Requests are rotated after this much audio.
    static let maximumRequestDuration = 55.0

    /// Tags this transcriber's results (see `TranscriptChunk.transcriberID`).
    let id: Int
    private let recognizer: SFSpeechRecognizer
    private let format: AVAudioFormat
    private let lock = NSLock()

    private var isActive = false
    /// Number of the current request (requests count up from 1).
    private var generation = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Audio time of each request's first sample, by generation.
    private var requestStartTimes: [Int: Double] = [:]
    private var failureTimes: [Date] = []
    private var onEvent: (@Sendable (TranscriberEvent) -> Void)?

    /// Returns nil when on-device recognition isn't available.
    /// - Parameters:
    ///   - sampleRate: Rate of the samples passed to `append`.
    ///   - id: Tag for this transcriber's results.
    init?(sampleRate: Double, id: Int) {
        guard let recognizer = SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }
        self.id = id
        self.recognizer = recognizer
        self.format = format
    }

    func start(onEvent: @escaping @Sendable (TranscriberEvent) -> Void) {
        lock.withLock {
            isActive = true
            self.onEvent = onEvent
        }
        beginRequest()
    }

    /// Ends recognition; the last result still arrives as final.
    func stop() {
        let (currentRequest, currentTask) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            isActive = false
            let pair = (request, task)
            request = nil
            task = nil
            return pair
        }
        currentRequest?.endAudio()
        currentTask?.finish()
    }

    /// - Parameter startTime: Audio time of the first sample.
    func append(_ samples: UnsafeBufferPointer<Float>, startTime: Double) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }

        let needsRotation = lock.withLock { () -> Bool in
            guard isActive, let request else { return false }
            let requestStart = requestStartTimes[generation] ?? startTime
            requestStartTimes[generation] = requestStart
            request.append(buffer)
            return startTime - requestStart >= Self.maximumRequestDuration
        }
        if needsRotation {
            rotateRequest()
        }
    }

    // MARK: Requests

    private func beginRequest() {
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation

        let requestID = lock.withLock { () -> Int? in
            guard isActive else { return nil }
            generation += 1
            request = newRequest
            return generation
        }
        guard let requestID else { return }

        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handle(result: result, error: error, requestID: requestID)
        }
        let isStale = lock.withLock { () -> Bool in
            guard generation == requestID, isActive else { return true }
            task = newTask
            return false
        }
        if isStale {
            newTask.cancel()
        }
    }

    /// Finishes the current request (its final text still arrives) and
    /// continues with a fresh one, keeping each request short.
    private func rotateRequest() {
        let (oldRequest, oldTask) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            let pair = (request, task)
            request = nil
            task = nil
            return pair
        }
        oldRequest?.endAudio()
        oldTask?.finish()
        beginRequest()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: (any Error)?, requestID: Int) {
        let (callback, startTime, isCurrent, active) = lock.withLock {
            (onEvent, requestStartTimes[requestID] ?? 0, generation == requestID, isActive)
        }

        if let result {
            let transcription = result.bestTranscription
            let words = transcription.segments.map { segment in
                TimedWord(text: segment.substring, start: startTime + segment.timestamp, duration: segment.duration)
            }
            callback?(.result(TranscriptChunk(
                transcriberID: id,
                requestID: requestID,
                text: transcription.formattedString,
                words: words,
                isFinal: result.isFinal
            )))
        }

        // When the current request ends on its own (silence timeout, error),
        // keep going with a new one while transcription is on.
        let ended = error != nil || (result?.isFinal ?? false)
        guard ended, isCurrent, active else { return }
        if let error, recordFailure(error) {
            callback?(.failed(transcriberID: id, message: "Transcription stopped: \(error.localizedDescription)"))
            stop()
            return
        }
        beginRequest()
    }

    /// Notes a real error. "No speech detected" (code 1110) is expected
    /// during quiet stretches and doesn't count.
    /// - Returns: True when errors repeat so fast that it's time to give up.
    private func recordFailure(_ error: any Error) -> Bool {
        if (error as NSError).code == 1110 {
            return false
        }
        let now = Date()
        return lock.withLock {
            failureTimes = failureTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
            return failureTimes.count >= 3
        }
    }
}
