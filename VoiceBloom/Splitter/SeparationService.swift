import Foundation

// MARK: - Choices

nonisolated enum SeparationEngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case highQuality
    case basic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highQuality: "High Quality"
        case .basic: "Basic"
        }
    }

    var detail: String {
        switch self {
        case .highQuality: "Machine learning on this iPhone. Works on any song, including mono."
        case .basic: "Basic quality: removes what's in the centre of a stereo mix. Best on studio songs with centred vocals; doesn't work on mono files."
        }
    }
}

nonisolated enum SeparationQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .best: "Best"
        }
    }
}

/// Which parts to keep.
nonisolated enum SplitOutputs: String, CaseIterable, Identifiable, Codable, Sendable {
    case both
    case vocals
    case backing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: "Both"
        case .vocals: "Vocals Only"
        case .backing: "Backing Only"
        }
    }

    var keepsVocals: Bool { self != .backing }
    var keepsBacking: Bool { self != .vocals }
    var stemCount: Int { self == .both ? 2 : 1 }
}

nonisolated enum SeparationSourceType: String, Codable, Sendable {
    case audio
    case video
}

nonisolated enum SeparationError: LocalizedError, Equatable, Sendable {
    case cancelled
    case monoSource
    case silentSource
    case unreadable
    case notEnoughStorage(neededMB: Int, availableMB: Int)
    case writeFailed
    case engineFailed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Splitting was cancelled."
        case .monoSource:
            "This file is mono (both channels are the same), so the Basic engine can't tell the voice from the music. Try a stereo version of the song, or the High Quality engine."
        case .silentSource:
            "This file has no sound to split."
        case .unreadable:
            "This file couldn’t be read. Try an MP3, M4A, WAV, MP4 or MOV file."
        case .notEnoughStorage(let needed, let available):
            "Not enough free space: splitting needs about \(needed) MB and \(available) MB is free. Delete some saved splits (Settings › Split Tracks Storage) or other files, then try again."
        case .writeFailed:
            "The split parts couldn’t be saved. Check that your iPhone has free space and try again."
        case .engineFailed:
            "Splitting stopped because of a processing error. Please try again."
        }
    }
}

// MARK: - Engines

/// A separation engine (SPEC section 23.1). Engines process one chunk of
/// stereo audio at a time; `ChunkedRunner` streams the file through them in
/// overlapping chunks, so any engine works with the same splitter screens.
///
/// Instances are made and used on one background task (they keep scratch
/// buffers and aren't thread-safe).
nonisolated protocol SeparationService: AnyObject {
    var kind: SeparationEngineKind { get }
    /// Seconds per chunk and overlap between chunks (crossfaded).
    var chunkDuration: Double { get }
    var overlapDuration: Double { get }
    /// Vocals and backing for one chunk, the same length as the input.
    /// Vocals + backing should add up to the input.
    func separate(_ chunk: StereoBuffer, sampleRate: Double, quality: SeparationQuality) throws -> StemPair
}

/// Picks the engine to use, falling back to Basic when High Quality isn't
/// available (SPEC section 23.1).
nonisolated enum SeparationEngineFactory {
    nonisolated struct Choice {
        let engine: any SeparationService
        /// Set when the requested engine couldn't be used.
        let fallbackReason: String?
    }

    /// Whether the High Quality engine can be offered at all.
    static var isHighQualityAvailable: Bool {
        CoreMLSeparationEngine.isModelInstalled
    }

    static var highQualityUnavailableReason: String {
        HighQualityEngineError.modelMissing.errorDescription ?? ""
    }

    /// The requested engine, or Basic with the reason when High Quality
    /// can't be used (no model, or this iPhone can't load it).
    static func make(_ preferred: SeparationEngineKind) -> Choice? {
        if preferred == .highQuality {
            do {
                return Choice(engine: try CoreMLSeparationEngine.make(), fallbackReason: nil)
            } catch {
                guard let basic = BasicSeparationEngine() else { return nil }
                let reason = (error as? LocalizedError)?.errorDescription ?? highQualityUnavailableReason
                return Choice(engine: basic, fallbackReason: reason)
            }
        }
        guard let basic = BasicSeparationEngine() else { return nil }
        return Choice(engine: basic, fallbackReason: nil)
    }
}

// MARK: - Streaming

/// Where chunked audio comes from (a decoder, or an array in tests).
nonisolated protocol StereoSampleSource: AnyObject {
    var sampleRate: Double { get }
    /// Best guess of the total length (for progress).
    var estimatedFrameCount: Int { get }
    /// Up to `maxFrames` more frames, or nil at the end.
    func read(maxFrames: Int) throws -> StereoBuffer?
}

/// Where processed audio goes (files, or memory in tests).
nonisolated protocol StereoSampleSink: AnyObject {
    /// One buffer per output, in the same order every time.
    func write(_ outputs: [StereoBuffer]) throws
    func finish() throws
    /// Throws away everything written (cancel or failure).
    func discard()
}

