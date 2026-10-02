import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

/// Amplitude of the `frequency` component (Hann-windowed single DFT bin).
private func amplitude(_ signal: [Float], frequency: Double, sampleRate: Double) -> Double {
    var real = 0.0
    var imag = 0.0
    var windowSum = 0.0
    let count = signal.count
    for index in 0..<count {
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        real += Double(signal[index]) * window * cos(phase)
        imag -= Double(signal[index]) * window * sin(phase)
        windowSum += window
    }
    return 2 * (real * real + imag * imag).squareRoot() / windowSum
}

private func decibels(_ value: Double, _ reference: Double) -> Double {
    20 * log10(max(value, 1e-12) / max(reference, 1e-12))
}

private func sine(_ frequency: Double, amplitude: Double, count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

private func rms(_ signal: ArraySlice<Float>) -> Double {
    guard !signal.isEmpty else { return 0 }
    return (signal.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(signal.count)).squareRoot()
}

@Suite("Splitter: STFT and the Basic engine")
struct BasicSeparationTests {
    private let rate = 44_100.0

    @Test("The STFT gives back exactly what it was given")
    func roundTrip() throws {
        let transform = try #require(SpectralTransform(fftSize: 2048, hopSize: 512))
        let signal = TestSignal.noise(count: 10_000, amplitude: 0.5)
        let spectrum = transform.forward(signal)
        #expect(spectrum.frames == 10_000 / 512 + 1)
        let back = transform.inverse(spectrum, length: signal.count)
        let error = zip(signal, back).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-4)
        #expect(SpectralTransform(fftSize: 1000) == nil)
    }

    @Test("Center cancellation removes the centred voice and keeps panned instruments and bass")
    func centredToneIsRemoved() throws {
        let count = Int(rate * 2)
        let centre = sine(440, amplitude: 0.3, count: count, sampleRate: rate)
        let leftOnly = sine(300, amplitude: 0.2, count: count, sampleRate: rate)
        let rightOnly = sine(700, amplitude: 0.2, count: count, sampleRate: rate)
        let bass = sine(55, amplitude: 0.3, count: count, sampleRate: rate)
        let left = zip(zip(centre, leftOnly), bass).map { $0.0 + $0.1 + $1 }
        let right = zip(zip(centre, rightOnly), bass).map { $0.0 + $0.1 + $1 }
        let input = StereoBuffer(left: left, right: right)

        let engine = try #require(BasicSeparationEngine())
        let pair = try engine.separate(input, sampleRate: rate, quality: .fast)
        #expect(pair.vocals.count == count)
        #expect(pair.backing.count == count)

        let middle = Int(rate / 2)..<Int(rate * 1.5)
        let backingLeft = Array(pair.backing.left[middle])
        let backingRight = Array(pair.backing.right[middle])
        let inputLeft = Array(left[middle])
        let inputRight = Array(right[middle])
        let vocals = Array(pair.vocals.left[middle])

        // The backing strongly reduces the centred tone (SPEC section 23.6).
        #expect(decibels(amplitude(backingLeft, frequency: 440, sampleRate: rate), amplitude(inputLeft, frequency: 440, sampleRate: rate)) < -20)
        // Side-panned tones and the bass stay in the backing.
        #expect(abs(decibels(amplitude(backingLeft, frequency: 300, sampleRate: rate), amplitude(inputLeft, frequency: 300, sampleRate: rate))) < 1)
        #expect(abs(decibels(amplitude(backingRight, frequency: 700, sampleRate: rate), amplitude(inputRight, frequency: 700, sampleRate: rate))) < 1)
        #expect(abs(decibels(amplitude(backingLeft, frequency: 55, sampleRate: rate), amplitude(inputLeft, frequency: 55, sampleRate: rate))) < 1)
        // The vocals hold the centred tone and not the panned one.
        #expect(abs(decibels(amplitude(vocals, frequency: 440, sampleRate: rate), 0.3)) < 1)
        #expect(decibels(amplitude(vocals, frequency: 300, sampleRate: rate), 0.2) < -30)

        // Vocals + backing add back up to the original.
        let rebuilt = zip(pair.vocals.left, pair.backing.left).map { $0 + $1 }
        let error = zip(rebuilt, left).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-4)
    }

    @Test("The vocal band runs from about 100 Hz to 8 kHz")
    func band() {
        #expect(BasicSeparationEngine.bandWeight(frequency: 50) == 0)
        #expect(abs(BasicSeparationEngine.bandWeight(frequency: 100) - 0.5) < 1e-9)
        #expect(BasicSeparationEngine.bandWeight(frequency: 1_000) == 1)
        #expect(abs(BasicSeparationEngine.bandWeight(frequency: 8_000) - 0.5) < 1e-9)
        #expect(BasicSeparationEngine.bandWeight(frequency: 9_500) == 0)
    }
}

