import Foundation
import Testing
@testable import VoiceBloom

/// Shared helpers for the Clear Mic tests.
nonisolated enum ClearMicTestAudio {
    static let sampleRate = 48_000.0

    /// RMS level (dB re full scale) of a stretch of samples.
    static func rmsDb(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return SignalLevel.silenceDb }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(sum / Double(samples.count), 1e-30))
    }

    /// Sample indices from `start` to `end` seconds.
    static func span(_ start: Double, _ end: Double) -> Range<Int> {
        Int(start * sampleRate)..<Int(end * sampleRate)
    }

    /// `insert` added onto `base` from sample `offset`.
    static func mix(_ base: [Float], _ insert: [Float], at offset: Int) -> [Float] {
        var result = base
        for index in insert.indices where offset + index < result.count {
            result[offset + index] += insert[index]
        }
        return result
    }

    /// The processor's output lined up with its input (its latency dropped).
    static func aligned(_ output: [Float], latency: Int) -> [Float] {
        Array(output.dropFirst(latency))
    }

    /// Level change (dB) from `input` to `output` over a span in seconds.
    static func change(_ input: [Float], _ output: [Float], _ start: Double, _ end: Double) -> Double {
        let range = span(start, end)
        return rmsDb(output[range]) - rmsDb(input[range])
    }
}

@Suite("Clear Mic DSP")
struct ClearMicDSPTests {
    private typealias Audio = ClearMicTestAudio
    private let sampleRate = ClearMicTestAudio.sampleRate

    // MARK: High-pass filter

    @Test("The high-pass filter leaves the voice alone and removes rumble and hum")
    func highPassResponse() {
        let design = HighPassDesign(sampleRate: sampleRate)
        #expect(design.cutoff == 70)
        #expect(abs(design.gainDb(at: 70) + 3.01) < 0.1)
        #expect(design.gainDb(at: 50) < -11.5)
        #expect(design.gainDb(at: 60) < -6)
        #expect(design.gainDb(at: 100) > -0.3)
        #expect(design.gainDb(at: 120) > -0.1)
        #expect(design.gainDb(at: 200) > -0.01)
        #expect(design.gainDb(at: 1_000) > -0.001)
    }

    @Test("Filtering matches the designed response", arguments: [50.0, 60.0, 100.0, 200.0])
    func filterMatchesDesign(frequency: Double) {
        let design = HighPassDesign(sampleRate: sampleRate)
        var filter = HighPassFilterState(design: design)
        let tone = TestSignal.sine(frequency: frequency, count: 48_000)
        let output = filter.process(tone)
        // The second half, once the filter has settled (whole cycles of each tone).
        let measured = Audio.rmsDb(output[24_000...]) - Audio.rmsDb(tone[24_000...])
        let expected = design.gainDb(at: frequency)
        #expect(abs(measured - expected) < 0.05)
    }

    @Test("Weight readings are compensated for the high-pass filter")
    func weightCompensation() throws {
        let decimator = Decimator(inputSampleRate: sampleRate)
        let fundamental = 80.0
        // Harmonic k at 1/k: H1–H2 is 6 dB before filtering.
        let amplitudes = (1...72).map { 1 / Double($0) }
        let long = TestSignal.harmonicSeries(fundamental: fundamental, amplitudes: amplitudes, count: 50_048)
        let design = HighPassDesign(sampleRate: sampleRate)
        var filter = HighPassFilterState(design: design)
        let filtered = filter.process(long)
        let raw = decimator.decimate(Array(long.suffix(2_048)))
        let highPassed = decimator.decimate(Array(filtered.suffix(2_048)))

        let plainAnalyzer = WeightAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: 472)
        let compensatingAnalyzer = WeightAnalyzer(sampleRate: decimator.outputSampleRate, maximumFrameLength: 472)
        compensatingAnalyzer.inputFilter = design

        let reference = try #require(plainAnalyzer.analyze(raw, fundamental: fundamental, formants: nil))
        let uncorrected = try #require(plainAnalyzer.analyze(highPassed, fundamental: fundamental, formants: nil))
        let corrected = try #require(compensatingAnalyzer.analyze(highPassed, fundamental: fundamental, formants: nil))

