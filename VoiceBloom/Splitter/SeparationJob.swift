import Foundation
import SwiftData

/// What to split and how.
nonisolated struct SeparationRequest: Sendable {
    let id: UUID
    let sourceURL: URL
    let title: String
    let outputs: SplitOutputs
    let engine: SeparationEngineKind
    let quality: SeparationQuality
}

/// A finished split, ready to be saved as a `SeparatedTrack`.
nonisolated struct SeparationResult: Sendable {
    let id: UUID
    let title: String
    let sourceType: SeparationSourceType
    let engine: SeparationEngineKind
    let quality: SeparationQuality
    let sourceFileName: String?
    let vocalsFileName: String?
    let backingFileName: String?
    let duration: Double
    let sourceFileSize: Int64
    let vocalsFileSize: Int64
    let backingFileSize: Int64
    let chunkStats: [ChunkStat]
    /// Set when High Quality was requested but Basic was used.
    let fallbackReason: String?
}

/// Timing from the last split, for the debug screen (SPEC section 23.6).
nonisolated struct SeparationRunStats: Sendable, Equatable {
    let engine: SeparationEngineKind
    let chunks: [ChunkStat]
    let availableMemoryBytes: Int?

    var averageRealTimeFactor: Double? {
        let audio = chunks.reduce(0) { $0 + $1.audioSeconds }
        let processing = chunks.reduce(0) { $0 + $1.processingSeconds }
        return audio > 0 ? processing / audio : nil
    }
}

/// Runs a split in the background (call from a detached task).
nonisolated enum SeparationJob {
    /// Reads the start of the source to warn about mono or speech-only files.
    static let assessmentSeconds = 30.0

    static func run(
        _ request: SeparationRequest,
        progress: @escaping @Sendable (SeparationProgress) -> Void
    ) async throws -> SeparationResult {
        let folder = try SeparationFiles.folder(for: request.id)
        do {
            return try await perform(request, folder: folder, progress: progress)
        } catch {
            SeparationFiles.deleteFolder(for: request.id)
            throw Task.isCancelled ? SeparationError.cancelled : error
        }
    }

    private static func perform(
        _ request: SeparationRequest,
        folder: URL,
        progress: @escaping @Sendable (SeparationProgress) -> Void
    ) async throws -> SeparationResult {
        let info = try await StereoAssetReader.info(url: request.sourceURL)
        let sourceBytes = SeparationFiles.size(of: request.sourceURL)
        let duration = min(info.duration, StereoAssetReader.maximumDuration)

        // Low storage: refuse up front instead of failing halfway.
        try StorageEstimate.check(
            required: StorageEstimate.requiredBytes(duration: duration, stems: request.outputs.stemCount, sourceBytes: sourceBytes),
            available: StorageEstimate.availableBytes(at: folder)
        )

        guard let choice = SeparationEngineFactory.make(request.engine) else { throw SeparationError.engineFailed }
        let engine = choice.engine

        // The Basic engine needs a real stereo image.
        if engine.kind == .basic {
            let start = try await StereoAssetReader.readStart(of: request.sourceURL, seconds: assessmentSeconds)
            let assessment = SplitAssessment.assess(start, sampleRate: StereoAssetReader.decodeRate)
            if assessment.isSilent {
                throw SeparationError.silentSource
            }
            if assessment.isMono {
                throw SeparationError.monoSource
            }
        }
        try Task.checkCancellation()

        // Keep a copy of the original (needed to re-export videos).
        let sourceName = "source." + (request.sourceURL.pathExtension.isEmpty ? "dat" : request.sourceURL.pathExtension.lowercased())
        let sourceCopy = folder.appending(path: sourceName, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: sourceCopy)
        do {
            try FileManager.default.copyItem(at: request.sourceURL, to: sourceCopy)
        } catch {
            throw SeparationError.writeFailed
        }

        let vocalsURL = request.outputs.keepsVocals ? folder.appending(path: SeparationFiles.vocalsName, directoryHint: .notDirectory) : nil
        let backingURL = request.outputs.keepsBacking ? folder.appending(path: SeparationFiles.backingName, directoryHint: .notDirectory) : nil
        let reader = try await StereoAssetReader.open(url: sourceCopy)
        let writer = try StemFileWriter(urls: [vocalsURL, backingURL], sampleRate: reader.sampleRate)
        let sampleRate = reader.sampleRate
        let quality = request.quality
        let stats = try ChunkedRunner.run(
            source: reader,
            chunkLength: Int(engine.chunkDuration * sampleRate),
            overlap: Int(engine.overlapDuration * sampleRate),
            outputCount: 2,
            sink: writer,
            isCancelled: { Task.isCancelled },
            progress: progress
        ) { chunk in
            let pair = try engine.separate(chunk, sampleRate: sampleRate, quality: quality)
            return [pair.vocals, pair.backing]
        }

        return SeparationResult(
            id: request.id,
            title: request.title,
            sourceType: info.hasVideo ? .video : .audio,
            engine: engine.kind,
            quality: engine.kind == .highQuality ? quality : .fast,
            sourceFileName: sourceName,
            vocalsFileName: vocalsURL.map { _ in SeparationFiles.vocalsName },
            backingFileName: backingURL.map { _ in SeparationFiles.backingName },
            duration: reader.duration,
            sourceFileSize: SeparationFiles.size(of: sourceCopy),
            vocalsFileSize: vocalsURL.map { SeparationFiles.size(of: $0) } ?? 0,
            backingFileSize: backingURL.map { SeparationFiles.size(of: $0) } ?? 0,
            chunkStats: stats,
            fallbackReason: choice.fallbackReason
        )
    }

    /// Renders cleaned-up vocals (noise gate, de-reverb) to a new file.
    static func renderCleanup(from source: URL, to destination: URL, options: CleanupOptions) throws {
        let reader = try AudioFileStereoReader(url: source)
        let writer = try StemFileWriter(urls: [destination], sampleRate: reader.sampleRate)
        let sampleRate = reader.sampleRate
        let transform = SpectralTransform(fftSize: 2048, hopSize: 512)
        try ChunkedRunner.run(
            source: reader,
            chunkLength: Int(10 * sampleRate),
            overlap: Int(1 * sampleRate),
            outputCount: 1,
            sink: writer,
            isCancelled: { Task.isCancelled },
            progress: { _ in }
        ) { chunk in
            [VocalCleanup.apply(chunk, options: options, sampleRate: sampleRate, transform: transform)]
        }
    }
}