@Suite("Splitter: source checks")
struct SplitAssessmentTests {
    private let rate = 44_100.0

    @Test("Identical channels are mono")
    func mono() {
        let tone = sine(220, amplitude: 0.3, count: Int(rate), sampleRate: rate)
        let assessment = SplitAssessment.assess(StereoBuffer(mono: tone), sampleRate: rate)
        #expect(assessment.isMono)
        #expect(!assessment.isSilent)
    }

    @Test("A stereo mix isn't mono or speech")
    func stereoMusic() {
        let count = Int(rate * 2)
        let centre = sine(440, amplitude: 0.3, count: count, sampleRate: rate)
        let left = zip(centre, sine(300, amplitude: 0.2, count: count, sampleRate: rate)).map { $0 + $1 }
        let right = zip(centre, sine(500, amplitude: 0.2, count: count, sampleRate: rate)).map { $0 + $1 }
        let assessment = SplitAssessment.assess(StereoBuffer(left: left, right: right), sampleRate: rate)
        #expect(!assessment.isMono)
        #expect(!assessment.isLikelySpeechOnly)
        #expect(assessment.pauseShare < 0.05)
    }

    @Test("Phrases with pauses in mono sound like plain speech")
    func speech() {
        let count = Int(rate * 3)
        let tone = sine(180, amplitude: 0.3, count: count, sampleRate: rate)
        let noise = TestSignal.noise(count: count, amplitude: 0.0005)
        let phrases = (0..<count).map { index -> Float in
            let time = Double(index) / rate
            let talking = time.truncatingRemainder(dividingBy: 1) < 0.7
            return (talking ? tone[index] : 0) + noise[index]
        }
        let assessment = SplitAssessment.assess(StereoBuffer(mono: phrases), sampleRate: rate)
        #expect(assessment.isLikelySpeechOnly)
    }

    @Test("Silence is reported")
    func silence() {
        let assessment = SplitAssessment.assess(StereoBuffer(mono: TestSignal.silence(count: 44_100)), sampleRate: rate)
        #expect(assessment.isSilent)
        #expect(!assessment.isLikelySpeechOnly)
        #expect(SplitAssessment.assess(.empty, sampleRate: rate).isSilent)
    }
}

@Suite("Splitter: chunks, crossfades, cancel and storage")
struct ChunkedRunnerTests {
    private let rate = 44_100.0

    @discardableResult
    private func run(
        _ input: StereoBuffer,
        chunk: Int,
        overlap: Int,
        sink: MemoryStereoSink,
        isCancelled: () -> Bool = { false },
        process: (StereoBuffer) throws -> [StereoBuffer]
    ) throws -> [ChunkStat] {
        try ChunkedRunner.run(
            source: MemoryStereoSource(input, sampleRate: rate),
            chunkLength: chunk,
            overlap: overlap,
            outputCount: 1,
            sink: sink,
            isCancelled: isCancelled,
            progress: { _ in },
            process: process
        )
    }