nonisolated struct ChunkStat: Sendable, Equatable, Codable {
    let index: Int
    /// Seconds of audio in the chunk.
    let audioSeconds: Double
    /// Seconds it took to process.
    let processingSeconds: Double
}

nonisolated struct SeparationProgress: Sendable, Equatable {
    var fraction: Double
    var elapsed: Double
    var chunk: ChunkStat?

    var remainingSeconds: Double? {
        ProgressEstimate.remainingSeconds(elapsed: elapsed, fraction: fraction)
    }
}

/// Streams a source through a chunk processor in overlapping chunks and
/// crossfades the results (SPEC section 23.1: e.g. 10 s chunks, 1 s overlap),
/// so memory stays flat however long the song is.
nonisolated enum ChunkedRunner {
    /// - Parameters:
    ///   - outputCount: How many buffers `process` returns per chunk.
    ///   - isCancelled: Checked before every chunk.
    /// - Returns: Timing for every chunk.
    @discardableResult
    static func run(
        source: any StereoSampleSource,
        chunkLength: Int,
        overlap: Int,
        outputCount: Int,
        sink: any StereoSampleSink,
        isCancelled: () -> Bool,
        progress: (SeparationProgress) -> Void,
        process: (StereoBuffer) throws -> [StereoBuffer]
    ) throws -> [ChunkStat] {
        let length = max(1, chunkLength)
        let overlap = min(max(0, overlap), length / 2)
        let step = length - overlap
        let started = Date()
        var stitchers = Array(repeating: CrossfadeStitcher(overlap: overlap), count: outputCount)
        var pending = StereoBuffer.empty
        var finishedReading = false
        var consumed = 0
        var stats: [ChunkStat] = []
        let total = max(1, source.estimatedFrameCount)

        do {
            while true {
                if isCancelled() {
                    throw SeparationError.cancelled
                }
                while !finishedReading, pending.count < length {
                    if let block = try source.read(maxFrames: length - pending.count) {
                        if block.isEmpty {
                            finishedReading = true
                        } else {
                            pending.append(block)
                        }
                    } else {
                        finishedReading = true
                    }
                }
                guard !pending.isEmpty else { break }
                let isLast = finishedReading && pending.count <= length
                let chunk = pending.prefix(length)

                let chunkStart = Date()
                let outputs = try process(chunk)
                guard outputs.count == outputCount, outputs.allSatisfy({ $0.count == chunk.count }) else {
                    throw SeparationError.engineFailed
                }
                let ready = outputs.indices.map { index in
                    stitchers[index].stitch(outputs[index], isLast: isLast)
                }
                try sink.write(ready)

                let stat = ChunkStat(
                    index: stats.count,
                    audioSeconds: Double(chunk.count) / max(source.sampleRate, 1),
                    processingSeconds: Date().timeIntervalSince(chunkStart)
                )
                stats.append(stat)
                consumed += isLast ? chunk.count : step
                progress(SeparationProgress(
                    fraction: isLast ? 1 : min(Double(consumed) / Double(total), 0.99),
                    elapsed: Date().timeIntervalSince(started),
                    chunk: stat
                ))
                if isLast {
                    break
                }
                pending.removeFirst(step)
            }
            try sink.finish()
        } catch {
            sink.discard()
            throw error
        }
        return stats
    }
}

/// A source over arrays (tests, and audio already in memory).
nonisolated final class MemoryStereoSource: StereoSampleSource {
    let sampleRate: Double
    private let buffer: StereoBuffer
    private var position = 0

    init(_ buffer: StereoBuffer, sampleRate: Double) {
        self.buffer = buffer
        self.sampleRate = sampleRate
    }

    var estimatedFrameCount: Int { buffer.count }

    func read(maxFrames: Int) throws -> StereoBuffer? {
        guard position < buffer.count else { return nil }
        let end = min(buffer.count, position + max(1, maxFrames))
        let block = StereoBuffer(left: Array(buffer.left[position..<end]), right: Array(buffer.right[position..<end]))
        position = end
        return block
    }
}

/// A sink that collects everything in memory.
nonisolated final class MemoryStereoSink: StereoSampleSink {
    private(set) var outputs: [StereoBuffer]
    private(set) var isFinished = false
    private(set) var isDiscarded = false

    init(outputCount: Int) {
        outputs = Array(repeating: .empty, count: outputCount)
    }

    func write(_ buffers: [StereoBuffer]) throws {
        for (index, buffer) in buffers.enumerated() where index < outputs.count {
            outputs[index].append(buffer)
        }
    }

    func finish() throws {
        isFinished = true
    }

    func discard() {
        outputs = outputs.map { _ in .empty }
        isDiscarded = true
    }
}
