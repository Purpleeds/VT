import Foundation
import Testing
@testable import VoiceBloom

@Suite("RecordingFileStore")
struct RecordingFileStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a", directoryHint: .notDirectory)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    @Test("A clip survives the round trip through an .m4a file")
    func roundTrip() throws {
        let sampleRate = 48_000.0
        let tone = TestSignal.sine(frequency: 220, sampleRate: sampleRate, count: 48_000, amplitude: 0.5)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try RecordingFileStore.write(AudioClip(samples: tone, sampleRate: sampleRate, startTime: 3), to: url)
        let decoded = try RecordingFileStore.readSamples(from: url)

        #expect(decoded.sampleRate == sampleRate)
        // AAC is lossy and works in blocks, so allow a little slack.
        #expect(abs(decoded.duration - 1) < 0.1)

        // Same loudness and pitch in the middle of the clip.
        let middle = decoded.samples.count / 2
        let window = 4_096
        try #require(decoded.samples.count > middle + window)
        let decodedLevel = rms(decoded.samples[middle ..< middle + window])
        let originalLevel = rms(tone[middle ..< middle + window])
        #expect(abs(decodedLevel - originalLevel) / originalLevel < 0.15)

        let configuration = AnalysisConfiguration(sampleRate: sampleRate)
        let estimate = PitchAnalyzer(configuration: configuration)
            .estimate(Array(decoded.samples[middle ..< middle + configuration.frameSize]))
        let frequency = try #require(estimate.frequency)
        #expect(abs(frequency - 220) <= 2)
    }

    @Test("An empty clip is refused")
    func emptyClip() {
        let url = temporaryURL()
        #expect(throws: RecordingFileError.self) {
            try RecordingFileStore.write(AudioClip(samples: [], sampleRate: 48_000, startTime: 0), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("File names are unique .m4a names")
    func fileNames() {
        let id = UUID()
        let name = RecordingFileStore.makeFileName(id: id)
        #expect(name == "\(id.uuidString).m4a")
        #expect(RecordingFileStore.makeFileName(id: UUID()) != name)
    }

    @Test("Recordings are kept out of iCloud and computer backups")
    func excludedFromBackup() throws {
        let folder = try RecordingFileStore.directory()
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Deleting a missing file is harmless")
    func deleteMissing() {
        RecordingFileStore.delete(fileName: "does-not-exist.m4a")
        RecordingFileStore.delete(fileName: "")
    }
}
