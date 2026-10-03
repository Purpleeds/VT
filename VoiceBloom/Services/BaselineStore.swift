import Foundation
import SwiftData
import WidgetKit

/// Saves the Day 1 baseline (or the week 16 re-recording): a practice session
/// of kind `.baseline` with the reading and free-speech recordings.
@MainActor
enum BaselineStore {
    nonisolated struct Take: Sendable {
        let result: TakeResult
        let audio: AudioClip?
        let transcript: String?
    }

    /// - Parameter updatesProfile: True for Day 1 (sets the baseline values
    ///   the meters are scored from); false for a later re-recording.
    @discardableResult
    static func save(
        reading: Take?,
        speech: Take?,
        target: PitchTargetZone,
        profile: UserProfile,
        updatesProfile: Bool,
        context: ModelContext,
        now: Date = Date()
    ) async throws -> PracticeSession {
        let takes = [reading, speech].compactMap { $0 }
        let session = PracticeSession(startDate: now, kind: .baseline)
        context.insert(session)
        session.endDate = now
        session.targetPitchLow = target.lowerBound
        session.targetPitchHigh = target.upperBound
        session.duration = takes.reduce(0) { $0 + $1.result.duration }
        session.voicedDuration = takes.reduce(0) { $0 + $1.result.voicedDuration }
        let main = reading?.result ?? speech?.result
        session.averagePitch = main?.averagePitch
        session.minimumPitch = takes.compactMap(\.result.lowPitch).min()
        session.maximumPitch = takes.compactMap(\.result.highPitch).max()
        session.percentInTarget = main?.percentInTarget
        session.resonanceScore = main?.resonanceScore
        session.brightResonancePercent = main?.brightResonancePercent
        session.weightScore = main?.weightScore
        session.intonationScore = speech?.result.intonationScore ?? main?.intonationScore

        var readingRecordingID: UUID?
        for (take, label) in [(reading, "reading"), (speech, "free speech")] {
            guard let take, let audio = take.audio, !audio.samples.isEmpty else { continue }
            let id = UUID()
            let fileName = RecordingFileStore.makeFileName(id: id)
            try await Task.detached(priority: .userInitiated) {
                try RecordingFileStore.write(audio, fileName: fileName)
            }.value
            let recording = Recording(id: id, fileName: fileName, duration: audio.duration, kind: .baseline, createdAt: now)
            context.insert(recording)
            recording.session = session
            recording.sessionID = session.id
            recording.averagePitch = take.result.averagePitch
            recording.percentInTarget = take.result.percentInTarget
            recording.resonanceScore = take.result.resonanceScore
            recording.weightScore = take.result.weightScore
            recording.intonationScore = take.result.intonationScore
            recording.targetPitchLow = target.lowerBound
            recording.targetPitchHigh = target.upperBound
            recording.transcript = take.transcript ?? (label == "reading" ? ReadingPassages.baseline : nil)
            if label == "reading" {
                readingRecordingID = id
            }
        }

        if updatesProfile {
            profile.applyBaseline(reading: reading?.result, speech: speech?.result, recordingID: readingRecordingID)
        }
        try context.save()
        return session
    }
}

/// Applies a placement-test result: the recommended week and every week
/// before it are unlocked.
@MainActor
enum PlacementStore {
    static func apply(week: Int, result: PlacementResult, context: ModelContext, now: Date = Date()) throws {
        AppPreferences.savePlacement(week: week, result: result, date: now)
        let existing = try context.fetch(FetchDescriptor<LessonProgress>())
        for lessonWeek in 1...max(1, week) {
            if let progress = existing.first(where: { $0.week == lessonWeek }) {
                if progress.unlockedDate == nil {
                    progress.unlockedDate = now
                }
            } else {
                context.insert(LessonProgress(week: lessonWeek, unlockedDate: now))
            }
        }
        try context.save()
    }
}

/// "Delete all data" (SPEC sections 13 and 16).
@MainActor
enum DataEraser {
    static func eraseEverything(context: ModelContext) throws {
        try context.delete(model: Recording.self)
        try context.delete(model: PracticeSession.self)
        try context.delete(model: DailyJournalEntry.self)
        try context.delete(model: ScenarioResult.self)
        try context.delete(model: TargetVoiceProfile.self)
        try context.delete(model: LessonProgress.self)
        try context.delete(model: Achievement.self)
        try context.delete(model: UserProfile.self)
        try context.delete(model: SeparatedTrack.self)
        try context.delete(model: TrackSegment.self)
        try context.delete(model: PitchTrack.self)
        try context.save()

        SeparationFiles.deleteAll()
        PitchTrackFiles.deleteAll()
        if let folder = try? RecordingFileStore.directory() {
            try? FileManager.default.removeItem(at: folder)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        KeychainStore.set(nil, account: KeychainStore.geminiAPIKeyAccount)
        NotificationService.cancelAll()
        WidgetSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
        // Back to the standard icon (iOS confirms the change with an alert).
        if AppIconService.current != .standard {
            Task { _ = await AppIconService.set(.standard) }
        }
    }
}