/// Saved splits (SPEC section 23.3).
@MainActor
struct SeparationStore {
    let context: ModelContext

    func tracks() -> [SeparatedTrack] {
        let descriptor = FetchDescriptor<SeparatedTrack>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func track(id: UUID) -> SeparatedTrack? {
        let wanted = id
        var descriptor = FetchDescriptor<SeparatedTrack>(predicate: #Predicate<SeparatedTrack> { $0.id == wanted })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Saves a finished split; its files are already on disk.
    func save(_ result: SeparationResult, now: Date = Date()) throws -> SeparatedTrack {
        let track = SeparatedTrack(id: result.id, title: result.title)
        track.createdAt = now
        track.sourceType = result.sourceType
        track.engine = result.engine
        track.quality = result.quality
        track.sourceFileName = result.sourceFileName
        track.vocalsFileName = result.vocalsFileName
        track.backingFileName = result.backingFileName
        track.duration = result.duration
        track.sourceFileSize = result.sourceFileSize
        track.vocalsFileSize = result.vocalsFileSize
        track.backingFileSize = result.backingFileSize
        context.insert(track)
        do {
            try context.save()
        } catch {
            context.rollback()
            SeparationFiles.deleteFolder(for: result.id)
            throw error
        }
        return track
    }

    /// Deletes a split and its files (call after leaving any screen showing it).
    func delete(_ track: SeparatedTrack) throws {
        let id = track.id
        context.delete(track)
        try context.save()
        SeparationFiles.deleteFolder(for: id)
    }

    func deleteAll() throws {
        try context.delete(model: SeparatedTrack.self)
        try context.save()
        SeparationFiles.deleteAll()
    }

    func totalBytes() -> Int64 {
        tracks().reduce(0) { $0 + $1.totalFileSize }
    }
}

extension SeparatedTrack {
    nonisolated func fileURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return try? SeparationFiles.url(for: id, name: name)
    }

    nonisolated var vocalsURL: URL? { fileURL(vocalsFileName) }
    nonisolated var backingURL: URL? { fileURL(backingFileName) }
    nonisolated var sourceURL: URL? { fileURL(sourceFileName) }
    nonisolated var cleanedVocalsURL: URL? { fileURL(SeparationFiles.cleanedVocalsName) }
}
