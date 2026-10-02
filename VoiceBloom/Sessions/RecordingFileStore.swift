import AVFoundation
import Foundation

nonisolated enum RecordingFileError: LocalizedError, Sendable {
    case emptyAudio
    case cannotCreateBuffer

    var errorDescription: String? {
        switch self {
        case .emptyAudio: "There’s no audio to save yet."
        case .cannotCreateBuffer: "The recording couldn’t be prepared."
        }
    }
}

/// Audio files for recordings, kept in Application Support/Recordings.
///
/// The folder is excluded from iCloud/iTunes backups and files are encrypted
/// whenever the device is locked: recordings never leave the phone.
nonisolated enum RecordingFileStore {
    static let folderName = "Recordings"

    static func directory() throws -> URL {
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

    static func url(for fileName: String) throws -> URL {
        try directory().appending(path: fileName, directoryHint: .notDirectory)
    }

    static func makeFileName(id: UUID) -> String {
        "\(id.uuidString).m4a"
    }

    /// Encodes mono samples as AAC (.m4a), about 0.5 MB per minute.
    static func write(_ clip: AudioClip, to url: URL) throws {
        guard !clip.samples.isEmpty else { throw RecordingFileError.emptyAudio }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw RecordingFileError.cannotCreateBuffer }

        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        for (index, sample) in clip.samples.enumerated() {
            channel[index] = sample
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        // The file is finished and closed when `file` goes out of scope.
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Writes a clip into the Recordings folder.
    static func write(_ clip: AudioClip, fileName: String) throws {
        let destination = try url(for: fileName)
        try write(clip, to: destination)
    }

    /// Reads a recording back as mono samples (used for re-analysis and tests).
    static func readSamples(from url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(max(0, file.length))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw RecordingFileError.emptyAudio }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw RecordingFileError.cannotCreateBuffer }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioClip(samples: samples, sampleRate: file.processingFormat.sampleRate, startTime: 0)
    }

    static func delete(fileName: String) {
        guard !fileName.isEmpty, let fileURL = try? url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
