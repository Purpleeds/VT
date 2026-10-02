import Foundation
import Observation
import SwiftData

/// The session a check-in sheet is about.
nonisolated struct CheckInRequest: Identifiable, Sendable, Equatable {
    /// The session's id.
    let id: UUID
}

/// A short message shown at the bottom of the Practice screen.
nonisolated struct SessionToast: Identifiable, Sendable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// Saves practice sessions and recordings, and runs the post-session check-in.
///
/// - Every session is saved automatically while practicing (every 20 s when
///   statistics changed, and when the app goes to the background), so nothing
///   is lost if the app is closed.
/// - "Finish" saves the session, starts a fresh one and shows the check-in.
/// - "Save this as a recording" keeps the last 30 s of audio with its stats
///   and transcript.
@MainActor
@Observable
final class PracticeSessionController {
    /// Set to show the check-in sheet.
    var checkInRequest: CheckInRequest?
    /// An earlier session that ended without a check-in (e.g. the app was closed).
    private(set) var checkInReminder: CheckInRequest?
    private(set) var toast: SessionToast?
    private(set) var isSavingClip = false
    /// True on the day after check-ins suggested resting the voice.
    private(set) var isRestDaySuggested = false
    /// Shown when saved data couldn't be opened and nothing will be kept.
    let storageWarning: String?
    /// What the current session is (free practice, or a lesson's guided session).
    private(set) var sessionKind: PracticeSessionKind = .freePractice
    private(set) var sessionLessonID: String?

    let monitor: LiveVoiceMonitor
    let player: RecordingPlayer
    private let context: ModelContext

    @ObservationIgnored private var lastSaved: SessionSnapshot?
    @ObservationIgnored private var hasReportedSaveError = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private static let autosaveInterval = Duration.seconds(20)