    @Test("Unchanged chunks stitch back into the exact input")
    func identity() throws {
        let input = StereoBuffer(left: TestSignal.noise(count: 5_050, amplitude: 0.5, seed: 1), right: TestSignal.noise(count: 5_050, amplitude: 0.5, seed: 2))
        let sink = MemoryStereoSink(outputCount: 1)
        let stats = try run(input, chunk: 1_000, overlap: 100, sink: sink) { [$0] }
        let output = sink.outputs[0]
        #expect(output.count == input.count)
        let error = zip(output.left, input.left).map { abs($0 - $1) }.max() ?? 1
        let errorRight = zip(output.right, input.right).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-6)
        #expect(errorRight < 1e-6)
        #expect(stats.count == 6)
        #expect(sink.isFinished)
    }

    /// Largest jump between neighbouring samples.
    private func largestStep(_ signal: [Float]) -> Float {
        zip(signal.dropFirst(), signal).map { abs($0 - $1) }.max() ?? 0
    }

    @Test("Crossfades leave no clicks at chunk boundaries")
    func noClicks() throws {
        let input = StereoBuffer(mono: sine(100, amplitude: 0.5, count: 40_000, sampleRate: rate))
        // Each chunk comes back at a different level, like a model would.
        func alternating() -> (StereoBuffer) throws -> [StereoBuffer] {
            var index = 0
            return { chunk in
                defer { index += 1 }
                return [chunk.scaled(by: index.isMultiple(of: 2) ? 1 : 0.6)]
            }
        }
        let natural = largestStep(input.left)

        let faded = MemoryStereoSink(outputCount: 1)
        try run(input, chunk: 4_000, overlap: 441, sink: faded, process: alternating())
        #expect(largestStep(faded.outputs[0].left) < natural * 1.5)

        // Without overlap the same level changes click.
        let cut = MemoryStereoSink(outputCount: 1)
        try run(input, chunk: 4_000, overlap: 0, sink: cut, process: alternating())
        #expect(largestStep(cut.outputs[0].left) > natural * 3)
    }

    @Test("Cancelling stops and throws everything away")
    func cancel() {
        let input = StereoBuffer(mono: TestSignal.noise(count: 10_000))
        let sink = MemoryStereoSink(outputCount: 1)
        var chunks = 0
        var thrown: SeparationError?
        do {
            try run(input, chunk: 1_000, overlap: 100, sink: sink, isCancelled: { chunks >= 2 }) { chunk in
                chunks += 1
                return [chunk]
            }
        } catch let error as SeparationError {
            thrown = error
        } catch {}
        #expect(thrown == .cancelled)
        #expect(chunks == 2)
        #expect(sink.isDiscarded)
        #expect(sink.outputs[0].isEmpty)
    }

    @Test("A failing engine discards partial output")
    func failure() {
        let sink = MemoryStereoSink(outputCount: 1)
        var thrown: SeparationError?
        do {
            try run(StereoBuffer(mono: TestSignal.noise(count: 3_000)), chunk: 1_000, overlap: 100, sink: sink) { chunk in
                [chunk.prefix(chunk.count - 1)]
            }
        } catch let error as SeparationError {
            thrown = error
        } catch {}
        #expect(thrown == .engineFailed)
        #expect(sink.isDiscarded)
    }

    @Test("An empty source finishes with nothing")
    func empty() throws {
        let sink = MemoryStereoSink(outputCount: 1)
        let stats = try run(.empty, chunk: 1_000, overlap: 100, sink: sink) { [$0] }
        #expect(stats.isEmpty)
        #expect(sink.isFinished)
    }

    @Test("Low storage is refused before splitting")
    func storage() {
        let required = StorageEstimate.requiredBytes(duration: 100, stems: 2, sourceBytes: 1_000_000)
        #expect(abs(required - (5_760_000 + 1_000_000 + StorageEstimate.headroomBytes)) <= 1)
        #expect(throws: SeparationError.notEnoughStorage(neededMB: 57, availableMB: 10)) {
            try StorageEstimate.check(required: required, available: 10_000_000)
        }
        #expect(throws: Never.self) {
            try StorageEstimate.check(required: required, available: 1_000_000_000)
        }
        #expect(throws: Never.self) {
            try StorageEstimate.check(required: required, available: nil)
        }
    }

    @Test("Progress estimates the time left")
    func progress() {
        #expect(ProgressEstimate.remainingSeconds(elapsed: 10, fraction: 0.25) == 30)
        #expect(ProgressEstimate.remainingSeconds(elapsed: 1, fraction: 0.01) == nil)
        #expect(ProgressEstimate.remainingSeconds(elapsed: 5, fraction: 1) == 0)
        #expect(ProgressEstimate.text(remaining: 30) == "Less than a minute left")
        #expect(ProgressEstimate.text(remaining: 130) == "About 3 min left")
        #expect(ProgressEstimate.text(remaining: nil) == "Estimating time left…")
    }
}

