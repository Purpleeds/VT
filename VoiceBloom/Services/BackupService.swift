import CoreTransferable
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Archive format

/// A manual backup of everything (SPEC section 13): all stored records, the
/// audio files and a few preferences, in one JSON file the user keeps.
nonisolated struct BackupArchive: Codable, Sendable, Equatable {
    static let currentFormat = 1

    var format = BackupArchive.currentFormat
    var createdAt: Date
    var appVersion: String?
    var profiles: [ProfileRecord] = []
    var sessions: [SessionRecord] = []
    var recordings: [RecordingRecord] = []
    var lessonProgress: [LessonProgressRecord] = []
    var targetVoices: [TargetVoiceRecord] = []
    var scenarioResults: [ScenarioResultRecord] = []
    var achievements: [AchievementRecord] = []
    var journalEntries: [JournalRecord] = []
    var files: [BackupFile] = []
    var preferences = BackupPreferences()

    var recordCount: Int {
        profiles.count + sessions.count + recordings.count + lessonProgress.count + targetVoices.count
            + scenarioResults.count + achievements.count + journalEntries.count
    }
}

/// Just the format number, read before the rest of a backup.
private nonisolated struct BackupFormatHeader: Decodable {
    let format: Int
}

nonisolated struct BackupFile: Codable, Sendable, Equatable {
    let name: String
    let data: Data
}

nonisolated struct BackupPreferences: Codable, Sendable, Equatable {
    var journalSentence: String?
    var aiProvider: String?
    var discreetMode = false
    var challengeDays: [String] = []
    var pitchGameScores: [PitchGameRecord] = []
    var placementWeek: Int?
}

nonisolated struct ProfileRecord: Codable, Sendable, Equatable {
    var id: UUID
    var createdAt: Date
    var goalTypeRawValue: String
    var targetPitchLow: Double
    var targetPitchHigh: Double
    var targetF2: Double?
    var targetF3: Double?
    var targetH1MinusH2: Double?
    var targetIntonationSD: Double?
    var activeTargetVoiceProfileID: UUID?
    var baselinePitch: Double?
    var baselinePitchLow: Double?
    var baselinePitchHigh: Double?
    var baselineF2: Double?
    var baselineF3: Double?
    var baselineH1MinusH2: Double?
    var baselineIntonationSD: Double?
    var baselineRecordingID: UUID?
    var experienceLevelRawValue: String
    var dailyGoalMinutes: Int
    var reminderTime: Date?
    var defaultSessionLengthRawValue: String
    var displayUnitsRawValue: String
    var themeRawValue: String
    var aiCoachEnabled: Bool
    var faceIDLockEnabled: Bool
    var hasCompletedOnboarding: Bool
    var restSuggestedDate: Date?
}

nonisolated struct SessionRecord: Codable, Sendable, Equatable {
    var id: UUID
    var startDate: Date
    var endDate: Date?
    var duration: Double
    var voicedDuration: Double
    var kindRawValue: String
    var lessonID: String?
    var averagePitch: Double?
    var minimumPitch: Double?
    var maximumPitch: Double?
    var percentInTarget: Double?
    var targetPitchLow: Double
    var targetPitchHigh: Double
    var resonanceScore: Double?
    var brightResonancePercent: Double?
    var resonanceModeRawValue: String
    var weightScore: Double?
    var intonationScore: Double?
    var jitterPercent: Double?
    var shimmerPercent: Double?
    var harmonicsToNoiseDb: Double?
    var slipAlertCount: Int
    var strainWarningCount: Int
    var comfortRawValue: String?
    var naturalnessRating: Int?
    var checkInDate: Date?
    var aiFeedback: String?
}

nonisolated struct RecordingRecord: Codable, Sendable, Equatable {
    var id: UUID
    var sessionID: UUID?
    var journalEntryID: UUID?
    var createdAt: Date
    var fileName: String
    var duration: Double
    var kindRawValue: String
    var transcript: String?
    var averagePitch: Double?
    var percentInTarget: Double?
    var resonanceScore: Double?
    var weightScore: Double?
    var intonationScore: Double?
    var targetPitchLow: Double
    var targetPitchHigh: Double
}

nonisolated struct LessonProgressRecord: Codable, Sendable, Equatable {
    var week: Int
    var sessionsCompleted: Int
    var goalMet: Bool
    var unlockedDate: Date?
    var completedDate: Date?
    var lastPracticedDate: Date?
}

