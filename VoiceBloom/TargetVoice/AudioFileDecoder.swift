import AVFoundation
import CoreMedia
import Foundation

nonisolated enum TargetImportError: LocalizedError, Sendable, Equatable {
    case noAudio
    case unreadable
    case tooShort
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .noAudio: "This file has no sound to analyze."
        case .unreadable: "This file couldn’t be read. Try an MP3, M4A, WAV, MP4 or MOV file."
        case .tooShort: "This clip is too short. Choose at least a few seconds of someone speaking."
        case .copyFailed: "The file couldn’t be opened. Please try again."
        }
    }
}

/// An imported clip, decoded to mono.
nonisolated struct DecodedClip: Sendable, Equatable {
    let audio: AudioClip
    /// Length of the original file (it may be longer than what was loaded).
    let originalDuration: Double

    var wasShortened: Bool { originalDuration > audio.duration + 0.5 }
}

/// Reads the sound from audio and video files (SPEC section 9: extract audio
/// from videos with AVAssetReader).
nonisolated enum AudioFileDecoder {
    /// Only this much of a long file is loaded (the trim picks 10–60 s).
    static let maximumDuration = 180.0
    static let minimumDuration = 2.0

    /// Decodes on a background thread.
    static func decodeInBackground(url: URL) async throws -> DecodedClip {
        try await Task.detached(priority: .userInitiated) {
            try await decode(url: url)
        }.value
    }

    /// Mixes all audio tracks to mono at `TargetClipAnalyzer.sampleRate`.
    static func decode(url: URL, sampleRate: Double = TargetClipAnalyzer.sampleRate) async throws -> DecodedClip {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw TargetImportError.unreadable
        }
        guard !tracks.isEmpty else { throw TargetImportError.noAudio }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TargetImportError.unreadable
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw TargetImportError.unreadable }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maximumDuration, preferredTimescale: 600))
        guard reader.startReading() else { throw TargetImportError.unreadable }

        let limit = Int(maximumDuration * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(min(limit, Int(max(0, duration.seconds.isFinite ? duration.seconds : 0) * sampleRate) + 1))
        while samples.count < limit, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            samples.append(contentsOf: chunk.prefix(limit - samples.count))
        }
        if reader.status == .reading {
            reader.cancelReading()
        }
        if reader.status == .failed {
            throw TargetImportError.unreadable
        }

        let audio = AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
        guard audio.duration >= minimumDuration else {
            throw samples.isEmpty ? TargetImportError.noAudio : TargetImportError.tooShort
        }
        let original = duration.seconds.isFinite ? duration.seconds : audio.duration
        return DecodedClip(audio: audio, originalDuration: max(original, audio.duration))
    }
}

/// Temporary copies of picked files (the originals may only be readable
/// briefly, or be inside another app's storage).
nonisolated enum TargetImportFiles {
    static func temporaryURL(pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "TargetImport-\(UUID().uuidString)", directoryHint: .notDirectory)
            .appendingPathExtension(pathExtension.isEmpty ? "dat" : pathExtension)
    }

    /// Copies a file picked in Files (a security-scoped URL).
    static func copyPickedFile(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try copy(url)
    }

    static func copy(_ url: URL) throws -> URL {
        let destination = temporaryURL(pathExtension: url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw TargetImportError.copyFailed
        }
        return destination
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
