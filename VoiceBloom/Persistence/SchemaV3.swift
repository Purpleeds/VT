import Foundation
import SwiftData

/// Version 3 of the stored data: version 2 plus Pitch Tracks (SPEC section
/// 22.8: `PitchTrack` and its `TrackSegment` bars). The other models didn't
/// change, so this version lists version 2's types as they are; only the new
/// models are defined here. The migration is lightweight (new models only).
nonisolated enum VoiceBloomSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        VoiceBloomSchemaV2.models + [PitchTrack.self, TrackSegment.self]
    }

    // MARK: - PitchTrack (SPEC section 22.8)

    /// A track made from an uploaded clip. Built-in exercise tracks are
    /// generated on the fly and aren't stored. The clip's audio lives in
    /// Application Support/PitchTracks/<id>/ (see `PitchTrackFiles`).
    @Model
    nonisolated final class PitchTrack {
        var id: UUID = UUID()
        var name: String = ""
        var createdAt: Date = Date()
        var lastPlayedAt: Date?
        /// `PitchTrackKind`: speech or singing.
        var kindRawValue: String = PitchTrackKind.speech.rawValue
        /// What detection suggested (the user may have overridden it).
        var detectedKindRawValue: String?
        var duration: Double = 0
        /// The trimmed clip (original mix), inside the track's folder.
        var audioFileName: String?
        /// The split this track was made from, when it was split first
        /// (its vocals and backing play in the Vocals/Backing modes).
        var separatedTrackID: UUID?
        /// Where the track starts inside the split's files (seconds).
        var splitOffset: Double = 0

        // Settings (SPEC section 22.1)
        var transpose: Int = 0
        var speed: Double = 1
        var difficultyRawValue: String = TrackDifficulty.medium.rawValue
        var scoresResonanceAndWeight: Bool = false
        var audioModeRawValue: String = TrackAudioMode.original.rawValue
        var loopStart: Double?
        var loopEnd: Double?

        // What was detected
        var rangeLowMidi: Double?
        var rangeHighMidi: Double?
        var tuningOffsetCents: Double?
        var hasBackgroundMusic: Bool = false
        var hasMultipleSpeakers: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \TrackSegment.track)
        var segments: [TrackSegment]? = []

        init(id: UUID = UUID(), name: String, kind: PitchTrackKind) {
            self.id = id
            self.name = name
            kindRawValue = kind.rawValue
        }

        var kind: PitchTrackKind {
            get { PitchTrackKind(rawValue: kindRawValue) ?? .speech }
            set { kindRawValue = newValue.rawValue }
        }

        var difficulty: TrackDifficulty {
            get { TrackDifficulty(rawValue: difficultyRawValue) ?? .medium }
            set { difficultyRawValue = newValue.rawValue }
        }

        var audioMode: TrackAudioMode {
            get { TrackAudioMode(rawValue: audioModeRawValue) ?? .guideTones }
            set { audioModeRawValue = newValue.rawValue }
        }
    }

    // MARK: - TrackSegment (SPEC section 22.8)

    /// One bar of a Pitch Track.
    @Model
    nonisolated final class TrackSegment {
        var id: UUID = UUID()
        var index: Int = 0
        var start: Double = 0
        var duration: Double = 0
        var pitchHz: Double = 0
        /// Semitones (MIDI, may be fractional).
        var midi: Double = 0
        var noteName: String = ""
        // Resonance target
        var f1: Double?
        var f2: Double?
        var f3: Double?
        var resonanceScore: Double?
        var weightScore: Double?
        var loudnessDb: Double?
        var word: String?
        /// The pitch line of a curved (speech) bar, JSON-encoded points.
        var contourData: Data?
        var track: PitchTrack?

        init(index: Int, start: Double, duration: Double, midi: Double) {
            self.index = index
            self.start = start
            self.duration = duration
            self.midi = midi
            pitchHz = PitchMath.frequency(forMidiNote: midi)
            noteName = PitchMath.noteName(for: pitchHz) ?? ""
        }
    }
}

/// Plans how to upgrade stored data between schema versions.
nonisolated enum VoiceBloomMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VoiceBloomSchemaV1.self, VoiceBloomSchemaV2.self, VoiceBloomSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: VoiceBloomSchemaV1.self, toVersion: VoiceBloomSchemaV2.self),
            .lightweight(fromVersion: VoiceBloomSchemaV2.self, toVersion: VoiceBloomSchemaV3.self),
        ]
    }
}

// The rest of the app refers to the current schema's models by these names.
typealias UserProfile = VoiceBloomSchemaV2.UserProfile
typealias PracticeSession = VoiceBloomSchemaV2.PracticeSession
typealias Recording = VoiceBloomSchemaV2.Recording
typealias LessonProgress = VoiceBloomSchemaV2.LessonProgress
typealias TargetVoiceProfile = VoiceBloomSchemaV2.TargetVoiceProfile
typealias ScenarioResult = VoiceBloomSchemaV2.ScenarioResult
typealias Achievement = VoiceBloomSchemaV2.Achievement
typealias DailyJournalEntry = VoiceBloomSchemaV2.DailyJournalEntry
typealias SeparatedTrack = VoiceBloomSchemaV2.SeparatedTrack
typealias PitchTrack = VoiceBloomSchemaV3.PitchTrack
typealias TrackSegment = VoiceBloomSchemaV3.TrackSegment