        // The filter takes about 1.3 dB more off H1 (80 Hz) than off H2…
        let shift = design.gainDb(at: 2 * fundamental) - design.gainDb(at: fundamental)
        #expect(shift > 1)
        // …and the analyzer adds exactly that back.
        #expect(abs((corrected.h1MinusH2 - uncorrected.h1MinusH2) - shift) < 1e-6)
        #expect(abs(corrected.h1MinusH2 - reference.h1MinusH2) < 0.5)
    }

    // MARK: Processor basics

    @Test("With everything off, the output is the input delayed by the latency")
    func passThroughReconstructs() throws {
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .passThrough))
        #expect(processor.fftSize == 1_024)
        #expect(processor.latencySamples == 512)
        #expect(abs(processor.latency - 512.0 / 48_000) < 1e-12)

        let input = TestSignal.noise(count: 20_000, amplitude: 0.5, seed: 7)
        let output = processor.process(input)
        // Output comes in whole hops: 39 × 512.
        #expect(output.count == 19_968)
        var largestError: Float = 0
        for index in 0..<(output.count - 512) {
            largestError = max(largestError, abs(output[index + 512] - input[index]))
        }
        #expect(largestError < 1e-4)
        // The first hop is the initial silence.
        let firstHop = output.prefix(512)
        #expect(firstHop.allSatisfy { abs($0) < 1e-5 })
    }

    @Test("Lower sample rates use a smaller FFT")
    func lowSampleRate() throws {
        let processor = try #require(ClearMicProcessor(sampleRate: 16_000, parameters: .light))
        #expect(processor.fftSize == 512)
        #expect(processor.latencySamples == 256)
        #expect(ClearMicProcessor.fftSize(forSampleRate: 44_100) == 1_024)
        let tooLow = ClearMicProcessor(sampleRate: 4_000, parameters: .light)
        #expect(tooLow?.fftSize == nil)
    }

    @Test("Chunk sizes don't change the result")
    func chunkingIsInvisible() throws {
        let input = Audio.mix(TestSignal.noise(count: 24_000, amplitude: 0.02, seed: 3), TestSignal.vowel(.femaleAE, count: 12_000), at: 6_000)
        let oneShot = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .strong))
        let whole = oneShot.process(input)
        let streaming = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .strong))
        var pieces: [Float] = []
        var position = 0
        let sizes = [37, 480, 1, 1_024, 333, 5_000]
        var step = 0
        while position < input.count {
            let end = min(input.count, position + sizes[step % sizes.count])
            pieces += streaming.process(Array(input[position..<end]))
            position = end
            step += 1
        }
        let chunked = pieces
        #expect(chunked == whole)
    }

    @Test("Strengths map to their processing")
    func strengths() {
        #expect(ClearMicStrength.off.parameters == nil)
        #expect(ClearMicStrength.light.parameters == .light)
        #expect(ClearMicStrength.strong.parameters == .strong)
        #expect(ClearMicStrength.system.parameters?.noiseReduction == false)
        #expect(ClearMicStrength.system.parameters?.highPass == true)
        #expect(ClearMicParameters.strong.overSubtraction > ClearMicParameters.light.overSubtraction)
        #expect(ClearMicParameters.strong.spectralFloor < ClearMicParameters.light.spectralFloor)
        #expect(ClearMicParameters.strong.gateRangeDb > ClearMicParameters.light.gateRangeDb)
        #expect(ClearMicOffline.parameters(for: .off) == .light)
        #expect(ClearMicOffline.parameters(for: .system) == .light)
        #expect(ClearMicOffline.parameters(for: .strong) == .strong)
    }

    // MARK: Noise reduction and gate

    @Test("A sampled room profile quiets the pauses and leaves the voice", arguments: [ClearMicStrength.light, .strong])
    func noiseReductionWithProfile(strength: ClearMicStrength) throws {
        let parameters = try #require(strength.parameters)
        // 1 s of room noise (sampled), 0.5 s pause, 1 s vowel, 1 s pause.
        let input = Audio.mix(TestSignal.noise(count: 168_000, amplitude: 0.02, seed: 21), TestSignal.vowel(.maleAH, count: 48_000), at: 72_000)
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: parameters))
        processor.beginNoiseCapture(seconds: 1)
        let output = Audio.aligned(processor.process(input), latency: processor.latencySamples)

        let pauseBefore = Audio.change(input, output, 1.1, 1.45)
        let voice = Audio.change(input, output, 1.6, 2.4)
        let pauseAfter = Audio.change(input, output, 3.0, 3.45)
        let minimum = strength == .strong ? 18.0 : 10.0
        #expect(-pauseBefore >= minimum)
        #expect(-pauseAfter >= minimum)
        #expect(abs(voice) < 0.5)
    }

    @Test("A long held vowel is never mistaken for noise")
    func heldVowelIsKept() throws {
        let vowel = TestSignal.vowel(.maleAH, count: 96_000)
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .strong))
        let output = Audio.aligned(processor.process(vowel), latency: processor.latencySamples)
        let status = processor.status
        #expect(!status.isNoiseKnown)
        #expect(status.isGateOpen)
        #expect(abs(Audio.change(vowel, output, 0.5, 1.8)) < 0.1)
    }

    @Test("Without a profile, the room is learned in the first pause after speech")
    func learnsTheRoomInAPause() throws {
        // 0.8 s room, 1 s vowel, 1.5 s room.
        let input = Audio.mix(TestSignal.noise(count: 158_400, amplitude: 0.02, seed: 41), TestSignal.vowel(.maleAH, count: 48_000), at: 38_400)
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .light))
        let output = Audio.aligned(processor.process(input), latency: processor.latencySamples)
        // Before any speech nothing is known, so the room passes (only the
        // high-pass touches it), and the voice is untouched.
        #expect(abs(Audio.change(input, output, 0.1, 0.7)) < 0.5)
        #expect(abs(Audio.change(input, output, 1.0, 1.7)) < 0.5)
        // After the first pause the room is known and turned down.
        #expect(processor.status.isNoiseKnown)
        #expect(-Audio.change(input, output, 2.3, 3.2) >= 10)
    }

    @Test("Sampling room noise measures its level and hands the profile over once")
    func samplesRoomNoise() throws {
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .light))
        processor.beginNoiseCapture(seconds: 0.8)
        _ = processor.process(TestSignal.noise(count: 24_000, amplitude: 0.02, seed: 9))
        // 46 of 75 frames so far.
        let progress = try #require(processor.status.captureProgress)
        #expect(progress > 0.5 && progress < 0.8)
        _ = processor.process(TestSignal.noise(count: 24_000, amplitude: 0.02, seed: 10))

        let profile = try #require(processor.takeCapturedProfile())
        let second = processor.takeCapturedProfile()
        #expect(second == nil)
        #expect(processor.status.captureProgress == nil)
        #expect(processor.status.isNoiseKnown)
        // Uniform noise of amplitude a has an RMS of a/√3.
        let expected = 20 * log10(0.02 / 3.0.squareRoot())
        #expect(abs(profile.levelDb - expected) < 0.5)
        #expect(profile.bins.count == 513)
        #expect(profile.matches(sampleRate: sampleRate, fftSize: 1_024))
        #expect(!profile.matches(sampleRate: 44_100, fftSize: 1_024))
        let learned = try #require(processor.noiseProfile(inputKind: .builtInMicrophone))
        #expect(learned.inputKind == .builtInMicrophone)
    }

    @Test("A profile from another sample rate is ignored")
    func mismatchedProfileIgnored() throws {
        let profile = ClearMicNoiseProfile(
            sampleRate: 16_000, fftSize: 512, bins: [Float](repeating: 1e-6, count: 257),
            levelDb: -40, inputKind: nil, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let other = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .light, profile: profile))
        #expect(!other.status.isNoiseKnown)
        let matching = try #require(ClearMicProcessor(sampleRate: 16_000, parameters: .light, profile: profile))
        #expect(matching.status.isNoiseKnown)
    }

    @Test("The gate opens before a word and fades out smoothly after it")
    func gateTiming() throws {
        // 1 s room (sampled), 0.5 s room, 0.4 s buzz, 0.8 s room.
        let start = 72_000
        let length = 19_200
        let end = start + length
        let input = Audio.mix(
            TestSignal.noise(count: 129_600, amplitude: 0.02, seed: 31),
            TestSignal.sawtooth(frequency: 200, count: length, amplitude: 0.3),
            at: start
        )
        let processor = try #require(ClearMicProcessor(sampleRate: sampleRate, parameters: .light))
        processor.beginNoiseCapture(seconds: 1)
        let output = Audio.aligned(processor.process(input), latency: processor.latencySamples)
        func change(from: Int, count: Int) -> Double {
            Audio.rmsDb(output[from..<(from + count)]) - Audio.rmsDb(input[from..<(from + count)])
        }

        // The word is untouched, including its first 10 ms (the gate looks ahead).
        let word = change(from: start + 2_400, count: 14_400)
        let onset = change(from: start, count: 480)
        #expect(abs(word) < 0.5)
        #expect(abs(onset) < 1)

        // After it, the room fades down over a few hundred milliseconds.
        let after20 = change(from: end + 960, count: 480)
        let after150 = change(from: end + 7_200, count: 480)
        let after500 = change(from: end + 24_000, count: 480)
        #expect(after20 > -3)
        #expect(after150 < after20)
        #expect(after500 < after150)
        #expect(after500 < -10)
    }

    // MARK: Offline (saved recordings)

    @Test("Offline enhancement keeps the length and quiets the pauses", arguments: [ClearMicStrength.light, .strong])
    func offlineEnhancement(strength: ClearMicStrength) {
        // 0.7 s room, 1.2 s vowel, 0.7 s room: the quiet parts give the profile.
        let recording = Audio.mix(TestSignal.noise(count: 124_800, amplitude: 0.02, seed: 51), TestSignal.vowel(.maleAH, count: 57_600), at: 33_600)
        let enhanced = ClearMicOffline.enhance(recording, sampleRate: sampleRate, parameters: ClearMicOffline.parameters(for: strength))
        #expect(enhanced.count == recording.count)
        let minimum = strength == .strong ? 14.0 : 8.0
        #expect(-Audio.change(recording, enhanced, 0.1, 0.6) >= minimum)
        #expect(-Audio.change(recording, enhanced, 2.25, 2.55) >= minimum)
        #expect(abs(Audio.change(recording, enhanced, 0.9, 1.8)) < 0.5)
    }

    @Test("Offline output lines up with the input sample for sample")
    func offlineAlignment() {
        let recording = Audio.mix(TestSignal.noise(count: 124_800, amplitude: 0.02, seed: 52), TestSignal.vowel(.maleAH, count: 57_600), at: 33_600)
        // Noise reduction only (the high-pass filter shifts low-frequency phase).
        let parameters = ClearMicParameters(
            highPass: false, noiseReduction: true, overSubtraction: 1.3, spectralFloor: 0.4,
            gate: false, gateMarginDb: 6, gateRangeDb: 0
        )
        let enhanced = ClearMicOffline.enhance(recording, sampleRate: sampleRate, parameters: parameters)
        let range = Audio.span(0.9, 1.8)
        let difference = range.map { enhanced[$0] - recording[$0] }
        // During the vowel almost nothing is removed; one sample off would leave about −17 dB.
        let residual = Audio.rmsDb(difference[...]) - Audio.rmsDb(recording[range])
        #expect(residual < -25)
    }

    @Test("Empty and very short recordings pass through")
    func offlineEdgeCases() {
        let empty = ClearMicOffline.enhance([], sampleRate: sampleRate, parameters: .light)
        #expect(empty.isEmpty)
        let short = TestSignal.noise(count: 100, amplitude: 0.1, seed: 1)
        let shortEnhanced = ClearMicOffline.enhance(short, sampleRate: sampleRate, parameters: .light)
        #expect(shortEnhanced.count == 100)
        let clip = AudioClip(samples: short, sampleRate: sampleRate, startTime: 4)
        let enhancedClip = ClearMicOffline.enhance(clip, strength: .strong)
        #expect(enhancedClip.startTime == 4)
        #expect(enhancedClip.samples.count == 100)
    }

    // MARK: Readings survive

    @Test("Clear Mic doesn't move pitch, resonance or weight readings")
    func readingsSurvive() throws {
        // 0.6 s room, 1.5 s vowel, 0.6 s room, about 22 dB below the vowel.
        let samples = Audio.mix(TestSignal.noise(count: 129_600, amplitude: 0.02, seed: 61), TestSignal.vowel(.maleAE, count: 72_000), at: 28_800)
        let recording = AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
        let result = ClearMicComparison.compare(raw: recording, strength: .light, knownProfile: nil)
        let raw = result.comparison.raw
        let enhanced = result.comparison.enhanced
        #expect(result.enhanced.samples.count == samples.count)
        #expect(result.comparison.strength == .light)

        let rawPitch = try #require(raw.medianPitch)
        let enhancedPitch = try #require(enhanced.medianPitch)
        #expect(abs(rawPitch - 110) < 2)
        #expect(abs(enhancedPitch - rawPitch) < 1)
        let cents = try #require(result.comparison.pitchDifferenceCents)
        #expect(abs(cents) < 10)

        let rawF2 = try #require(raw.f2)
        let enhancedF2 = try #require(enhanced.f2)
        #expect(abs(enhancedF2 - rawF2) / rawF2 < 0.08)

        let rawWeight = try #require(raw.h1MinusH2)
        let enhancedWeight = try #require(enhanced.h1MinusH2)
        #expect(abs(enhancedWeight - rawWeight) < 2)

        #expect(enhanced.voicedSeconds >= raw.voicedSeconds * 0.8)
        let reduction = try #require(result.comparison.backgroundReductionDb)
        #expect(reduction > 6)
    }

    @Test("Background and voice levels come from the quietest and loudest blocks")
    func levels() throws {
        let quiet = TestSignal.noise(count: 24_000, amplitude: 0.001, seed: 2)
        let loud = TestSignal.sine(frequency: 220, count: 24_000, amplitude: 0.5)
        let levels = ClearMicComparison.levels(quiet + loud, sampleRate: sampleRate)
        let background = try #require(levels.background)
        let voice = try #require(levels.voice)
        #expect(abs(background - 20 * log10(0.001 / 3.0.squareRoot())) < 1.5)
        #expect(abs(voice - 20 * log10(0.5 / 2.0.squareRoot())) < 0.5)
        let tooShort = ClearMicComparison.levels([0.1, 0.2], sampleRate: sampleRate)
        #expect(tooShort.background == nil)
    }

    @Test("The A/B summary compares pitch and background")
    func abSummary() throws {
        let raw = MicTakeReadings(medianPitch: 200, voicedSeconds: 4, backgroundDb: -50)
        let enhanced = MicTakeReadings(medianPitch: 200 * pow(2, 3.0 / 1_200), voicedSeconds: 4, backgroundDb: -62)
        let comparison = MicABComparison(strength: .light, raw: raw, enhanced: enhanced)
        let cents = try #require(comparison.pitchDifferenceCents)
        #expect(abs(cents - 3) < 1e-9)
        #expect(comparison.backgroundReductionDb == 12)
        let summary = comparison.summary
        #expect(summary.contains("12 dB"))
        let silent = MicABComparison(strength: .light, raw: MicTakeReadings(), enhanced: MicTakeReadings())
        let silentSummary = silent.summary
        #expect(silentSummary.contains("No clear voice"))
    }

    // MARK: Live stage

    @Test("Recordings get the raw audio while the analysis hears Clear Mic")
    func stageKeepsRawAudioForRecordings() throws {
        let signal = Audio.mix(TestSignal.noise(count: 48_000, amplitude: 0.02, seed: 71), TestSignal.vowel(.femaleAE, count: 24_000), at: 12_000)
        let ring = SampleRingBuffer(minimumCapacity: 65_536)
        _ = ring.write(signal)
        let tap = AudioTap()
        tap.begin(sampleRate: sampleRate, startTime: 0)
        let control = ClearMicControl()
        control.setParameters(.light)
        let stage = ClearMicStage(
            sampleRate: sampleRate, parameters: .light, analyzesEnhanced: true, profile: nil,
            inputKind: .builtInMicrophone, control: control, hopHint: 512
        )
        #expect(stage.analyzesEnhanced)
        #expect(abs(stage.latency - 512.0 / 48_000) < 1e-12)
        let pipeline = VoiceAnalysisPipeline(
            configuration: AnalysisConfiguration(sampleRate: sampleRate),
            startTime: -stage.latency,
            inputHighPass: HighPassDesign(sampleRate: sampleRate)
        )
        let frames = stage.drain(ring, pipeline: pipeline, tap: tap, rawStartTime: 0)
        #expect(!frames.isEmpty)
        #expect(stage.rawSampleCount == signal.count)

        let recent = try #require(tap.recentAudio.clip(lastSeconds: 1))
        #expect(recent.samples == signal)

        let status = control.status
        #expect(status.isEnhancing)
        #expect(abs(status.latency - 512.0 / 48_000) < 1e-12)
        #expect(status.peakDb > -10)
        // The quietest 100 ms: the room noise, a/√3 for uniform noise.
        let floor = try #require(status.noiseFloorDb)
        #expect(abs(floor - 20 * log10(0.02 / 3.0.squareRoot())) < 1.5)
    }

    @Test("With Clear Mic off the analysis hears exactly the raw audio")
    func stageOffIsRaw() {
        let signal = TestSignal.sine(frequency: 247, count: 20_000)
        let configuration = AnalysisConfiguration()
        let direct = VoiceAnalysisPipeline(configuration: configuration).process(signal)
        let ring = SampleRingBuffer(minimumCapacity: 32_768)
        _ = ring.write(signal)
        let stage = ClearMicStage(
            sampleRate: sampleRate, parameters: nil, analyzesEnhanced: true, profile: nil,
            inputKind: nil, control: ClearMicControl(), hopHint: configuration.hopSize
        )
        #expect(!stage.analyzesEnhanced)
        #expect(stage.latency == 0)
        let frames = stage.drain(ring, pipeline: VoiceAnalysisPipeline(configuration: configuration), tap: AudioTap(), rawStartTime: 0)
        let frameTimes = frames.map { $0.time }
        let directTimes = direct.map { $0.time }
        let frameEstimates = frames.map { $0.rawFrequency }
        let directEstimates = direct.map { $0.rawFrequency }
        #expect(frameTimes == directTimes)
        #expect(frameEstimates == directEstimates)
    }

    @Test("Frame times stay on the raw audio's timeline when the analysis hears Clear Mic")
    func stageKeepsFrameTimes() throws {
        let signal = TestSignal.sawtooth(frequency: 180, count: 24_000, amplitude: 0.3)
        let configuration = AnalysisConfiguration()
        let rawFrames = VoiceAnalysisPipeline(configuration: configuration).process(signal)
        let ring = SampleRingBuffer(minimumCapacity: 32_768)
        _ = ring.write(signal)
        let stage = ClearMicStage(
            sampleRate: sampleRate, parameters: .passThrough, analyzesEnhanced: true, profile: nil,
            inputKind: nil, control: ClearMicControl(), hopHint: configuration.hopSize
        )
        #expect(stage.analyzesEnhanced)
        // The monitor starts the pipeline's clock one latency early.
        let pipeline = VoiceAnalysisPipeline(configuration: configuration, startTime: -stage.latency)
        let frames = stage.drain(ring, pipeline: pipeline, tap: AudioTap(), rawStartTime: 0)
        try #require(frames.count >= 10 && rawFrames.count >= 10)
        // Clear Mic's delay is exactly one analysis hop at 48 kHz, so frame
        // k + 1 analyzes the same audio as raw frame k, at the same time.
        for index in 0..<min(frames.count - 1, rawFrames.count) {
            let enhancedFrame = frames[index + 1]
            let rawFrame = rawFrames[index]
            #expect(abs(enhancedFrame.time - rawFrame.time) < 1e-9)
            if let enhancedPitch = enhancedFrame.rawFrequency, let rawPitch = rawFrame.rawFrequency {
                #expect(abs(enhancedPitch - rawPitch) < 0.05)
            }
        }
    }

    // MARK: Saved recordings

    @Test("A Clear Mic copy is made once and the original file never changes")
    func enhancedCopy() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: source) }
        let samples = Audio.mix(TestSignal.noise(count: 96_000, amplitude: 0.02, seed: 81), TestSignal.vowel(.femaleAE, count: 48_000), at: 24_000)
        let clip = AudioClip(samples: samples, sampleRate: sampleRate, startTime: 0)
        try RecordingFileStore.write(clip, to: source)
        let before = try Data(contentsOf: source)

        let id = UUID()
        let copy = try EnhancedRecordingCache.enhancedCopy(of: source, id: id, strength: .light)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        #expect(copy.lastPathComponent == EnhancedRecordingCache.fileName)
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        let after = try Data(contentsOf: source)
        #expect(after == before)

        let again = try EnhancedRecordingCache.enhancedCopy(of: source, id: id, strength: .light)
        #expect(again == copy)
        let strong = try EnhancedRecordingCache.enhancedCopy(of: source, id: id, strength: .strong)
        defer { try? FileManager.default.removeItem(at: strong.deletingLastPathComponent()) }
        #expect(strong != copy)

        let original = try RecordingFileStore.readSamples(from: source)
        let decoded = try RecordingFileStore.readSamples(from: copy)
        #expect(abs(decoded.duration - clip.duration) < 0.1)
        // The room before the vowel is clearly quieter in the copy.
        let quiet = 4_800..<19_200
        try #require(decoded.samples.count > quiet.upperBound && original.samples.count > quiet.upperBound)
        #expect(Audio.rmsDb(original.samples[quiet]) - Audio.rmsDb(decoded.samples[quiet]) > 6)
    }
}

