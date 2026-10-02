import Foundation
import SwiftData

extension TargetVoiceProfile {
    /// Copies the measured voice into the profile.
    nonisolated func apply(_ take: TakeResult) {
        averagePitch = take.medianPitch
        minimumPitch = take.lowPitch
        maximumPitch = take.highPitch
        pitchHistogram = take.pitchHistogram
        histogramLowerBound = TakeResult.histogramLowerBound
        histogramBinSemitones = 1
        averageF1 = take.f1
        averageF2 = take.f2
        averageF3 = take.f3
        h1MinusH2 = take.h1MinusH2
        spectralTilt = take.spectralTilt
        intonationSD = take.intonationSD
    }

    nonisolated var snapshot: VoiceSnapshot {
        VoiceSnapshot(
            pitchHistogram: pitchHistogram,
            medianPitch: averagePitch,
            f1: averageF1,
            f2: averageF2,
            f3: averageF3,
            h1MinusH2: h1MinusH2,
            intonationSD: intonationSD
        )
    }

    nonisolated var suggestion: TargetSuggestion {
        TargetSuggestion(medianPitch: averagePitch, f2: averageF2, f3: averageF3, h1MinusH2: h1MinusH2, intonationSD: intonationSD)
    }

    /// Lightness of the voice (0–100) on the default weight scale.
    nonisolated var weightScore: Double? {
        h1MinusH2.map { WeightReference.standard.score(h1MinusH2: $0, spectralTilt: spectralTilt) }
    }

    nonisolated var clipFileURL: URL? {
        sourceClipFileName.flatMap { try? RecordingFileStore.url(for: $0) }
    }
}

extension TargetSuggestion {
    /// Writes the suggested targets into the user's profile. They stay
    /// editable in Settings (manual override).
    nonisolated func apply(to user: UserProfile) {
        if let pitchZone {
            user.goalType = .custom
            user.targetZone = pitchZone
        }
        if let f2 { user.targetF2 = f2 }
        if let f3 { user.targetF3 = f3 }
        if let h1MinusH2 { user.targetH1MinusH2 = h1MinusH2 }
        if let intonationSD { user.targetIntonationSD = intonationSD }
    }
}

/// Saved target voices (SPEC section 9: save multiple profiles and switch
/// between them).
@MainActor
struct TargetVoiceStore {
    let context: ModelContext

    /// All profiles, oldest first.
    func profiles() -> [TargetVoiceProfile] {
        (try? context.fetch(FetchDescriptor<TargetVoiceProfile>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Saves the analyzed section as a new profile, with its audio for
    /// shadowing.
    @discardableResult
    func save(
        name: String,
        report: TargetClipReport,
        clip: AudioClip,
        range: ClosedRange<Double>,
        separatedTrack: SeparatedTrack? = nil,
        now: Date = Date()
    ) async throws -> TargetVoiceProfile {
        let section = TargetClipAnalyzer.section(of: clip, range: range)
        let file = try await SavedAudioFile.writeIfPresent(section)
        do {
            let profile = TargetVoiceProfile(name: TargetVoiceStore.cleanName(name, existing: profiles().count))
            context.insert(profile)
            profile.createdAt = now
            profile.apply(report.take)
            profile.sourceClipFileName = file?.fileName
            profile.clipStart = range.lowerBound
            profile.clipEnd = range.upperBound
            profile.separatedTrack = separatedTrack
            try context.save()
            return profile
        } catch {
            context.rollback()
            if let file {
                RecordingFileStore.delete(fileName: file.fileName)
            }
            throw error
        }
    }

    /// A trimmed name, or "Target voice N" when it's empty.
    static func cleanName(_ name: String, existing: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Target voice \(existing + 1)" : String(trimmed.prefix(60))
    }

    func rename(_ profile: TargetVoiceProfile, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.name = String(trimmed.prefix(60))
        try context.save()
    }

    /// Makes this the active target; with `applyTargets`, the user's pitch,
    /// resonance, weight and intonation targets are set from it.
    func activate(_ profile: TargetVoiceProfile, for user: UserProfile, applyTargets: Bool) throws {
        for other in profiles() {
            other.isActive = other.id == profile.id
        }
        user.activeTargetVoiceProfileID = profile.id
        if applyTargets {
            profile.suggestion.apply(to: user)
        }
        try context.save()
    }

    /// No active target (the user's targets stay as they are).
    func deactivate(for user: UserProfile) throws {
        for profile in profiles() {
            profile.isActive = false
        }
        user.activeTargetVoiceProfileID = nil
        try context.save()
    }

    /// Deletes the profile and its audio.
    func delete(_ profile: TargetVoiceProfile, user: UserProfile?) throws {
        let fileName = profile.sourceClipFileName
        if let user, user.activeTargetVoiceProfileID == profile.id {
            user.activeTargetVoiceProfileID = nil
        }
        context.delete(profile)
        try context.save()
        if let fileName {
            RecordingFileStore.delete(fileName: fileName)
        }
    }
}
