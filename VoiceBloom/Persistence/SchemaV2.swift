import Foundation
import SwiftData

/// Version 2 of the stored data: version 1 plus `SeparatedTrack` (the vocal
/// splitter, SPEC section 23) and a link from target voices to the split they
/// were measured from. Version 1 stays as shipped; the migration is lightweight
/// (a new model and a new optional relationship).
nonisolated enum VoiceBloomSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            PracticeSession.self,
            Recording.self,
            LessonProgress.self,
            TargetVoiceProfile.self,
            ScenarioResult.self,
            Achievement.self,
            DailyJournalEntry.self,
            SeparatedTrack.self,
        ]
    }

    // MARK: - UserProfile

    /// Goal, targets, baseline values, experience level and preferences.
    /// Device-specific settings (mic calibration, alert settings, voice-quality
    /// norms) stay in UserDefaults because they belong to this iPhone's mic.
    @Model
    nonisolated final class UserProfile {
        var id: UUID = UUID()
        var createdAt: Date = Date()

        // Goal and targets
        var goalTypeRawValue: String = GoalType.feminine.rawValue
        var targetPitchLow: Double = 180
        var targetPitchHigh: Double = 220
        /// Optional overrides of the default resonance/weight/intonation targets.
        var targetF2: Double?
        var targetF3: Double?
        var targetH1MinusH2: Double?
        var targetIntonationSD: Double?
        var activeTargetVoiceProfileID: UUID?

        // Baseline (from the Day 1 recording)
        var baselinePitch: Double?
        var baselinePitchLow: Double?
        var baselinePitchHigh: Double?
        var baselineF2: Double?
        var baselineF3: Double?
        var baselineH1MinusH2: Double?
        var baselineIntonationSD: Double?
        var baselineRecordingID: UUID?

        // Experience and routine
        var experienceLevelRawValue: String = ExperienceLevel.beginner.rawValue
        var dailyGoalMinutes: Int = 15
        var reminderTime: Date?
        var defaultSessionLengthRawValue: String = SessionLength.standard.rawValue

        // Preferences
        var displayUnitsRawValue: String = DisplayUnits.both.rawValue
        var themeRawValue: String = AppTheme.system.rawValue
        var aiCoachEnabled: Bool = true
        var faceIDLockEnabled: Bool = false
        var hasCompletedOnboarding: Bool = false

        // Vocal health
        /// Set when check-ins suggest a rest day; the app shows the suggestion that day.
        var restSuggestedDate: Date?

        init() {}

        var goalType: GoalType {
            get { GoalType(rawValue: goalTypeRawValue) ?? .feminine }
            set { goalTypeRawValue = newValue.rawValue }
        }

        var experienceLevel: ExperienceLevel {
            get { ExperienceLevel(rawValue: experienceLevelRawValue) ?? .beginner }
            set { experienceLevelRawValue = newValue.rawValue }
        }

        var targetZone: PitchTargetZone {
            get { PitchTargetZone(lowerBound: targetPitchLow, upperBound: targetPitchHigh) }
            set {
                targetPitchLow = newValue.lowerBound
                targetPitchHigh = newValue.upperBound
            }
        }
    }

    // MARK: - PracticeSession ("Session" in the spec)

    @Model
    nonisolated final class PracticeSession {
        var id: UUID = UUID()
        var startDate: Date = Date()
        /// Set when the session is finished (nil while still in progress).
        var endDate: Date?
        /// Seconds spent listening, excluding pauses.
        var duration: Double = 0
        var voicedDuration: Double = 0
        var kindRawValue: String = PracticeSessionKind.freePractice.rawValue
        var lessonID: String?

        // Pitch
        var averagePitch: Double?
        var minimumPitch: Double?
        var maximumPitch: Double?
        var percentInTarget: Double?
        var targetPitchLow: Double = 180
        var targetPitchHigh: Double = 220

        // Resonance, weight, intonation (0–100 averages)
        var resonanceScore: Double?
        var brightResonancePercent: Double?
        var resonanceModeRawValue: String = ResonanceMode.speech.rawValue
        var weightScore: Double?
        var intonationScore: Double?

        // Voice quality (rough indicators)
        var jitterPercent: Double?
        var shimmerPercent: Double?
        var harmonicsToNoiseDb: Double?
        var slipAlertCount: Int = 0
        var strainWarningCount: Int = 0

        // Check-in
        var comfortRawValue: String?
        var naturalnessRating: Int?
        var checkInDate: Date?

        var aiFeedback: String?

        @Relationship(deleteRule: .cascade, inverse: \Recording.session)
        var recordings: [Recording]? = []

        init(id: UUID = UUID(), startDate: Date = Date(), kind: PracticeSessionKind = .freePractice) {
            self.id = id
            self.startDate = startDate
            kindRawValue = kind.rawValue
        }

        var kind: PracticeSessionKind {
            get { PracticeSessionKind(rawValue: kindRawValue) ?? .freePractice }
            set { kindRawValue = newValue.rawValue }
        }

        var comfort: ComfortRating? {
            get { comfortRawValue.flatMap(ComfortRating.init(rawValue:)) }
            set { comfortRawValue = newValue?.rawValue }
        }

        var isFinished: Bool { endDate != nil }
        var hasCheckIn: Bool { checkInDate != nil }

        var targetZone: PitchTargetZone {
            PitchTargetZone(lowerBound: targetPitchLow, upperBound: targetPitchHigh)
        }

        /// Copies the latest statistics into the stored session.
        func apply(_ snapshot: SessionSnapshot) {
            duration = snapshot.activeDuration
            voicedDuration = snapshot.voicedDuration
            averagePitch = snapshot.averagePitch
            minimumPitch = snapshot.minimumPitch
            maximumPitch = snapshot.maximumPitch
            percentInTarget = snapshot.percentInTarget
            targetPitchLow = snapshot.target.lowerBound
            targetPitchHigh = snapshot.target.upperBound
            resonanceScore = snapshot.resonanceScore
            brightResonancePercent = snapshot.brightResonancePercent
            resonanceModeRawValue = snapshot.resonanceMode.rawValue
            weightScore = snapshot.weightScore
            intonationScore = snapshot.intonationScore
            jitterPercent = snapshot.jitterPercent
            shimmerPercent = snapshot.shimmerPercent
            harmonicsToNoiseDb = snapshot.harmonicsToNoiseDb
            slipAlertCount = snapshot.slipAlertCount
            strainWarningCount = snapshot.strainWarningCount
        }
    }

    // MARK: - Recording

    /// An audio clip saved on this device. The file lives in the app's
    /// Recordings folder (never uploaded or backed up); only its name is stored,
    /// because the app's container path can change between launches.
    @Model
    nonisolated final class Recording {
        var id: UUID = UUID()
        var sessionID: UUID?
        var session: PracticeSession?
        var journalEntry: DailyJournalEntry?
        var createdAt: Date = Date()
        var fileName: String = ""
        var duration: Double = 0
        var kindRawValue: String = RecordingKind.clip.rawValue
        var transcript: String?

        // Stats for the recorded stretch
        var averagePitch: Double?
        var percentInTarget: Double?
        var resonanceScore: Double?
        var weightScore: Double?
        var intonationScore: Double?
        var targetPitchLow: Double = 180
        var targetPitchHigh: Double = 220

        init(id: UUID = UUID(), fileName: String, duration: Double, kind: RecordingKind = .clip, createdAt: Date = Date()) {
            self.id = id
            self.fileName = fileName
            self.duration = duration
            kindRawValue = kind.rawValue
            self.createdAt = createdAt
        }

        var kind: RecordingKind {
            get { RecordingKind(rawValue: kindRawValue) ?? .clip }
            set { kindRawValue = newValue.rawValue }
        }

        /// Where the audio file is on disk (nil if the folder can't be found).
        var fileURL: URL? {
            try? RecordingFileStore.url(for: fileName)
        }

        func apply(_ stats: ClipStats) {
            averagePitch = stats.averagePitch
            percentInTarget = stats.percentInTarget
            resonanceScore = stats.resonanceScore
            weightScore = stats.weightScore
            intonationScore = stats.intonationScore
            targetPitchLow = stats.target.lowerBound
            targetPitchHigh = stats.target.upperBound
        }
    }

    // MARK: - LessonProgress

    @Model
    nonisolated final class LessonProgress {
        var week: Int = 1
        var sessionsCompleted: Int = 0
        var goalMet: Bool = false
        var unlockedDate: Date?
        var completedDate: Date?
        var lastPracticedDate: Date?

        init(week: Int, unlockedDate: Date? = nil) {
            self.week = week
            self.unlockedDate = unlockedDate
        }
    }

    // MARK: - TargetVoiceProfile

    @Model
    nonisolated final class TargetVoiceProfile {
        var id: UUID = UUID()
        var name: String = ""
        var createdAt: Date = Date()
        var isActive: Bool = false

        // Pitch
        var averagePitch: Double?
        var minimumPitch: Double?
        var maximumPitch: Double?
        /// Share of voiced time per pitch bin; bin i starts at
        /// histogramLowerBound · 2^(i · histogramBinSemitones / 12) Hz.
        var pitchHistogram: [Double] = []
        var histogramLowerBound: Double = 60
        var histogramBinSemitones: Double = 1

        // Resonance, weight, intonation
        var averageF1: Double?
        var averageF2: Double?
        var averageF3: Double?
        var h1MinusH2: Double?
        var spectralTilt: Double?
        var intonationSD: Double?

        // Source clip
        var sourceClipFileName: String?
        var clipStart: Double?
        var clipEnd: Double?
        /// The split this voice was measured from (its isolated vocals).
        var separatedTrack: SeparatedTrack?

        init(name: String) {
            self.name = name
        }
    }

    // MARK: - ScenarioResult

    @Model
    nonisolated final class ScenarioResult {
        var id: UUID = UUID()
        var scenarioID: String = ""
        var difficultyRawValue: String = ScenarioDifficulty.easy.rawValue
        var date: Date = Date()
        /// Per-turn scores, JSON-encoded `[ScenarioTurnScore]`.
        var turnScoresData: Data = Data()
        var transcript: String = ""
        var overallScore: Double?
        var usedAIPartner: Bool = false

        init(scenarioID: String, difficulty: ScenarioDifficulty) {
            self.scenarioID = scenarioID
            difficultyRawValue = difficulty.rawValue
        }

        var difficulty: ScenarioDifficulty {
            get { ScenarioDifficulty(rawValue: difficultyRawValue) ?? .easy }
            set { difficultyRawValue = newValue.rawValue }
        }

        var turnScores: [ScenarioTurnScore] {
            get { (try? JSONDecoder().decode([ScenarioTurnScore].self, from: turnScoresData)) ?? [] }
            set { turnScoresData = (try? JSONEncoder().encode(newValue)) ?? Data() }
        }
    }

    // MARK: - Achievement

    @Model
    nonisolated final class Achievement {
        var identifier: String = ""
        var unlockedDate: Date = Date()

        init(identifier: String, unlockedDate: Date = Date()) {
            self.identifier = identifier
            self.unlockedDate = unlockedDate
        }
    }

    // MARK: - DailyJournalEntry

    @Model
    nonisolated final class DailyJournalEntry {
        var id: UUID = UUID()
        var date: Date = Date()
        var sentence: String = ""
        @Relationship(deleteRule: .cascade, inverse: \Recording.journalEntry)
        var recording: Recording?
        var averagePitch: Double?
        var resonanceScore: Double?
        var weightScore: Double?
        var intonationScore: Double?

        init(date: Date = Date(), sentence: String) {
            self.date = date
            self.sentence = sentence
        }
    }

    // MARK: - SeparatedTrack (SPEC section 23.5)

    /// A song or video split into vocals and backing. Files live in
    /// Application Support/Separations/<id>/ (see `SeparationFiles`).
    @Model
    nonisolated final class SeparatedTrack {
        var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        /// A copy of the original, kept for video exports.
        var sourceFileName: String?
        var sourceTypeRawValue: String = SeparationSourceType.audio.rawValue
        var engineRawValue: String = SeparationEngineKind.basic.rawValue
        var qualityRawValue: String = SeparationQuality.fast.rawValue
        var vocalsFileName: String?
        var backingFileName: String?
        var duration: Double = 0
        var sourceFileSize: Int64 = 0
        var vocalsFileSize: Int64 = 0
        var backingFileSize: Int64 = 0
        @Relationship(deleteRule: .nullify, inverse: \TargetVoiceProfile.separatedTrack)
        var targetVoices: [TargetVoiceProfile]? = []

        init(id: UUID = UUID(), title: String) {
            self.id = id
            self.title = title
        }

        var sourceType: SeparationSourceType {
            get { SeparationSourceType(rawValue: sourceTypeRawValue) ?? .audio }
            set { sourceTypeRawValue = newValue.rawValue }
        }

        var engine: SeparationEngineKind {
            get { SeparationEngineKind(rawValue: engineRawValue) ?? .basic }
            set { engineRawValue = newValue.rawValue }
        }

        var quality: SeparationQuality {
            get { SeparationQuality(rawValue: qualityRawValue) ?? .fast }
            set { qualityRawValue = newValue.rawValue }
        }

        var totalFileSize: Int64 { sourceFileSize + vocalsFileSize + backingFileSize }
    }
}