@Suite("Clear Mic settings and suggestions")
struct ClearMicSettingsTests {
    private func settings(_ strength: ClearMicStrength, passedCheck: Bool = false) -> ClearMicSettings {
        var settings = ClearMicSettings()
        settings.strength = strength
        if passedCheck {
            settings.systemCheck = SystemModeCheckResult(
                date: Date(timeIntervalSince1970: 1_700_000_000), passed: true,
                systemSampleRate: 48_000, normalSampleRate: 48_000,
                pitchDifferenceCents: 2, voicedRatio: 0.95, reason: "Passed"
            )
        }
        return settings
    }

    @Test("Defaults: off, analyzing enhanced audio when on, Bluetooth mics off")
    func defaults() {
        let defaults = ClearMicSettings()
        #expect(defaults.strength == .off)
        #expect(defaults.effectiveStrength == .off)
        #expect(!defaults.isEnhancing)
        #expect(defaults.analyzesEnhancedAudio)
        #expect(!defaults.allowsBluetoothInput)
        #expect(defaults.captureOptions == CaptureOptions())
    }

    @Test("System mode only applies after its check passes")
    func systemModeNeedsTheCheck() {
        let unchecked = settings(.system)
        #expect(unchecked.effectiveStrength == .light)
        #expect(unchecked.displayedStrength == .light)
        #expect(!unchecked.captureOptions.voiceProcessing)

        let checked = settings(.system, passedCheck: true)
        #expect(checked.isSystemModeAvailable)
        #expect(checked.effectiveStrength == .system)
        #expect(checked.captureOptions.voiceProcessing)

        var testing = settings(.system)
        testing.isTestingSystemMode = true
        let duringCheck = testing
        #expect(duringCheck.effectiveStrength == .system)
        #expect(duringCheck.captureOptions.voiceProcessing)

        var bluetooth = settings(.light)
        bluetooth.allowsBluetoothInput = true
        bluetooth.preferredInputUID = "headset"
        let options = bluetooth.captureOptions
        #expect(options == CaptureOptions(voiceProcessing: false, allowsBluetoothInput: true, preferredInputUID: "headset"))
    }