nonisolated struct TargetVoiceRecord: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var isActive: Bool
    var averagePitch: Double?
    var minimumPitch: Double?
    var maximumPitch: Double?
    var pitchHistogram: [Double]
    var histogramLowerBound: Double
    var histogramBinSemitones: Double
    var averageF1: Double?
    var averageF2: Double?
    var averageF3: Double?
    var h1MinusH2: Double?
    var spectralTilt: Double?
    var intonationSD: Double?
    var sourceClipFileName: String?
    var clipStart: Double?
    var clipEnd: Double?
}

nonisolated struct ScenarioResultRecord: Codable, Sendable, Equatable {
    var id: UUID
    var scenarioID: String
    var difficultyRawValue: String
    var date: Date
    var turnScoresData: Data
    var transcript: String
    var overallScore: Double?
    var usedAIPartner: Bool
}

nonisolated struct AchievementRecord: Codable, Sendable, Equatable {
    var identifier: String
    var unlockedDate: Date
}

nonisolated struct JournalRecord: Codable, Sendable, Equatable {
    var id: UUID
    var date: Date
    var sentence: String
    var averagePitch: Double?
    var resonanceScore: Double?
    var weightScore: Double?
    var intonationScore: Double?
}

nonisolated enum BackupError: LocalizedError, Sendable, Equatable {
    case unreadable
    case newerFormat

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn’t a VoiceBloom backup, or it’s damaged."
        case .newerFormat: "This backup was made by a newer version of VoiceBloom. Update the app, then try again."
        }
    }
}

// MARK: - Making and restoring backups

