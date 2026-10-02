import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

// MARK: - Folders

/// Split tracks live in Application Support/Separations/<id>/: a copy of the
/// source (for video exports), vocals.m4a, backing.m4a and an optional
/// cleaned-up vocals file. Excluded from iCloud/computer backups.
nonisolated enum SeparationFiles {
    static let folderName = "Separations"
    static let vocalsName = "vocals.m4a"
    static let backingName = "backing.m4a"
    static let cleanedVocalsName = "vocals-clean.m4a"

    static func root() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = base.appending(path: folderName, directoryHint: .isDirectory)
        if !manager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
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

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// A fresh temporary folder for exports (old exports are cleared).
    static func exportsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

// MARK: - Reading

/// Decodes any audio or video file to stereo float at 44.1 kHz, a block at a
/// time (AVAssetReader), so long songs never sit in memory whole.
nonisolated final class StereoAssetReader: StereoSampleSource {
    static let decodeRate = 44_100.0
    /// Longer files are cut here.
    static let maximumDuration = 20 * 60.0

    let sampleRate = StereoAssetReader.decodeRate
    let duration: Double
    let estimatedFrameCount: Int
    let hasVideo: Bool
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private var leftover: [Float] = []

    private init(reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, duration: Double, hasVideo: Bool) {
        self.reader = reader
        self.output = output
        self.duration = duration
        self.hasVideo = hasVideo
        estimatedFrameCount = Int(duration * StereoAssetReader.decodeRate)
    }

    /// - Parameter limit: Read at most this many seconds (e.g. for a quick check).
    static func open(url: URL, limit: Double? = nil) async throws -> StereoAssetReader {
        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        let length: CMTime
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            length = try await asset.load(.duration)
        } catch {
            throw SeparationError.unreadable
        }
        guard !audioTracks.isEmpty else { throw SeparationError.silentSource }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SeparationError.unreadable
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: decodeRate,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw SeparationError.unreadable }
        reader.add(output)
        let total = length.seconds.isFinite ? max(0, length.seconds) : 0
        let readLength = min(total > 0 ? total : maximumDuration, limit ?? maximumDuration, maximumDuration)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: readLength, preferredTimescale: 600))
        guard reader.startReading() else { throw SeparationError.unreadable }
        return StereoAssetReader(reader: reader, output: output, duration: readLength, hasVideo: !videoTracks.isEmpty)
    }

    func read(maxFrames: Int) throws -> StereoBuffer? {
        let wanted = max(1, maxFrames) * 2
        while leftover.count < wanted, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            if status == kCMBlockBufferNoErr {
                leftover.append(contentsOf: chunk)
            }
        }
        if reader.status == .failed {
            throw SeparationError.unreadable
        }
        guard leftover.count >= 2 else { return nil }
        let frames = min(leftover.count / 2, max(1, maxFrames))
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = leftover[2 * frame]
            right[frame] = leftover[2 * frame + 1]
        }
        leftover.removeFirst(frames * 2)
        return StereoBuffer(left: left, right: right)
    }

    func cancel() {
        if reader.status == .reading {
            reader.cancelReading()
        }
    }

    /// Length (seconds) and whether the file has a picture.
    static func info(url: URL) async throws -> (duration: Double, hasVideo: Bool) {
        let asset = AVURLAsset(url: url)
        do {
            let length = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            return (length.seconds.isFinite ? max(0, length.seconds) : 0, !videoTracks.isEmpty)
        } catch {
            throw SeparationError.unreadable
        }
    }

    /// Reads up to `seconds` from the start of a file (for the quick checks).
    static func readStart(of url: URL, seconds: Double) async throws -> StereoBuffer {
        let reader = try await open(url: url, limit: seconds)
        var buffer = StereoBuffer.empty
        while let block = try reader.read(maxFrames: 65_536) {
            buffer.append(block)
        }
        return buffer
    }
}

/// Reads files AVAudioFile understands (the app's own .m4a/.wav files),
/// mono files as two equal channels.
nonisolated final class AudioFileStereoReader: StereoSampleSource {
    let sampleRate: Double
    let estimatedFrameCount: Int
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL, blockFrames: Int = 65_536) throws {
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SeparationError.unreadable
        }
        sampleRate = file.processingFormat.sampleRate
        estimatedFrameCount = Int(max(0, file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw SeparationError.unreadable
        }
        self.buffer = buffer
    }

    var duration: Double { sampleRate > 0 ? Double(estimatedFrameCount) / sampleRate : 0 }

    func read(maxFrames: Int) throws -> StereoBuffer? {
        guard file.framePosition < file.length else { return nil }
        let frames = AVAudioFrameCount(min(max(1, maxFrames), Int(buffer.frameCapacity)))
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw SeparationError.unreadable
        }
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return nil }
        let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        return StereoBuffer(left: left, right: right)
    }

    /// Skips `frames` frames (negative offsets in a mixdown).
    func skip(_ frames: Int) {
        file.framePosition = min(file.length, file.framePosition + AVAudioFramePosition(max(0, frames)))
    }
}

// MARK: - Writing

nonisolated enum AudioExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case m4a
    case wav

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    func settings(sampleRate: Double, channels: Int) -> [String: Any] {
        switch self {
        case .m4a:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 96_000 * channels,
            ]
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}