    @Test("System falls back to Light unless iOS voice processing is really on")
    func parametersForFormat() {
        let plain = CaptureFormat(sampleRate: 48_000, channelCount: 1, ioBufferDuration: 0.005)
        let processed = CaptureFormat(sampleRate: 48_000, channelCount: 1, ioBufferDuration: 0.005, isVoiceProcessing: true)
        let off = settings(.off)
        let light = settings(.light)
        let strong = settings(.strong)
        let system = settings(.system, passedCheck: true)
        #expect(LiveVoiceMonitor.clearMicParameters(for: off, format: plain) == nil)
        #expect(LiveVoiceMonitor.clearMicParameters(for: light, format: plain) == .light)
        #expect(LiveVoiceMonitor.clearMicParameters(for: strong, format: plain) == .strong)
        #expect(LiveVoiceMonitor.clearMicParameters(for: system, format: plain) == .light)
        #expect(LiveVoiceMonitor.clearMicParameters(for: system, format: processed) == .system)
    }

    @Test("Settings survive a round trip; unknown or missing values fall back")
    func settingsCoding() throws {
        var original = settings(.strong, passedCheck: true)
        original.analyzesEnhancedAudio = false
        original.allowsBluetoothInput = true
        original.preferredInputUID = "wired-1"
        original.isTestingSystemMode = true
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClearMicSettings.self, from: data)
        // The System Mode Check's temporary flag is never saved.
        var expected = original
        expected.isTestingSystemMode = false
        let wanted = expected
        #expect(decoded == wanted)