@MainActor
enum BackupService {
    static func makeArchive(context: ModelContext, now: Date = Date(), includeFiles: Bool = true) throws -> BackupArchive {
        var archive = BackupArchive(createdAt: now)
        archive.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        archive.profiles = try context.fetch(FetchDescriptor<UserProfile>()).map { profile in
            ProfileRecord(
                id: profile.id, createdAt: profile.createdAt, goalTypeRawValue: profile.goalTypeRawValue,
                targetPitchLow: profile.targetPitchLow, targetPitchHigh: profile.targetPitchHigh,
                targetF2: profile.targetF2, targetF3: profile.targetF3, targetH1MinusH2: profile.targetH1MinusH2,
                targetIntonationSD: profile.targetIntonationSD, activeTargetVoiceProfileID: profile.activeTargetVoiceProfileID,
                baselinePitch: profile.baselinePitch, baselinePitchLow: profile.baselinePitchLow, baselinePitchHigh: profile.baselinePitchHigh,
                baselineF2: profile.baselineF2, baselineF3: profile.baselineF3, baselineH1MinusH2: profile.baselineH1MinusH2,
                baselineIntonationSD: profile.baselineIntonationSD, baselineRecordingID: profile.baselineRecordingID,
                experienceLevelRawValue: profile.experienceLevelRawValue, dailyGoalMinutes: profile.dailyGoalMinutes,
                reminderTime: profile.reminderTime, defaultSessionLengthRawValue: profile.defaultSessionLengthRawValue,
                displayUnitsRawValue: profile.displayUnitsRawValue, themeRawValue: profile.themeRawValue,
                aiCoachEnabled: profile.aiCoachEnabled, faceIDLockEnabled: profile.faceIDLockEnabled,
                hasCompletedOnboarding: profile.hasCompletedOnboarding, restSuggestedDate: profile.restSuggestedDate
            )
        }
        archive.sessions = try context.fetch(FetchDescriptor<PracticeSession>()).map { session in
            SessionRecord(
                id: session.id, startDate: session.startDate, endDate: session.endDate, duration: session.duration,
                voicedDuration: session.voicedDuration, kindRawValue: session.kindRawValue, lessonID: session.lessonID,
                averagePitch: session.averagePitch, minimumPitch: session.minimumPitch, maximumPitch: session.maximumPitch,
                percentInTarget: session.percentInTarget, targetPitchLow: session.targetPitchLow, targetPitchHigh: session.targetPitchHigh,
                resonanceScore: session.resonanceScore, brightResonancePercent: session.brightResonancePercent,
                resonanceModeRawValue: session.resonanceModeRawValue, weightScore: session.weightScore,
                intonationScore: session.intonationScore, jitterPercent: session.jitterPercent, shimmerPercent: session.shimmerPercent,
                harmonicsToNoiseDb: session.harmonicsToNoiseDb, slipAlertCount: session.slipAlertCount,
                strainWarningCount: session.strainWarningCount, comfortRawValue: session.comfortRawValue,
                naturalnessRating: session.naturalnessRating, checkInDate: session.checkInDate, aiFeedback: session.aiFeedback
            )
        }
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        archive.recordings = recordings.map { recording in
            RecordingRecord(
                id: recording.id, sessionID: recording.session?.id ?? recording.sessionID,
                journalEntryID: recording.journalEntry?.id, createdAt: recording.createdAt, fileName: recording.fileName,
                duration: recording.duration, kindRawValue: recording.kindRawValue, transcript: recording.transcript,
                averagePitch: recording.averagePitch, percentInTarget: recording.percentInTarget,
                resonanceScore: recording.resonanceScore, weightScore: recording.weightScore,
                intonationScore: recording.intonationScore, targetPitchLow: recording.targetPitchLow,
                targetPitchHigh: recording.targetPitchHigh
            )
        }
        archive.lessonProgress = try context.fetch(FetchDescriptor<LessonProgress>()).map { progress in
            LessonProgressRecord(
                week: progress.week, sessionsCompleted: progress.sessionsCompleted, goalMet: progress.goalMet,
                unlockedDate: progress.unlockedDate, completedDate: progress.completedDate, lastPracticedDate: progress.lastPracticedDate
            )
        }
        let targets = try context.fetch(FetchDescriptor<TargetVoiceProfile>())
        archive.targetVoices = targets.map { target in
            TargetVoiceRecord(
                id: target.id, name: target.name, createdAt: target.createdAt, isActive: target.isActive,
                averagePitch: target.averagePitch, minimumPitch: target.minimumPitch, maximumPitch: target.maximumPitch,
                pitchHistogram: target.pitchHistogram, histogramLowerBound: target.histogramLowerBound,
                histogramBinSemitones: target.histogramBinSemitones, averageF1: target.averageF1, averageF2: target.averageF2,
                averageF3: target.averageF3, h1MinusH2: target.h1MinusH2, spectralTilt: target.spectralTilt,
                intonationSD: target.intonationSD, sourceClipFileName: target.sourceClipFileName,
                clipStart: target.clipStart, clipEnd: target.clipEnd
            )
        }
        archive.scenarioResults = try context.fetch(FetchDescriptor<ScenarioResult>()).map { result in
            ScenarioResultRecord(
                id: result.id, scenarioID: result.scenarioID, difficultyRawValue: result.difficultyRawValue, date: result.date,
                turnScoresData: result.turnScoresData, transcript: result.transcript, overallScore: result.overallScore,
                usedAIPartner: result.usedAIPartner
            )
        }
        archive.achievements = try context.fetch(FetchDescriptor<Achievement>()).map {
            AchievementRecord(identifier: $0.identifier, unlockedDate: $0.unlockedDate)
        }
        archive.journalEntries = try context.fetch(FetchDescriptor<DailyJournalEntry>()).map { entry in
            JournalRecord(
                id: entry.id, date: entry.date, sentence: entry.sentence, averagePitch: entry.averagePitch,
                resonanceScore: entry.resonanceScore, weightScore: entry.weightScore, intonationScore: entry.intonationScore
            )
        }

        if includeFiles {
            let names = Set(recordings.map(\.fileName) + targets.compactMap(\.sourceClipFileName)).filter { !$0.isEmpty }
            archive.files = names.sorted().compactMap { name in
                guard let url = try? RecordingFileStore.url(for: name), let data = try? Data(contentsOf: url) else { return nil }
                return BackupFile(name: name, data: data)
            }
        }

        let defaults = UserDefaults.standard
        archive.preferences = BackupPreferences(
            journalSentence: defaults.string(forKey: JournalStore.sentenceKey),
            aiProvider: defaults.string(forKey: AppPreferences.aiProviderKey),
            discreetMode: DiscreetMode.isEnabled,
            challengeDays: ChallengeStore.doneDays(),
            pitchGameScores: PitchGameScores.all(),
            placementWeek: AppPreferences.placementWeek
        )
        return archive
    }

    static func encode(_ archive: BackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Read the format first so a newer backup gets a clear message.
        guard let header = try? decoder.decode(BackupFormatHeader.self, from: data) else { throw BackupError.unreadable }
        guard header.format <= BackupArchive.currentFormat else { throw BackupError.newerFormat }
        guard let archive = try? decoder.decode(BackupArchive.self, from: data) else { throw BackupError.unreadable }
        return archive
    }