/// Writes one stereo file per output (nil URL = drop that output).
nonisolated final class StemFileWriter: StereoSampleSink {
    let urls: [URL?]
    private var files: [AVAudioFile?]

    init(urls: [URL?], sampleRate: Double, format: AudioExportFormat = .m4a) throws {
        self.urls = urls
        var opened: [AVAudioFile?] = []
        do {
            for url in urls {
                if let url {
                    try? FileManager.default.removeItem(at: url)
                    opened.append(try AVAudioFile(
                        forWriting: url,
                        settings: format.settings(sampleRate: sampleRate, channels: 2),
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    ))
                } else {
                    opened.append(nil)
                }
            }
        } catch {
            for url in urls.compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            throw SeparationError.writeFailed
        }
        files = opened
    }

    func write(_ outputs: [StereoBuffer]) throws {
        for (index, output) in outputs.enumerated() where index < files.count && !output.isEmpty {
            guard let file = files[index] else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(output.count)),
                  let channels = buffer.floatChannelData
            else { throw SeparationError.writeFailed }
            buffer.frameLength = AVAudioFrameCount(output.count)
            output.left.withUnsafeBufferPointer { source in
                for frame in 0..<output.count {
                    channels[0][frame] = source[frame]
                }
            }
            if file.processingFormat.channelCount > 1 {
                output.right.withUnsafeBufferPointer { source in
                    for frame in 0..<output.count {
                        channels[1][frame] = source[frame]
                    }
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw SeparationError.writeFailed
            }
        }
    }

    /// Files are completed and closed when released.
    func finish() throws {
        files = files.map { _ in nil }
    }

    func discard() {
        files = files.map { _ in nil }
        for url in urls.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Waveforms

nonisolated enum FileWaveform {
    /// Peak level per bucket, read a block at a time.
    static func peaks(url: URL, bucketCount: Int) throws -> [Float] {
        let reader = try AudioFileStereoReader(url: url)
        let total = max(1, reader.estimatedFrameCount)
        let buckets = max(1, bucketCount)
        var peaks = [Float](repeating: 0, count: buckets)
        var position = 0
        while let block = try reader.read(maxFrames: 65_536) {
            for frame in 0..<block.count {
                let bucket = min(buckets - 1, (position + frame) * buckets / total)
                let level = max(abs(block.left[frame]), abs(block.right[frame]))
                if level > peaks[bucket] {
                    peaks[bucket] = level
                }
            }
            position += block.count
        }
        return peaks
    }
}

// MARK: - Mixdown and exports

/// One file in a mixdown.
nonisolated struct MixInput: Sendable, Equatable {
    let url: URL
    let gain: Float
    /// Frames to delay this input (negative = start later in the file).
    var offsetFrames: Int = 0
}

nonisolated enum StemMixdown {
    static let blockFrames = 32_768

    /// Mixes the inputs into one stereo file, with a soft limiter so loud
    /// mixes (volumes up to 150 %) don't clip.
    static func render(
        _ inputs: [MixInput],
        to url: URL,
        format: AudioExportFormat,
        sampleRate: Double = StereoAssetReader.decodeRate,
        isCancelled: () -> Bool = { false }
    ) throws {
        let readers = try inputs.map { input -> AudioFileStereoReader in
            let reader = try AudioFileStereoReader(url: input.url)
            if input.offsetFrames < 0 {
                reader.skip(-input.offsetFrames)
            }
            return reader
        }
        var delays = inputs.map { max(0, $0.offsetFrames) }
        var finished = Array(repeating: false, count: readers.count)
        let writer = try StemFileWriter(urls: [url], sampleRate: sampleRate, format: format)
        do {
            while true {
                if isCancelled() {
                    throw SeparationError.cancelled
                }
                var mixed = StereoBuffer(
                    left: [Float](repeating: 0, count: blockFrames),
                    right: [Float](repeating: 0, count: blockFrames)
                )
                var produced = 0
                for index in readers.indices where !finished[index] {
                    // Leading silence for delayed inputs.
                    var offset = 0
                    if delays[index] > 0 {
                        offset = min(delays[index], blockFrames)
                        delays[index] -= offset
                        produced = max(produced, offset)
                    }
                    guard offset < blockFrames else { continue }
                    guard let block = try readers[index].read(maxFrames: blockFrames - offset) else {
                        finished[index] = true
                        continue
                    }
                    let gain = inputs[index].gain
                    for frame in 0..<block.count {
                        mixed.left[offset + frame] += block.left[frame] * gain
                        mixed.right[offset + frame] += block.right[frame] * gain
                    }
                    produced = max(produced, offset + block.count)
                }
                // Every input has run out.
                guard produced > 0 else { break }
                let out = mixed.prefix(produced)
                try writer.write([StereoBuffer(left: out.left.map(softLimit), right: out.right.map(softLimit))])
            }
            try writer.finish()
        } catch {
            writer.discard()
            throw error
        }
    }

    /// Linear up to 0.9, then bends smoothly toward 1.
    static func softLimit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > 0.9 else { return sample }
        let limited = 0.9 + 0.1 * tanh((magnitude - 0.9) / 0.1)
        return sample < 0 ? -limited : limited
    }
}

/// Replaces a video's soundtrack, keeping the picture untouched
/// (SPEC section 23.3: AVMutableComposition + AVAssetExportSession).
nonisolated enum VideoAudioReplacer {
    static func export(video: URL, audio: URL, to destination: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        do {
            let duration = try await videoAsset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw SeparationError.unreadable }
            try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

            if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioDuration = try await audioAsset.load(.duration)
                let audioRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration))
                try compositionAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
            }
        } catch let error as SeparationError {
            throw error
        } catch {
            throw SeparationError.unreadable
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw SeparationError.writeFailed
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            throw SeparationError.writeFailed
        }
    }
}