@Suite("Splitter: vocal clean-up")
struct VocalCleanupTests {
    private let rate = 44_100.0

    @Test("The noise gate quiets the gaps and leaves the voice alone")
    func gate() {
        let count = Int(rate * 2)
        let noise = TestSignal.noise(count: count, amplitude: 0.005)
        let signal = (0..<count).map { index -> Float in
            let time = Double(index) / rate
            let voiced = (time > 0.3 && time < 0.8) || (time > 1.2 && time < 1.6)
            return (voiced ? Float(0.3 * sin(2 * Double.pi * 220 * time)) : 0) + noise[index]
        }
        let output = VocalCleanup.apply(StereoBuffer(mono: signal), options: CleanupOptions(noiseGate: true), sampleRate: rate, transform: nil).left
        let gap = Int(1.0 * rate)..<Int(1.15 * rate)
        let voiced = Int(0.4 * rate)..<Int(0.7 * rate)
        #expect(decibels(rms(output[gap]), rms(signal[gap])) < -10)
        #expect(abs(decibels(rms(output[voiced]), rms(signal[voiced]))) < 0.5)
    }

    @Test("De-reverb shortens a decaying tail more than the steady note")
    func deReverb() throws {
        let transform = try #require(SpectralTransform(fftSize: 2048, hopSize: 512))
        let count = Int(rate * 2)
        let signal = (0..<count).map { index -> Float in
            let time = Double(index) / rate
            guard time > 0.1 else { return 0 }
            let envelope = time < 0.6 ? 1 : exp(-6.9 * (time - 0.6) / 0.5)
            return Float(0.3 * sin(2 * Double.pi * 300 * time) * envelope)
        }
        let output = VocalCleanup.apply(StereoBuffer(mono: signal), options: CleanupOptions(deReverb: true), sampleRate: rate, transform: transform).left
        let steady = Int(0.3 * rate)..<Int(0.55 * rate)
        let tail = Int(0.7 * rate)..<Int(1.0 * rate)
        #expect(decibels(rms(output[steady]), rms(signal[steady])) > -2)
        #expect(decibels(rms(output[tail]), rms(signal[tail])) < -4)
    }

    @Test("No options, no change")
    func none() {
        let signal = StereoBuffer(mono: TestSignal.noise(count: 1_000))
        #expect(VocalCleanup.apply(signal, options: CleanupOptions(), sampleRate: rate, transform: nil) == signal)
        #expect(CleanupOptions().isEmpty)
    }
}

@Suite("Splitter: mixer, loops and exports")
struct StemMixTests {
    @Test("Modes, mute and solo set each part's gain")
    func gains() {
        var settings = StemMixSettings()
        settings.vocalsVolume = 1.2
        settings.backingVolume = 0.5
        #expect(settings.gain(.vocals) == 1.2)
        #expect(settings.gain(.backing) == 0.5)
        settings.mode = .original
        #expect(settings.gain(.vocals) == 1 && settings.gain(.backing) == 1)
        settings.mode = .vocals
        #expect(settings.gain(.vocals) == 1 && settings.gain(.backing) == 0)
        settings.mode = .backing
        #expect(settings.gain(.vocals) == 0 && settings.gain(.backing) == 1)
        settings.mode = .mix
        settings.backingSolo = true
        #expect(settings.gain(.vocals) == 0 && settings.gain(.backing) == 0.5)
        settings.backingSolo = false
        settings.vocalsMuted = true
        #expect(settings.gain(.vocals) == 0)
        settings.vocalsMuted = false
        settings.vocalsVolume = 3
        #expect(settings.gain(.vocals) == 1.5)
        #expect(abs(StemMixSettings.decibels(forGain: 1.5) - 3.52) < 0.01)
        #expect(StemMixSettings.decibels(forGain: 0) == -96)
    }

