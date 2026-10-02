import Foundation
import SwiftData

/// A take's audio written to the Recordings folder.
nonisolated struct SavedAudioFile: Sendable, Equatable {
    let id: UUID
    let fileName: String
    let duration: Double

    /// Encodes the audio off the main thread.
    static func write(_ audio: AudioClip) async throws -> SavedAudioFile {
        let id = UUID()
        let fileName = RecordingFileStore.makeFileName(id: id)
        try await Task.detached(priority: .userInitiated) {
            try RecordingFileStore.write(audio, fileName: fileName)
        }.value
        return SavedAudioFile(id: id, fileName: fileName, duration: audio.duration)
    }

    /// Writes the audio if there is any; nil for silence or a missing clip.
    static func writeIfPresent(_ audio: AudioClip?) async throws -> SavedAudioFile? {
        guard let audio, !audio.samples.isEmpty else { return nil }
        return try await write(audio)
    }
}

extension Recording {
    /// Copies a take's numbers onto the recording.
    nonisolated func apply(_ take: TakeResult, target: PitchTargetZone) {
        averagePitch = take.medianPitch
        percentInTarget = take.percentInTarget
        resonanceScore = take.resonanceScore
        weightScore = take.weightScore
        intonationScore = take.intonationScore
        targetPitchLow = target.lowerBound
        targetPitchHigh = target.upperBound
    }
}

/// The Daily Sentence Journal: the same sentence recorded each day
/// (SPEC section 8), one entry per day.
@MainActor
struct JournalStore {
    let context: ModelContext

    static let sentenceKey = "journal.sentence"

    /// The sentence the user records every day.
    static var sentence: String {
        get {
            let saved = UserDefaults.standard.string(forKey: sentenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return saved.isEmpty ? ReadingPassages.journalSentence : saved
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: sentenceKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: sentenceKey)
            }
        }
    }

    /// Seconds allowed for one reading of the sentence.
    static let recordingDuration = 12.0

    /// All entries, oldest first.
    func entries() -> [DailyJournalEntry] {
        (try? context.fetch(FetchDescriptor<DailyJournalEntry>(sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    func entry(on day: Date, calendar: Calendar = .current) -> DailyJournalEntry? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let descriptor = FetchDescriptor<DailyJournalEntry>(
            predicate: #Predicate<DailyJournalEntry> { $0.date >= start && $0.date < end }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Saves today's recording, replacing an earlier one from the same day.
    @discardableResult
    func save(
        take: TakeResult,
        audio: AudioClip?,
        sentence: String,
        target: PitchTargetZone,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> DailyJournalEntry {
        // Write the audio first so a failure leaves the journal untouched.
        let file = try await SavedAudioFile.writeIfPresent(audio)
        do {
            var replacedFile: String?
            if let existing = entry(on: now, calendar: calendar) {
                replacedFile = existing.recording?.fileName
                context.delete(existing)
            }

            let entry = DailyJournalEntry(date: now, sentence: sentence)
            context.insert(entry)
            entry.averagePitch = take.medianPitch
            entry.resonanceScore = take.resonanceScore
            entry.weightScore = take.weightScore
            entry.intonationScore = take.intonationScore

            if let file {
                let recording = Recording(id: file.id, fileName: file.fileName, duration: file.duration, kind: .journal, createdAt: now)
                context.insert(recording)
                recording.journalEntry = entry
                recording.transcript = sentence
                recording.apply(take, target: target)
            }
            try context.save()
            if let replacedFile {
                RecordingFileStore.delete(fileName: replacedFile)
            }
            return entry
        } catch {
            context.rollback()
            if let file {
                RecordingFileStore.delete(fileName: file.fileName)
            }
            throw error
        }
    }

    /// Deletes an entry, its recording and the audio file.
    func delete(_ entry: DailyJournalEntry) throws {
        let fileName = entry.recording?.fileName
        context.delete(entry)
        try context.save()
        if let fileName {
            RecordingFileStore.delete(fileName: fileName)
        }
    }

    /// Timeline points, oldest first.
    func points() -> [JournalPoint] {
        entries().map { $0.timelinePoint }
    }
}

extension DailyJournalEntry {
    /// The entry's numbers for the timeline.
    nonisolated var timelinePoint: JournalPoint {
        JournalPoint(
            id: id,
            date: date,
            pitch: averagePitch,
            resonance: resonanceScore,
            weight: weightScore,
            intonation: intonationScore,
            hasAudio: recording != nil
        )
    }
}

/// Quick Check (SPEC section 8): a 10-second reading saved as a session of
/// kind `.quickCheck`, with its recording.
@MainActor
struct QuickCheckStore {
    let context: ModelContext

    static let duration = 10.0

    /// The most recent Quick Checks, newest first.
    func recent(limit: Int = 1) -> [PracticeSession] {
        let kind = PracticeSessionKind.quickCheck.rawValue
        var descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate<PracticeSession> { $0.kindRawValue == kind },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The numbers of the most recent Quick Check.
    func latestValues() -> QuickCheckValues? {
        recent().first.map(QuickCheckStore.values(of:))
    }

    static func values(of session: PracticeSession) -> QuickCheckValues {
        QuickCheckValues(
            pitch: session.averagePitch,
            percentInTarget: session.percentInTarget,
            resonance: session.resonanceScore,
            weight: session.weightScore,
            intonation: session.intonationScore,
            date: session.startDate
        )
    }

    @discardableResult
    func save(take: TakeResult, audio: AudioClip?, target: PitchTargetZone, now: Date = Date()) async throws -> PracticeSession {
        let file = try await SavedAudioFile.writeIfPresent(audio)
        do {
            let session = PracticeSession(startDate: now.addingTimeInterval(-take.duration), kind: .quickCheck)
            context.insert(session)
            session.endDate = now
            session.duration = take.duration
            session.voicedDuration = take.voicedDuration
            session.averagePitch = take.medianPitch
            session.minimumPitch = take.lowPitch
            session.maximumPitch = take.highPitch
            session.percentInTarget = take.percentInTarget
            session.targetPitchLow = target.lowerBound
            session.targetPitchHigh = target.upperBound
            session.resonanceScore = take.resonanceScore
            session.brightResonancePercent = take.brightResonancePercent
            session.weightScore = take.weightScore
            session.intonationScore = take.intonationScore

            if let file {
                let recording = Recording(id: file.id, fileName: file.fileName, duration: file.duration, kind: .quickCheck, createdAt: now)
                context.insert(recording)
                recording.session = session
                recording.sessionID = session.id
                recording.transcript = ReadingPassages.quickCheck
                recording.apply(take, target: target)
            }
            try context.save()
            return session
        } catch {
            context.rollback()
            if let file {
                RecordingFileStore.delete(fileName: file.fileName)
            }
            throw error
        }
    }
}
