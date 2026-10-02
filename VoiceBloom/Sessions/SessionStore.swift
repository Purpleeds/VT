import Foundation
import SwiftData

/// Reads and writes practice sessions, recordings and check-ins.
@MainActor
struct SessionStore {
    /// Sessions with less voice than this aren't kept (unless a clip was saved).
    static let minimumVoicedDuration = 3.0

    let context: ModelContext

    // MARK: Sessions

    func session(id sessionID: UUID) -> PracticeSession? {
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.id == sessionID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Saves the latest statistics of a session.
    ///
    /// A new session is only stored once it has at least 3 seconds of voice,
    /// so opening the app by accident doesn't fill the history.
    /// - Returns: The stored session, or nil if it is too short to keep.
    @discardableResult
    func save(_ snapshot: SessionSnapshot, finished: Bool, now: Date = Date()) throws -> PracticeSession? {
        let existing = session(id: snapshot.id)
        guard existing != nil || snapshot.voicedDuration >= Self.minimumVoicedDuration else {
            return nil
        }
        let stored = existing ?? insertSession(for: snapshot)
        stored.apply(snapshot)
        if finished {
            stored.endDate = now
        }
        try context.save()
        return stored
    }

    /// The stored session for a snapshot, created if needed (e.g. when a clip
    /// is saved before the session is long enough to be kept on its own).
    func ensureSession(for snapshot: SessionSnapshot) -> PracticeSession {
        let stored = session(id: snapshot.id) ?? insertSession(for: snapshot)
        stored.apply(snapshot)
        return stored
    }

    private func insertSession(for snapshot: SessionSnapshot) -> PracticeSession {
        let newSession = PracticeSession(id: snapshot.id, startDate: snapshot.startDate, kind: .freePractice)
        context.insert(newSession)
        return newSession
    }

    /// Marks sessions left in progress by an earlier launch as finished
    /// (e.g. the app was closed from the app switcher while paused).
    /// - Parameter currentSessionID: The session being practiced right now.
    func finishAbandonedSessions(except currentSessionID: UUID?) throws {
        let descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.endDate == nil }
        )
        let unfinished = try context.fetch(descriptor).filter { $0.id != currentSessionID }
        guard !unfinished.isEmpty else { return }
        for abandoned in unfinished {
            abandoned.endDate = abandoned.startDate.addingTimeInterval(abandoned.duration)
        }
        try context.save()
    }

    /// Deletes a session, its recordings and their audio files.
    func delete(_ session: PracticeSession) throws {
        let fileNames = (session.recordings ?? []).map(\.fileName)
        context.delete(session)
        try context.save()
        for fileName in fileNames {
            RecordingFileStore.delete(fileName: fileName)
        }
    }

    // MARK: Recordings

    /// Stores a recording whose audio file has already been written.
    @discardableResult
    func addRecording(
        id: UUID,
        fileName: String,
        clip: RecentClip,
        to session: PracticeSession,
        now: Date = Date()
    ) throws -> Recording {
        let recording = Recording(id: id, fileName: fileName, duration: clip.audio.duration, kind: .clip, createdAt: now)
        context.insert(recording)
        recording.apply(clip.stats)
        recording.transcript = clip.transcript
        recording.sessionID = session.id
        recording.session = session
        try context.save()
        return recording
    }

    func delete(_ recording: Recording) throws {
        let fileName = recording.fileName
        context.delete(recording)
        try context.save()
        RecordingFileStore.delete(fileName: fileName)
    }

    // MARK: Check-ins

    /// Saves the post-session check-in and works out whether to suggest rest.
    func recordCheckIn(
        for session: PracticeSession,
        comfort: ComfortRating,
        naturalness: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CheckInAdvice {
        session.comfort = comfort
        session.naturalnessRating = naturalness.map { min(max($0, 1), 5) }
        session.checkInDate = now
        try context.save()

        let reports = try comfortReports(since: now.addingTimeInterval(-8 * 24 * 3600))
        let advice = CheckInRules.advice(for: reports, now: now, calendar: calendar)
        if advice != .none {
            ProfileStore(context: context).profile().restSuggestedDate = now
            try context.save()
        }
        return advice
    }

    /// Check-in answers since a date, newest first.
    func comfortReports(since start: Date) throws -> [ComfortReport] {
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.checkInDate != nil && $0.startDate >= start },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return try context.fetch(descriptor).compactMap { stored in
            guard let comfort = stored.comfort, let date = stored.checkInDate else { return nil }
            return ComfortReport(date: date, comfort: comfort)
        }
    }

    /// The most recent session from the last 12 hours that is finished, long
    /// enough to count and still has no check-in.
    func sessionAwaitingCheckIn(now: Date = Date()) -> PracticeSession? {
        let start = now.addingTimeInterval(-12 * 3600)
        let minimumVoiced = Self.minimumVoicedDuration
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> {
                $0.endDate != nil && $0.checkInDate == nil && $0.startDate >= start && $0.voicedDuration >= minimumVoiced
            },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

/// The single user profile (created on first use).
@MainActor
struct ProfileStore {
    let context: ModelContext

    func profile() -> UserProfile {
        var descriptor = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        let created = UserProfile()
        context.insert(created)
        return created
    }
}
