import Foundation
import Observation

/// The live transcript shown under the pitch graph.
///
/// `LiveVoiceMonitor` starts and stops transcribers as listening starts and
/// stops; each one is fed the app's own microphone samples through
/// `AudioTap`, and recognition runs entirely on the device.
@MainActor
@Observable
final class TranscriptionService {
    /// The user's choice. Kept between launches.
    private(set) var isEnabled: Bool
    private(set) var status: TranscriptionStatus
    /// The session's transcript so far.
    private(set) var text = ""

    private let tap: AudioTap
    @ObservationIgnored private var accumulator = TranscriptAccumulator()
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var listeningSampleRate: Double?
    @ObservationIgnored private var nextTranscriberID = 1
    /// Results from older transcribers belong to a previous session.
    @ObservationIgnored private var oldestAcceptedTranscriberID = 1
    private let events: AsyncStream<TranscriberEvent>.Continuation
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private static let enabledKey = "liveTranscriptEnabled"
    static let permissionMessage = "Speech recognition is turned off for VoiceBloom. You can allow it in Settings › Privacy & Security › Speech Recognition."

    init(tap: AudioTap) {
        self.tap = tap
        let enabled = UserDefaults.standard.bool(forKey: TranscriptionService.enabledKey)
        isEnabled = enabled
        status = enabled ? .waitingForAudio : .off

        // Recognizer callbacks arrive on another queue; a stream keeps them in order.
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriberEvent.self)
        events = continuation
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    var isListening: Bool { transcriber != nil }

    /// Turns transcripts on, asking for speech recognition permission if needed.
    /// - Returns: True when transcription can run.
    func enable() async -> Bool {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        let isAllowed = await SpeechAuthorization.request()
        // The user may have turned it off again while the permission alert showed.
        guard isEnabled else { return false }
        guard SpeechAuthorization.hasUsageDescription else {
            status = .unavailable("Live transcripts aren’t set up in this build yet: the speech recognition usage description is missing from Info.plist.")
            return false
        }
        guard isAllowed else {
            status = .unavailable(Self.permissionMessage)
            return false
        }
        if let reason = SpeechAuthorization.unavailableReason() {
            status = .unavailable(reason)
            return false
        }
        if !isListening {
            status = .waitingForAudio
        }
        return true
    }

    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stopListening()
        status = .off
    }

    /// Starts a transcriber for a listening run (if transcripts are on).
    func startListening(sampleRate: Double) {
        guard isEnabled, transcriber == nil else { return }
        guard SpeechAuthorization.isAuthorized else {
            status = .unavailable(Self.permissionMessage)
            return
        }
        let id = nextTranscriberID
        nextTranscriberID += 1
        guard let newTranscriber = LiveTranscriber(sampleRate: sampleRate, id: id) else {
            status = .unavailable(SpeechAuthorization.unavailableReason() ?? "Transcription isn’t available right now.")
            return
        }
        let continuation = events
        newTranscriber.start { event in
            continuation.yield(event)
        }
        tap.setTranscriber(newTranscriber)
        transcriber = newTranscriber
        listeningSampleRate = sampleRate
        status = .listening
    }

    func stopListening() {
        tap.setTranscriber(nil)
        transcriber?.stop()
        transcriber = nil
        listeningSampleRate = nil
        if status == .listening {
            status = .waitingForAudio
        }
    }

    /// Clears the transcript for a new session.
    func reset() {
        accumulator.reset()
        text = ""
        oldestAcceptedTranscriberID = nextTranscriberID
        // A running request would carry the old session's words into the
        // new one, so start a fresh transcriber.
        if let sampleRate = listeningSampleRate {
            stopListening()
            startListening(sampleRate: sampleRate)
        }
    }

    /// Words spoken between two audio times, for saving with a clip.
    func text(from start: Double, through end: Double) -> String? {
        accumulator.text(from: start, through: end)
    }

    private func apply(_ event: TranscriberEvent) {
        switch event {
        case .result(let chunk):
            guard chunk.transcriberID >= oldestAcceptedTranscriberID else { return }
            accumulator.apply(chunk)
            let newText = accumulator.text
            if text != newText {
                text = newText
            }
        case .failed(let transcriberID, let message):
            guard transcriberID == transcriber?.id else { return }
            tap.setTranscriber(nil)
            transcriber = nil
            listeningSampleRate = nil
            status = .unavailable(message)
        }
    }
}