    @Test("Loops stay inside the track and wrap around")
    func loops() throws {
        #expect(LoopRange.make(start: 5, end: 5.2, duration: 60) == nil)
        let loop = try #require(LoopRange.make(start: 20, end: 10, duration: 60))
        #expect(loop.start == 10 && loop.end == 20)
        #expect(LoopRange.make(start: 50, end: 90, duration: 60)?.end == 60)
        #expect(loop.position(after: 15) == 15)
        #expect(loop.position(after: 20) == 10)
        #expect(loop.position(after: 3) == 10)
    }

    @Test("Export names and inputs")
    func exports() {
        #expect(StemExport.fileName(title: "My/Song: Live?", content: .vocals, fileExtension: "m4a") == "My Song  Live - Vocals.m4a")
        #expect(StemExport.fileName(title: "  ", content: .mix, fileExtension: "wav") == "Split - Mix.wav")
        let vocals = URL(filePath: "/tmp/v.m4a")
        let backing = URL(filePath: "/tmp/b.m4a")
        var settings = StemMixSettings()
        settings.vocalsMuted = true
        settings.mode = .vocals
        let mix = StemExport.inputs(content: .mix, vocals: vocals, backing: backing, settings: settings)
        #expect(mix == [MixInput(url: backing, gain: 1)])
        #expect(StemExport.inputs(content: .vocals, vocals: vocals, backing: backing, settings: settings) == [MixInput(url: vocals, gain: 1)])
        #expect(StemExport.inputs(content: .backing, vocals: vocals, backing: nil, settings: settings).isEmpty)
        #expect(StemMixdown.softLimit(0.5) == 0.5)
        #expect(StemMixdown.softLimit(3) <= 1)
        #expect(StemMixdown.softLimit(-3) >= -1)
        #expect(StemMixdown.softLimit(0.95) < 0.95)
        #expect(StemMixdown.softLimit(0.95) > 0.9)
    }
}