    init(
        monitor: LiveVoiceMonitor,
        player: RecordingPlayer,
        container: ModelContainer,
        storageWarning: String? = nil
    ) {
        self.monitor = monitor
        self.player = player
        self.storageWarning = storageWarning
        context = container.mainContext

        // Playback must stop before the microphone listens again.
        monitor.willStartListening = { [weak player] in
            player?.stop()
        }

        let store = SessionStore(context: context)
        try? store.finishAbandonedSessions(except: monitor.sessionID)
        let profile = ProfileStore(context: context).profile()
        try? context.save()
        monitor.targetZone = profile.targetZone
        checkInReminder = store.sessionAwaitingCheckIn().map { CheckInRequest(id: $0.id) }
        refreshRestDay()

        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PracticeSessionController.autosaveInterval)
                guard let self else { return }
                self.saveProgress()
            }
        }
    }

    private var store: SessionStore { SessionStore(context: context) }

    /// True once the current session has heard some practice audio.
    var hasSessionInProgress: Bool { monitor.sessionStartDate != nil }

    // MARK: Session lifecycle

    /// Saves the current session's statistics if they changed.
    func saveProgress() {
        guard let snapshot = monitor.sessionSnapshot(), snapshot != lastSaved else { return }
        do {
            if try store.save(snapshot, finished: false, kind: sessionKind, lessonID: sessionLessonID) != nil {
                lastSaved = snapshot
            }
        } catch {
            reportSaveError()
        }
    }

    /// Saves when the app leaves the screen (it may be closed while away).
    func enterBackground() async {
        saveProgress()
        await monitor.pause(.background)
        saveProgress()
    }

    /// Ends the session: saves it, starts a fresh one and asks for a check-in.
    /// - Returns: The saved session, if it was long enough to keep.
    @discardableResult
    func finishSession(askForCheckIn: Bool = true) async -> PracticeSession? {
        await monitor.pause(.user)
        var finished: PracticeSession?
        if let snapshot = monitor.sessionSnapshot() {
            do {
                finished = try store.save(snapshot, finished: true, kind: sessionKind, lessonID: sessionLessonID)
            } catch {
                // Keep the session on screen so the user can try again.
                showToast("Your session couldn’t be saved. Please try again.", isError: true)
                return nil
            }
        }
        monitor.resetSession()
        lastSaved = nil
        if let finished {
            if askForCheckIn {
                checkInReminder = nil
                checkInRequest = CheckInRequest(id: finished.id)
            }
        } else if askForCheckIn {
            showToast("Session cleared. Sessions are saved once you’ve spoken for a few seconds.")
        }
        return finished
    }

    // MARK: Guided sessions

    /// Starts a lesson (or other guided) session: any free practice in
    /// progress is saved first, then listening starts on a fresh session.
    func beginGuidedSession(kind: PracticeSessionKind, lessonID: String?) async {
        if hasSessionInProgress {
            await finishSession(askForCheckIn: false)
        } else {
            monitor.resetSession()
        }
        sessionKind = kind
        sessionLessonID = lessonID
        await monitor.start()
    }

    /// Ends a guided session: saves it and asks for the check-in.
    @discardableResult
    func endGuidedSession() async -> PracticeSession? {
        let finished = await finishSession(askForCheckIn: true)
        sessionKind = .freePractice
        sessionLessonID = nil
        return finished
    }

    /// Minutes practiced today, including the session in progress.
    func minutesPracticedToday(now: Date = Date()) -> Double {
        store.minutesPracticed(on: now) + (monitor.sessionSnapshot()?.activeDuration ?? 0) / 60
    }

    /// The SPEC's soft cap on daily practice.
    static let dailySoftCapMinutes = 45.0

    /// Throws the current session away, including any recordings saved in it.
    func discardSession() async {
        await monitor.pause(.user)
        if let stored = store.session(id: monitor.sessionID) {
            do {
                try store.delete(stored)
            } catch {
                showToast("The session couldn’t be deleted. Please try again.", isError: true)
                return
            }
        }
        monitor.resetSession()
        lastSaved = nil
    }

    // MARK: Recordings

    /// Saves the last 30 seconds of audio as a recording in this session.
    func saveRecentClip() async {
        guard !isSavingClip else { return }
        guard let clip = monitor.recentClip(), let snapshot = monitor.sessionSnapshot() else {
            showToast("There’s nothing to save yet. Say something, then tap Save.", isError: true)
            return
        }
        isSavingClip = true
        defer { isSavingClip = false }

        let id = UUID()
        let fileName = RecordingFileStore.makeFileName(id: id)
        let audio = clip.audio
        do {
            // Encoding takes a moment, so it happens off the main thread.
            try await Task.detached(priority: .userInitiated) {
                try RecordingFileStore.write(audio, fileName: fileName)
            }.value
            let session = store.ensureSession(for: snapshot, kind: sessionKind, lessonID: sessionLessonID)
            try store.addRecording(id: id, fileName: fileName, clip: clip, to: session)
            lastSaved = snapshot
            showToast("Saved the last \(Self.durationText(audio.duration)) as a recording.")
        } catch {
            RecordingFileStore.delete(fileName: fileName)
            let reason = (error as? RecordingFileError)?.errorDescription ?? "The recording couldn’t be saved."
            showToast(reason, isError: true)
        }
    }

    /// Plays a recording (or stops it if it's already playing).
    /// Listening pauses first so the microphone doesn't analyze the playback.
    func togglePlayback(of recording: Recording) async {
        if player.playingID == recording.id {
            player.stop()
            return
        }
        await monitor.pause(.user)
        guard let url = recording.fileURL,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            showToast("This recording’s audio file is missing.", isError: true)
            return
        }
        player.play(url: url, id: recording.id)
    }

    /// Plays recordings back to back ("Then vs Now"), after pausing listening.
    func playInSequence(_ recordings: [Recording]) async {
        await monitor.pause(.user)
        var items: [(url: URL, id: UUID)] = []
        for recording in recordings {
            guard let url = recording.fileURL,
                  FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            else {
                showToast("A recording’s audio file is missing.", isError: true)
                return
            }
            items.append((url: url, id: recording.id))
        }
        player.playSequence(items)
    }

    func delete(_ recording: Recording) {
        if player.playingID == recording.id {
            player.stop()
        }
        do {
            try store.delete(recording)
        } catch {
            showToast("The recording couldn’t be deleted. Please try again.", isError: true)
        }
    }

    /// The session being practiced can't be deleted from History.
    func canDelete(_ session: PracticeSession) -> Bool {
        session.id != monitor.sessionID
    }

    func delete(_ session: PracticeSession) {
        guard canDelete(session) else { return }
        if let playing = player.playingID, (session.recordings ?? []).contains(where: { $0.id == playing }) {
            player.stop()
        }
        do {
            try store.delete(session)
        } catch {
            showToast("The session couldn’t be deleted. Please try again.", isError: true)
        }
    }

    // MARK: Check-in

    func session(id: UUID) -> PracticeSession? {
        store.session(id: id)
    }

    /// Saves the check-in answers.
    /// - Returns: Advice to show (rest day, see a professional), or nil if saving failed.
    func saveCheckIn(for session: PracticeSession, comfort: ComfortRating, naturalness: Int?) -> CheckInAdvice? {
        do {
            let advice = try store.recordCheckIn(for: session, comfort: comfort, naturalness: naturalness)
            if checkInReminder?.id == session.id {
                checkInReminder = nil
            }
            refreshRestDay()
            return advice
        } catch {
            showToast("Your check-in couldn’t be saved. Please try again.", isError: true)
            return nil
        }
    }

    func showCheckIn(for request: CheckInRequest) {
        checkInRequest = request
    }

    func dismissCheckInReminder() {
        checkInReminder = nil
    }

    /// Re-checks the rest-day suggestion (the date may have changed).
    func refreshRestDay(now: Date = Date()) {
        let suggestedOn = ProfileStore(context: context).profile().restSuggestedDate
        let suggested = CheckInRules.isRestDaySuggested(suggestedOn: suggestedOn, now: now)
        if isRestDaySuggested != suggested {
            isRestDaySuggested = suggested
        }
    }

    // MARK: Messages

    func showToast(_ message: String, isError: Bool = false) {
        toast = SessionToast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func reportSaveError() {
        guard !hasReportedSaveError else { return }
        hasReportedSaveError = true
        showToast("Your session couldn’t be saved. Practice still works; we’ll keep trying.", isError: true)
    }

    /// e.g. "30 seconds", "8 seconds".
    static func durationText(_ seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded()))
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}
