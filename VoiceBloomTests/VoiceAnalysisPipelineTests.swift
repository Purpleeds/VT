import Foundation
import Testing
@testable import VoiceBloom

@Suite("VoiceAnalysisPipeline (end to end)")
struct VoiceAnalysisPipelineTests {
    private let configuration = AnalysisConfiguration()

    /// Feeds the signal in small, uneven chunks the way the audio thread would.
    private func process(_ signal: [Float], with pipeline: VoiceAnalysisPipeline) -> [VoiceFrame] {
        var frames: [VoiceFrame] = []
        var position = 0
        let chunkSizes = [256, 241, 512, 100]
        var chunkIndex = 0
        while position < signal.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], signal.count - position)
            frames += pipeline.process(Array(signal[position ..< position + size]))
            position += size
            chunkIndex += 1
        }
        return frames
    }

    @Test("A steady tone is voiced and accurate", arguments: [110.0, 196.0, 220.0])
    func steadyTone(frequency: Double) throws {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let frames = process(TestSignal.sawtooth(frequency: frequency, count: 48_000), with: pipeline)

        // (48000 − 2048) / 512 + 1 = 90 frames in one second.
        #expect(frames.count == 90)
        let voiced = frames.filter(\.isVoiced)
        #expect(voiced.count == frames.count)
        for frame in voiced {
            let filtered = try #require(frame.filteredFrequency)
            #expect(abs(filtered - frequency) <= 2)
            let display = try #require(frame.displayFrequency)
            #expect(abs(display - frequency) <= 2)
        }
    }

    @Test("Frames are timestamped at their centres, one hop apart")
    func timestamps() {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration, startTime: 5)
        let frames = process(TestSignal.sine(frequency: 200, count: 8192), with: pipeline)
        #expect(frames.count == 13)
        #expect(abs(frames[0].time - (5 + 1024.0 / 48_000)) < 1e-9)
        for index in 1..<frames.count {
            #expect(abs(frames[index].time - frames[index - 1].time - configuration.hopDuration) < 1e-9)
        }
    }

    @Test("Silence never produces a pitch")
    func silenceIsGated() {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let frames = process(TestSignal.silence(count: 24_000), with: pipeline)
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.status == .belowNoiseGate })
        #expect(frames.allSatisfy { $0.displayFrequency == nil })
    }

    @Test("A tone quieter than the noise gate is ignored")
    func quietToneIsGated() {
        // Noise floor fixed at −40 dBFS (a loud room); the tone is about −49 dBFS.
        let pipeline = VoiceAnalysisPipeline(
            configuration: configuration,
            noiseFloor: NoiseFloorEstimator(initialFloorDb: -40, riseRateDbPerSecond: 0, fallCoefficient: 0)
        )
        let frames = process(TestSignal.sine(frequency: 200, count: 12_000, amplitude: 0.005), with: pipeline)
        #expect(frames.allSatisfy { $0.status == .belowNoiseGate })
        // YIN still sees the tone, which the debug screen shows as raw dots.
        #expect(frames.contains { $0.rawFrequency != nil })
    }

    @Test("Voice after silence is detected once it rises above the noise floor")
    func voiceAfterSilence() throws {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let quietRoom = TestSignal.noise(count: 24_000, amplitude: 0.0005) // ≈ −71 dBFS
        let voice = TestSignal.sawtooth(frequency: 180, count: 24_000, amplitude: 0.3)
        let frames = process(quietRoom + voice, with: pipeline)

        let firstVoiced = try #require(frames.firstIndex(where: \.isVoiced))
        // No pitch during the quiet room, and the floor learned the room level.
        #expect(frames[..<firstVoiced].allSatisfy { $0.displayFrequency == nil })
        #expect(frames[firstVoiced].noiseFloorDb < -60)
        let laterFrames = frames.suffix(20)
        #expect(laterFrames.allSatisfy(\.isVoiced))
        for frame in laterFrames {
            let filtered = try #require(frame.filteredFrequency)
            #expect(abs(filtered - 180) <= 2)
        }
    }

    @Test("Draining the ring buffer gives the same result as direct processing")
    func drainMatchesDirectProcessing() {
        let signal = TestSignal.sine(frequency: 247, count: 20_000)

        let direct = VoiceAnalysisPipeline(configuration: configuration).process(signal)

        let ring = SampleRingBuffer(minimumCapacity: 32_768)
        ring.write(signal)
        let drained = VoiceAnalysisPipeline(configuration: configuration).drain(ring)

        #expect(direct.map(\.rawFrequency) == drained.map(\.rawFrequency))
        #expect(direct.map(\.displayFrequency) == drained.map(\.displayFrequency))
        #expect(direct.map(\.formants) == drained.map(\.formants))
        #expect(ring.availableCount == 0)
    }

    @Test("A sustained vowel gets formants and weight on its stable frames", arguments: [TestVowel.maleAH, .femaleAE, .femaleEE])
    func vowelAnalysis(vowel: TestVowel) throws {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let frames = process(TestSignal.vowel(vowel, count: 48_000), with: pipeline)
        #expect(frames.count == 90)

        // Onsets are never stable: three steady voiced frames are needed first.
        #expect(!frames[0].isStable)
        #expect(!frames[1].isStable)

        let stable = frames.filter(\.isStable)
        #expect(stable.count >= 80)
        for frame in stable {
            let formants = try #require(frame.formants)
            #expect(abs(formants.f1.frequency - vowel.formants[0].frequency) <= 60)
            #expect(abs(formants.f2.frequency - vowel.formants[1].frequency) <= 90)
            #expect(frame.weight != nil)
        }
        // Formants and weight are only ever measured on stable frames.
        #expect(frames.filter { !$0.isStable }.allSatisfy { $0.formants == nil && $0.weight == nil })
    }

    @Test("A phrase is summarized once the speaker pauses")
    func phraseCompletes() throws {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        // One second of "ah" at 120 Hz, then 0.6 s of silence.
        let signal = TestSignal.vowel(.maleAH, count: 48_000) + TestSignal.silence(count: 28_800)
        let frames = process(signal, with: pipeline)
        let phrases = frames.compactMap(\.completedPhrase)
        #expect(phrases.count == 1)
        let phrase = try #require(phrases.first)
        #expect(phrase.voicedDuration > 0.9 && phrase.voicedDuration < 1.05)
        #expect(abs(phrase.meanFrequency - 120) < 2)
        // A held vowel is (correctly) not melodic.
        #expect(phrase.standardDeviationSemitones < 0.2)
        #expect(phrase.rises == 0 && phrase.falls == 0)
    }

    @Test("Silence and quiet noise never produce formants")
    func noFormantsWithoutVoice() {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let quietRoom = TestSignal.noise(count: 24_000, amplitude: 0.0005)
        let frames = process(TestSignal.silence(count: 12_000) + quietRoom, with: pipeline)
        #expect(frames.allSatisfy { $0.formants == nil && $0.weight == nil && !$0.isStable })
    }

    @Test("Peak level is reported per frame")
    func peakLevel() throws {
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let frames = process(TestSignal.sine(frequency: 200, count: 8192, amplitude: 0.5), with: pipeline)
        let frame = try #require(frames.first)
        #expect(abs(frame.peakDb - (-6.02)) < 0.1)
        #expect(frame.peakDb > frame.levelDb)
    }

    @Test("A calibrated noise floor gates quiet sounds the adaptive floor would let through")
    func calibratedGate() {
        // A soft tone at about −49 dBFS.
        let tone = TestSignal.sine(frequency: 200, count: 12_000, amplitude: 0.005)
        let adaptive = VoiceAnalysisPipeline(configuration: configuration)
        let calibrated = VoiceAnalysisPipeline(configuration: configuration, noiseFloor: .calibrated(floorDb: -45))
        #expect(process(tone, with: adaptive).contains(where: \.isVoiced))
        #expect(!process(tone, with: calibrated).contains(where: \.isVoiced))
    }
}