@Suite("Splitter: files and the whole pipeline", .serialized)
struct SplitterFileTests {
    private let rate = 44_100.0

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SplitterTests-\(UUID().uuidString)-\(name)", directoryHint: .notDirectory)
    }

    @Test("Stereo WAV files round-trip and mix with gains and offsets")
    func filesAndMixdown() throws {
        let first = temporaryURL("a.wav")
        let second = temporaryURL("b.wav")
        let mixed = temporaryURL("mix.wav")
        defer {
            for url in [first, second, mixed] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let a = StereoBuffer(left: sine(220, amplitude: 0.25, count: 20_000, sampleRate: rate), right: sine(330, amplitude: 0.25, count: 20_000, sampleRate: rate))
        let b = StereoBuffer(mono: sine(440, amplitude: 0.25, count: 10_000, sampleRate: rate))
        for (url, buffer) in [(first, a), (second, b)] {
            let writer = try StemFileWriter(urls: [url], sampleRate: rate, format: .wav)
            try writer.write([buffer])
            try writer.finish()
        }

        let reader = try AudioFileStereoReader(url: first)
        #expect(reader.estimatedFrameCount == 20_000)
        var readBack = StereoBuffer.empty
        while let block = try reader.read(maxFrames: 4_096) {
            readBack.append(block)
        }
        #expect(readBack.count == 20_000)
        #expect((zip(readBack.right, a.right).map { abs($0 - $1) }.max() ?? 1) < 0.001)

        try StemMixdown.render(
            [MixInput(url: first, gain: 1), MixInput(url: second, gain: 0.5, offsetFrames: 5_000)],
            to: mixed,
            format: .wav
        )
        let mixReader = try AudioFileStereoReader(url: mixed)
        var mix = StereoBuffer.empty
        while let block = try mixReader.read(maxFrames: 8_192) {
            mix.append(block)
        }
        #expect(mix.count == 20_000)
        for index in [100, 6_000, 14_000, 16_000] {
            let delayed = index >= 5_000 && index < 15_000 ? b.left[index - 5_000] * 0.5 : 0
            #expect(abs(mix.left[index] - (a.left[index] + delayed)) < 0.001)
        }
    }

    @Test("A stereo file splits end to end into vocals and backing files")
    func endToEnd() async throws {
        let source = temporaryURL("song.wav")
        defer { try? FileManager.default.removeItem(at: source) }
        let count = Int(rate * 3)
        let centre = sine(440, amplitude: 0.3, count: count, sampleRate: rate)
        let left = zip(centre, sine(300, amplitude: 0.2, count: count, sampleRate: rate)).map { $0 + $1 }
        let right = zip(centre, sine(700, amplitude: 0.2, count: count, sampleRate: rate)).map { $0 + $1 }
        let writer = try StemFileWriter(urls: [source], sampleRate: rate, format: .wav)
        try writer.write([StereoBuffer(left: left, right: right)])
        try writer.finish()

        let request = SeparationRequest(id: UUID(), sourceURL: source, title: "Test song", outputs: .both, engine: .basic, quality: .fast)
        defer { SeparationFiles.deleteFolder(for: request.id) }
        let result = try await SeparationJob.run(request) { _ in }
        #expect(result.engine == .basic)
        #expect(result.vocalsFileName == SeparationFiles.vocalsName)
        #expect(result.backingFileName == SeparationFiles.backingName)
        #expect(abs(result.duration - 3) < 0.05)
        #expect(result.vocalsFileSize > 0 && result.backingFileSize > 0)
        #expect(!result.chunkStats.isEmpty)

        let backing = try AudioFileStereoReader(url: try SeparationFiles.url(for: request.id, name: SeparationFiles.backingName))
        var parts = StereoBuffer.empty
        while let block = try backing.read(maxFrames: 65_536) {
            parts.append(block)
        }
        let middle = Array(parts.left[Int(rate)..<Int(rate * 2)])
        #expect(amplitude(middle, frequency: 440, sampleRate: rate) < 0.03)
        #expect(amplitude(middle, frequency: 300, sampleRate: rate) > 0.15)
    }

    @Test("Mono files are refused by the Basic engine")
    func monoRefused() async throws {
        let source = temporaryURL("mono.wav")
        defer { try? FileManager.default.removeItem(at: source) }
        let writer = try StemFileWriter(urls: [source], sampleRate: rate, format: .wav)
        try writer.write([StereoBuffer(mono: sine(220, amplitude: 0.3, count: 44_100, sampleRate: rate))])
        try writer.finish()
        let request = SeparationRequest(id: UUID(), sourceURL: source, title: "Mono", outputs: .both, engine: .basic, quality: .fast)
        await #expect(throws: SeparationError.monoSource) {
            _ = try await SeparationJob.run(request) { _ in }
        }
    }
}

@MainActor
@Suite("Splitter: saved splits", .serialized)
struct SeparationStoreTests {
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    private func result(_ id: UUID = UUID()) -> SeparationResult {
        SeparationResult(
            id: id, title: "Song", sourceType: .video, engine: .basic, quality: .fast,
            sourceFileName: "source.mov", vocalsFileName: SeparationFiles.vocalsName, backingFileName: nil,
            duration: 12, sourceFileSize: 1_000, vocalsFileSize: 200, backingFileSize: 0,
            chunkStats: [], fallbackReason: nil
        )
    }

    @Test("Splits are saved, linked to target voices and deleted")
    func saveAndDelete() throws {
        let context = container.mainContext
        let store = SeparationStore(context: context)
        let id = UUID()
        let track = try store.save(result(id))
        #expect(store.track(id: id)?.title == "Song")
        #expect(track.sourceType == .video)
        #expect(track.vocalsURL?.lastPathComponent == SeparationFiles.vocalsName)
        #expect(track.backingURL == nil)
        #expect(store.totalBytes() == 1_200)

        let voice = TargetVoiceProfile(name: "Voice")
        context.insert(voice)
        voice.separatedTrack = track
        try context.save()
        #expect(track.targetVoices?.count == 1)

        try store.delete(track)
        #expect(store.track(id: id) == nil)
        #expect(voice.separatedTrack == nil)
        #expect(store.tracks().isEmpty)
    }
}