        let empty = try JSONDecoder().decode(ClearMicSettings.self, from: Data("{}".utf8))
        #expect(empty == ClearMicSettings())
        let unknown = try JSONDecoder().decode(ClearMicSettings.self, from: Data(#"{"strength":"turbo","allowsBluetoothInput":true}"#.utf8))
        #expect(unknown.strength == .off)
        #expect(unknown.allowsBluetoothInput)
    }

    @Test("Settings and the noise profile are saved per iPhone")
    func stores() throws {
        let suite = "VoiceBloomTests.clearMic.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ClearMicSettingsStore.load(from: defaults) == ClearMicSettings())
        let strong = settings(.strong)
        ClearMicSettingsStore.save(strong, to: defaults)
        #expect(ClearMicSettingsStore.load(from: defaults) == strong)

        #expect(ClearMicProfileStore.load(from: defaults) == nil)
        let profile = ClearMicNoiseProfile(
            sampleRate: 48_000, fftSize: 1_024, bins: [Float](repeating: 1e-6, count: 513),
            levelDb: -55, inputKind: .builtInMicrophone, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        ClearMicProfileStore.save(profile, to: defaults)
        #expect(ClearMicProfileStore.load(from: defaults) == profile)
        #expect(ClearMicProfileStore.load(sampleRate: 48_000, fftSize: 1_024, inputKind: .builtInMicrophone, from: defaults) == profile)
        #expect(ClearMicProfileStore.load(sampleRate: 48_000, fftSize: 1_024, inputKind: nil, from: defaults) == profile)
        #expect(ClearMicProfileStore.load(sampleRate: 44_100, fftSize: 1_024, inputKind: .builtInMicrophone, from: defaults) == nil)
        #expect(ClearMicProfileStore.load(sampleRate: 48_000, fftSize: 512, inputKind: .builtInMicrophone, from: defaults) == nil)
        #expect(ClearMicProfileStore.load(sampleRate: 48_000, fftSize: 1_024, inputKind: .bluetooth, from: defaults) == nil)
        ClearMicProfileStore.save(nil, to: defaults)
        #expect(ClearMicProfileStore.load(from: defaults) == nil)
    }

    @Test("The control hands changes to the analysis thread once")
    func control() {
        let control = ClearMicControl()
        let start = control.currentParameters.revision
        let unchanged = control.parameters(after: start)
        #expect(unchanged?.revision == nil)
        control.setParameters(.strong)
        let change = control.parameters(after: start)
        #expect(change?.parameters == .strong)
        #expect(change?.revision == start + 1)
        control.setParameters(nil)
        let cleared = control.parameters(after: start + 1)
        #expect(cleared?.revision == start + 2)
        #expect(cleared?.parameters == nil)

        control.requestNoiseCapture(seconds: 2)
        let request = control.takeCaptureRequest()
        let again = control.takeCaptureRequest()
        #expect(request == 2)
        #expect(again == nil)

        let profile = ClearMicNoiseProfile(
            sampleRate: 48_000, fftSize: 1_024, bins: [Float](repeating: 1e-6, count: 513),
            levelDb: -50, inputKind: nil, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        control.publishCaptured(profile)
        let captured = control.takeCapturedProfile()
        let capturedAgain = control.takeCapturedProfile()
        #expect(captured == profile)
        #expect(capturedAgain == nil)
        #expect(control.latestProfile == profile)
        control.clearProfiles()
        #expect(control.latestProfile == nil)
    }

    // MARK: Noisy-room suggestion

    @Test("A noisy room is suggested once, after 8 seconds")
    func suggestionOnce() {
        var tracker = NoiseSuggestionTracker()
        let first = tracker.update(noiseFloorDb: -45, strength: .off, time: 0)
        let early = tracker.update(noiseFloorDb: -45, strength: .off, time: 7.5)
        let due = tracker.update(noiseFloorDb: -45, strength: .off, time: 8)
        let later = tracker.update(noiseFloorDb: -45, strength: .off, time: 30)
        #expect(first == nil)
        #expect(early == nil)
        #expect(due == .turnOnClearMic)
        #expect(later == nil)

        // A new session may suggest again.
        tracker.reset()
        let restart = tracker.update(noiseFloorDb: -45, strength: .off, time: 31)
        let again = tracker.update(noiseFloorDb: -45, strength: .off, time: 39)
        #expect(restart == nil)
        #expect(again == .turnOnClearMic)
    }

    @Test("A quiet moment restarts the wait")
    func quietRestarts() {
        var tracker = NoiseSuggestionTracker()
        let noisy = tracker.update(noiseFloorDb: -45, strength: .off, time: 0)
        let quiet = tracker.update(noiseFloorDb: -60, strength: .off, time: 5)
        let noisyAgain = tracker.update(noiseFloorDb: -45, strength: .off, time: 6)
        let notYet = tracker.update(noiseFloorDb: -45, strength: .off, time: 13.5)
        let unknown = tracker.update(noiseFloorDb: nil, strength: .off, time: 13.6)
        let restarted = tracker.update(noiseFloorDb: -45, strength: .off, time: 14)
        let stillWaiting = tracker.update(noiseFloorDb: -45, strength: .off, time: 21.5)
        let due = tracker.update(noiseFloorDb: -45, strength: .off, time: 22)
        #expect(noisy == nil)
        #expect(quiet == nil)
        #expect(noisyAgain == nil)
        #expect(notYet == nil)
        #expect(unknown == nil)
        #expect(restarted == nil)
        #expect(stillWaiting == nil)
        #expect(due == .turnOnClearMic)
    }

    @Test("Each strength has its own threshold and suggestion")
    func thresholdsPerStrength() {
        var light = NoiseSuggestionTracker()
        _ = light.update(noiseFloorDb: -45, strength: .light, time: 0)
        let lightQuiet = light.update(noiseFloorDb: -45, strength: .light, time: 10)
        _ = light.update(noiseFloorDb: -40, strength: .light, time: 11)
        let lightNoisy = light.update(noiseFloorDb: -40, strength: .light, time: 19)
        #expect(lightQuiet == nil)
        #expect(lightNoisy == .tryStrong)

        var strong = NoiseSuggestionTracker()
        _ = strong.update(noiseFloorDb: -40, strength: .strong, time: 0)
        let strongQuiet = strong.update(noiseFloorDb: -40, strength: .strong, time: 10)
        _ = strong.update(noiseFloorDb: -36, strength: .strong, time: 11)
        let strongNoisy = strong.update(noiseFloorDb: -36, strength: .strong, time: 19)
        #expect(strongQuiet == nil)
        #expect(strongNoisy == .findQuieterSpot)

        #expect(NoiseSuggestion.turnOnClearMic.suggestedStrength == .light)
        #expect(NoiseSuggestion.tryStrong.suggestedStrength == .strong)
        #expect(NoiseSuggestion.findQuieterSpot.suggestedStrength == nil)
        #expect(NoiseSuggestion.findQuieterSpot.actionTitle == nil)
    }

    @Test("Background badge thresholds")
    func badge() {
        #expect(MicNoiseBadge(noiseFloorDb: -70) == .great)
        #expect(MicNoiseBadge(noiseFloorDb: -60) == .great)
        #expect(MicNoiseBadge(noiseFloorDb: -55) == .ok)
        #expect(MicNoiseBadge(noiseFloorDb: -48) == .ok)
        #expect(MicNoiseBadge(noiseFloorDb: -40) == .tooNoisy)
    }

    // MARK: System Mode Check

    private func measure(pitch: Double?, voiced: Double, spread: Double? = 10, sampleRate: Double = 48_000) -> PitchTakeMeasure {
        PitchTakeMeasure(medianPitch: pitch, voicedSeconds: voiced, pitchSpreadCents: spread, sampleRate: sampleRate)
    }

    @Test("System mode passes when pitch matches and the held note comes through")
    func systemCheckPasses() throws {
        let result = SystemModeCheck.evaluate(
            system: measure(pitch: 220.5, voiced: 3.6, spread: 12),
            normal: measure(pitch: 220, voiced: 3.8),
            voiceProcessingWorked: true
        )
        #expect(result.passed)
        let difference = try #require(result.pitchDifferenceCents)
        #expect(abs(difference - 1_200 * log2(220.5 / 220)) < 1e-9)
        let ratio = try #require(result.voicedRatio)
        #expect(abs(ratio - 3.6 / 3.8) < 1e-9)
    }

    @Test("System mode fails for pitch shifts, muted notes, low sample rates and unsteady pitch")
    func systemCheckFails() {
        let shifted = SystemModeCheck.evaluate(system: measure(pitch: 223.3, voiced: 3.6), normal: measure(pitch: 220, voiced: 3.8), voiceProcessingWorked: true)
        #expect(!shifted.passed)
        let muted = SystemModeCheck.evaluate(system: measure(pitch: 220, voiced: 1.5), normal: measure(pitch: 220, voiced: 3.8), voiceProcessingWorked: true)
        #expect(!muted.passed)
        let narrow = SystemModeCheck.evaluate(system: measure(pitch: 220, voiced: 3.6, sampleRate: 16_000), normal: measure(pitch: 220, voiced: 3.8), voiceProcessingWorked: true)
        #expect(!narrow.passed)
        let unsteady = SystemModeCheck.evaluate(system: measure(pitch: 220, voiced: 3.6, spread: 30), normal: measure(pitch: 220, voiced: 3.8, spread: 10), voiceProcessingWorked: true)
        #expect(!unsteady.passed)
        let silent = SystemModeCheck.evaluate(system: measure(pitch: 220, voiced: 3.6), normal: measure(pitch: nil, voiced: 0.5), voiceProcessingWorked: true)
        #expect(!silent.passed)
        let broken = SystemModeCheck.evaluate(system: measure(pitch: 220, voiced: 3.6), normal: measure(pitch: 220, voiced: 3.8), voiceProcessingWorked: false)
        #expect(!broken.passed)
    }
}