    /// Replaces everything on this iPhone with the backup.
    /// - Parameter includesDeviceState: also replace the audio files and
    ///   preferences (tests turn this off to leave the simulator alone).
    static func restore(_ archive: BackupArchive, context: ModelContext, includesDeviceState: Bool = true) throws {
        try context.delete(model: Recording.self)
        try context.delete(model: PracticeSession.self)
        try context.delete(model: DailyJournalEntry.self)
        try context.delete(model: ScenarioResult.self)
        try context.delete(model: TargetVoiceProfile.self)
        try context.delete(model: LessonProgress.self)
        try context.delete(model: Achievement.self)
        try context.delete(model: UserProfile.self)
        try context.save()

        if includesDeviceState {
            replaceFiles(with: archive.files)
        }

        for record in archive.profiles {
            let profile = UserProfile()
            profile.id = record.id
            profile.createdAt = record.createdAt
            profile.goalTypeRawValue = record.goalTypeRawValue
            profile.targetPitchLow = record.targetPitchLow
            profile.targetPitchHigh = record.targetPitchHigh
            profile.targetF2 = record.targetF2
            profile.targetF3 = record.targetF3
            profile.targetH1MinusH2 = record.targetH1MinusH2
            profile.targetIntonationSD = record.targetIntonationSD
            profile.activeTargetVoiceProfileID = record.activeTargetVoiceProfileID
            profile.baselinePitch = record.baselinePitch
            profile.baselinePitchLow = record.baselinePitchLow
            profile.baselinePitchHigh = record.baselinePitchHigh
            profile.baselineF2 = record.baselineF2
            profile.baselineF3 = record.baselineF3
            profile.baselineH1MinusH2 = record.baselineH1MinusH2
            profile.baselineIntonationSD = record.baselineIntonationSD
            profile.baselineRecordingID = record.baselineRecordingID
            profile.experienceLevelRawValue = record.experienceLevelRawValue
            profile.dailyGoalMinutes = record.dailyGoalMinutes
            profile.reminderTime = record.reminderTime
            profile.defaultSessionLengthRawValue = record.defaultSessionLengthRawValue
            profile.displayUnitsRawValue = record.displayUnitsRawValue
            profile.themeRawValue = record.themeRawValue
            profile.aiCoachEnabled = record.aiCoachEnabled
            profile.faceIDLockEnabled = record.faceIDLockEnabled
            profile.hasCompletedOnboarding = record.hasCompletedOnboarding
            profile.restSuggestedDate = record.restSuggestedDate
            context.insert(profile)
        }

        var sessionsByID: [UUID: PracticeSession] = [:]
        for record in archive.sessions {
            let session = PracticeSession(id: record.id, startDate: record.startDate)
            session.endDate = record.endDate
            session.duration = record.duration
            session.voicedDuration = record.voicedDuration
            session.kindRawValue = record.kindRawValue
            session.lessonID = record.lessonID
            session.averagePitch = record.averagePitch
            session.minimumPitch = record.minimumPitch
            session.maximumPitch = record.maximumPitch
            session.percentInTarget = record.percentInTarget
            session.targetPitchLow = record.targetPitchLow
            session.targetPitchHigh = record.targetPitchHigh
            session.resonanceScore = record.resonanceScore
            session.brightResonancePercent = record.brightResonancePercent
            session.resonanceModeRawValue = record.resonanceModeRawValue
            session.weightScore = record.weightScore
            session.intonationScore = record.intonationScore
            session.jitterPercent = record.jitterPercent
            session.shimmerPercent = record.shimmerPercent
            session.harmonicsToNoiseDb = record.harmonicsToNoiseDb
            session.slipAlertCount = record.slipAlertCount
            session.strainWarningCount = record.strainWarningCount
            session.comfortRawValue = record.comfortRawValue
            session.naturalnessRating = record.naturalnessRating
            session.checkInDate = record.checkInDate
            session.aiFeedback = record.aiFeedback
            context.insert(session)
            sessionsByID[record.id] = session
        }

        var entriesByID: [UUID: DailyJournalEntry] = [:]
        for record in archive.journalEntries {
            let entry = DailyJournalEntry(date: record.date, sentence: record.sentence)
            entry.id = record.id
            entry.averagePitch = record.averagePitch
            entry.resonanceScore = record.resonanceScore
            entry.weightScore = record.weightScore
            entry.intonationScore = record.intonationScore
            context.insert(entry)
            entriesByID[record.id] = entry
        }

        for record in archive.recordings where isSafeFileName(record.fileName) {
            let recording = Recording(id: record.id, fileName: record.fileName, duration: record.duration, createdAt: record.createdAt)
            recording.kindRawValue = record.kindRawValue
            recording.transcript = record.transcript
            recording.averagePitch = record.averagePitch
            recording.percentInTarget = record.percentInTarget
            recording.resonanceScore = record.resonanceScore
            recording.weightScore = record.weightScore
            recording.intonationScore = record.intonationScore
            recording.targetPitchLow = record.targetPitchLow
            recording.targetPitchHigh = record.targetPitchHigh
            recording.sessionID = record.sessionID
            context.insert(recording)
            if let id = record.sessionID, let session = sessionsByID[id] {
                recording.session = session
            }
            if let id = record.journalEntryID, let entry = entriesByID[id] {
                recording.journalEntry = entry
            }
        }

        for record in archive.lessonProgress {
            let progress = LessonProgress(week: record.week, unlockedDate: record.unlockedDate)
            progress.sessionsCompleted = record.sessionsCompleted
            progress.goalMet = record.goalMet
            progress.completedDate = record.completedDate
            progress.lastPracticedDate = record.lastPracticedDate
            context.insert(progress)
        }

        for record in archive.targetVoices {
            let target = TargetVoiceProfile(name: record.name)
            target.id = record.id
            target.createdAt = record.createdAt
            target.isActive = record.isActive
            target.averagePitch = record.averagePitch
            target.minimumPitch = record.minimumPitch
            target.maximumPitch = record.maximumPitch
            target.pitchHistogram = record.pitchHistogram
            target.histogramLowerBound = record.histogramLowerBound
            target.histogramBinSemitones = record.histogramBinSemitones
            target.averageF1 = record.averageF1
            target.averageF2 = record.averageF2
            target.averageF3 = record.averageF3
            target.h1MinusH2 = record.h1MinusH2
            target.spectralTilt = record.spectralTilt
            target.intonationSD = record.intonationSD
            target.sourceClipFileName = record.sourceClipFileName.flatMap { isSafeFileName($0) ? $0 : nil }
            target.clipStart = record.clipStart
            target.clipEnd = record.clipEnd
            context.insert(target)
        }

        for record in archive.scenarioResults {
            let result = ScenarioResult(scenarioID: record.scenarioID, difficulty: .easy)
            result.id = record.id
            result.difficultyRawValue = record.difficultyRawValue
            result.date = record.date
            result.turnScoresData = record.turnScoresData
            result.transcript = record.transcript
            result.overallScore = record.overallScore
            result.usedAIPartner = record.usedAIPartner
            context.insert(result)
        }

        for record in archive.achievements {
            context.insert(Achievement(identifier: record.identifier, unlockedDate: record.unlockedDate))
        }
        try context.save()

        if includesDeviceState {
            restorePreferences(archive.preferences)
        }
    }

