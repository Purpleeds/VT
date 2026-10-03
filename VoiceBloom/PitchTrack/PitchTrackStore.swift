import Foundation
import SwiftData

/// Pitch Track audio lives in Application Support/PitchTracks/<id>/ (the
/// trimmed original clip). Excluded from iCloud/computer backups.
nonisolated enum PitchTrackFiles {
    static let folderName = "PitchTracks"
    static let audioName = "original.m4a"

    static func root() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = base.appending(path: folderName, directoryHint: .isDirectory)
        if !manager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try manager.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
        return folder
    }

    static func folder(for id: UUID) throws -> URL {
        let folder = try root().appending(path: id.uuidString, directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func url(for id: UUID, name: String) throws -> URL {
        try folder(for: id).appending(path: name, directoryHint: .notDirectory)
    }

    static func deleteFolder(for id: UUID) {
        guard let root = try? root() else { return }
        try? FileManager.default.removeItem(at: root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    static func deleteAll() {
        guard let root = try? root() else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Where a track's sound comes from.
nonisolated struct TrackAudioSources: Sendable, Equatable {
    /// The trimmed original clip (mono).
    var original: URL?
    /// The split's parts, when the track was split first.
    var vocals: URL?
    var backing: URL?
    /// Where the track starts inside the split's files (seconds).
    var splitOffset: Double

    static let none = TrackAudioSources(original: nil, vocals: nil, backing: nil, splitOffset: 0)

    var hasSplit: Bool { vocals != nil && backing != nil }

    var availableModes: [TrackAudioMode] {
        TrackAudioMode.available(hasOriginalAudio: original != nil, hasSplit: hasSplit)
    }
}

/// Reads and writes Pitch Tracks (SPEC section 22.8).
@MainActor
struct PitchTrackStore {
    let context: ModelContext

    func allTracks() -> [PitchTrack] {
        let descriptor = FetchDescriptor<PitchTrack>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func track(id: UUID) -> PitchTrack? {
        let wanted = id
        var descriptor = FetchDescriptor<PitchTrack>(predicate: #Predicate { $0.id == wanted })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Saves a new track. The audio is written first; if saving the track
    /// fails, the audio is deleted again.
    func save(
        name: String,
        content: PitchTrackContent,
        detectedKind: PitchTrackKind?,
        settings: TrackSettings,
        audio: AudioClip?,
        separatedTrackID: UUID?,
        splitOffset: Double,
        hasBackgroundMusic: Bool,
        hasMultipleSpeakers: Bool
    ) async throws -> PitchTrack {
        let id = UUID()
        var audioFileName: String?
        if let audio, !audio.samples.isEmpty {
            let destination = try PitchTrackFiles.url(for: id, name: PitchTrackFiles.audioName)
            try await Task.detached(priority: .userInitiated) {
                try RecordingFileStore.write(audio, to: destination)
            }.value
            audioFileName = PitchTrackFiles.audioName
        }

        let track = PitchTrack(id: id, name: Self.cleanName(name), kind: content.kind == .builtIn ? .speech : content.kind)
        track.detectedKindRawValue = detectedKind?.rawValue
        track.duration = content.duration
        track.audioFileName = audioFileName
        track.separatedTrackID = separatedTrackID
        track.splitOffset = splitOffset
        track.tuningOffsetCents = content.tuningOffsetCents
        track.rangeLowMidi = content.range?.lowerBound
        track.rangeHighMidi = content.range?.upperBound
        track.hasBackgroundMusic = hasBackgroundMusic
        track.hasMultipleSpeakers = hasMultipleSpeakers
        Self.apply(settings, to: track)
        context.insert(track)
        for bar in content.bars {
            let segment = Self.segment(from: bar)
            context.insert(segment)
            segment.track = track
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            PitchTrackFiles.deleteFolder(for: id)
            throw error
        }
        return track
    }

    func update(_ track: PitchTrack, settings: TrackSettings) throws {
        Self.apply(settings, to: track)
        try context.save()
    }

    func rename(_ track: PitchTrack, to name: String) throws {
        let cleaned = Self.cleanName(name)
        guard cleaned != track.name else { return }
        track.name = cleaned
        try context.save()
    }

    func markPlayed(_ track: PitchTrack, at date: Date = Date()) {
        track.lastPlayedAt = date
        try? context.save()
    }

    /// Deletes the track, its bars and its audio. Callers dismiss any screen
    /// showing the track first.
    func delete(_ track: PitchTrack) throws {
        let id = track.id
        context.delete(track)
        try context.save()
        PitchTrackFiles.deleteFolder(for: id)
    }

    func deleteAll() throws {
        try context.delete(model: TrackSegment.self)
        try context.delete(model: PitchTrack.self)
        try context.save()
        PitchTrackFiles.deleteAll()
    }

    /// The files the track can play.
    func audioSources(for track: PitchTrack) -> TrackAudioSources {
        var sources = TrackAudioSources.none
        if let name = track.audioFileName, let url = try? PitchTrackFiles.url(for: track.id, name: name),
           FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            sources.original = url
        }
        if let splitID = track.separatedTrackID, let split = SeparationStore(context: context).track(id: splitID) {
            sources.vocals = split.vocalsURL
            sources.backing = split.backingURL
            sources.splitOffset = track.splitOffset
        }
        return sources
    }

    // MARK: Conversions

    static func content(of track: PitchTrack) -> PitchTrackContent {
        let bars = (track.segments ?? [])
            .sorted { $0.index < $1.index }
            .enumerated()
            .map { position, segment in bar(from: segment, index: position) }
        return PitchTrackContent(kind: track.kind, duration: track.duration, bars: bars, tuningOffsetCents: track.tuningOffsetCents)
    }

    static func settings(of track: PitchTrack) -> TrackSettings {
        var loop: TrackLoop?
        if let start = track.loopStart, let end = track.loopEnd {
            loop = TrackLoop(start: start, end: end, trackDuration: track.duration)
        }
        return TrackSettings(
            transpose: track.transpose,
            speed: track.speed,
            loop: loop,
            difficulty: track.difficulty,
            scoresResonanceAndWeight: track.scoresResonanceAndWeight,
            audioMode: track.audioMode
        )
    }

    static func apply(_ settings: TrackSettings, to track: PitchTrack) {
        track.transpose = settings.transpose
        track.speed = settings.speed
        track.difficulty = settings.difficulty
        track.scoresResonanceAndWeight = settings.scoresResonanceAndWeight
        track.audioMode = settings.audioMode
        track.loopStart = settings.loop?.start
        track.loopEnd = settings.loop?.end
    }

    static func segment(from bar: TrackBar) -> TrackSegment {
        let segment = TrackSegment(index: bar.index, start: bar.start, duration: bar.duration, midi: bar.midi)
        segment.f1 = bar.resonance?.f1
        segment.f2 = bar.resonance?.f2
        segment.f3 = bar.resonance?.f3
        segment.resonanceScore = bar.resonance?.score
        segment.weightScore = bar.weightScore
        segment.loudnessDb = bar.loudnessDb
        segment.word = bar.word
        if bar.isCurved {
            segment.contourData = try? JSONEncoder().encode(bar.contour)
        }
        return segment
    }

    static func bar(from segment: TrackSegment, index: Int) -> TrackBar {
        let contour = segment.contourData.flatMap { try? JSONDecoder().decode([TrackContourPoint].self, from: $0) } ?? []
        var resonance: BarResonance?
        if segment.f1 != nil || segment.f2 != nil || segment.f3 != nil || segment.resonanceScore != nil {
            resonance = BarResonance(f1: segment.f1, f2: segment.f2, f3: segment.f3, score: segment.resonanceScore)
        }
        return TrackBar(
            index: index,
            start: segment.start,
            duration: segment.duration,
            midi: segment.midi,
            contour: contour,
            resonance: resonance,
            weightScore: segment.weightScore,
            loudnessDb: segment.loudnessDb,
            word: segment.word
        )
    }

    /// A tidy track name (file names often carry extensions or underscores).
    static func cleanName(_ name: String) -> String {
        let trimmed = name
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "My Track" }
        return String(trimmed.prefix(60))
    }
}

/// Settings for the built-in tracks (they aren't stored in SwiftData).
nonisolated enum BuiltInTrackSettingsStore {
    static func key(for track: BuiltInTrack) -> String {
        "pitchTrack.builtIn.\(track.rawValue)"
    }

    static func load(_ track: BuiltInTrack) -> TrackSettings {
        if let data = UserDefaults.standard.data(forKey: key(for: track)),
           let saved = try? JSONDecoder().decode(TrackSettings.self, from: data) {
            return saved
        }
        return TrackSettings.defaults(kind: .builtIn, hasOriginalAudio: false, hasSplit: false, isSpeechPattern: track.isSpeechPattern)
    }

    static func save(_ settings: TrackSettings, for track: BuiltInTrack) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key(for: track))
        }
    }
}

/// Debug switches for Pitch Track (SPEC section 22.9).
nonisolated enum PitchTrackDebug {
    static let perfectVoiceKey = "pitchTrack.simulatePerfectVoice"

    /// Plays tracks with a simulated perfect voice instead of the microphone.
    static var simulatesPerfectVoice: Bool {
        UserDefaults.standard.bool(forKey: perfectVoiceKey)
    }
}