    /// Replaces the Recordings folder with the backup's audio files.
    private static func replaceFiles(with files: [BackupFile]) {
        if let folder = try? RecordingFileStore.directory() {
            try? FileManager.default.removeItem(at: folder)
        }
        // A backup file is outside input: only plain file names are written
        // into the Recordings folder.
        for file in files where isSafeFileName(file.name) {
            if let url = try? RecordingFileStore.url(for: file.name) {
                try? file.data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }

    private static func restorePreferences(_ preferences: BackupPreferences) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.journalSentence, forKey: JournalStore.sentenceKey)
        defaults.set(preferences.aiProvider, forKey: AppPreferences.aiProviderKey)
        defaults.set(preferences.discreetMode, forKey: DiscreetMode.key)
        defaults.set(preferences.challengeDays, forKey: ChallengeStore.key)
        defaults.set(try? JSONEncoder().encode(preferences.pitchGameScores), forKey: PitchGameScores.key)
        if let week = preferences.placementWeek {
            defaults.set(week, forKey: AppPreferences.placementWeekKey)
        }
    }

    /// A plain file name: no folders, no "..", not hidden.
    nonisolated static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }

    static func fileName(for date: Date = Date()) -> String {
        "VoiceBloom Backup \(date.formatted(.iso8601.year().month().day()))"
    }
}

/// The backup as a file for `.fileExporter`.
nonisolated struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.unreadable }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
