import Foundation
import Testing
@testable import VoiceBloom

@Suite("LivePitchPipeline (end to end)")
struct LivePitchPipelineTests {
    private let configuration = AnalysisConfiguration()

    /// Feeds the signal in small, uneven chunks the way the audio thread would.
    private func process(_ signal: [Float], with pipeline: LivePitchPipeline) -> [PitchFrame] {
        var frames: [PitchFrame] = []
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
        let pipeline = LivePitchPipeline(configuration: configuration)
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
        let pipeline = LivePitchPipeline(configuration: configuration, startTime: 5)
        let frames = process(TestSignal.sine(frequency: 200, count: 8192), with: pipeline)
        #expect(frames.count == 13)
        #expect(abs(frames[0].time - (5 + 1024.0 / 48_000)) < 1e-9)
        for index in 1..<frames.count {
            #expect(abs(frames[index].time - frames[index - 1].time - configuration.hopDuration) < 1e-9)
        }
    }

    @Test("Silence never produces a pitch")
    func silenceIsGated() {
        let pipeline = LivePitchPipeline(configuration: configuration)
        let frames = process(TestSignal.silence(count: 24_000), with: pipeline)
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.status == .belowNoiseGate })
        #expect(frames.allSatisfy { $0.displayFrequency == nil })
    }

    @Test("A tone quieter than the noise gate is ignored")
    func quietToneIsGated() {
        // Noise floor fixed at −40 dBFS (a loud room); the tone is about −49 dBFS.
        let pipeline = LivePitchPipeline(
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
        let pipeline = LivePitchPipeline(configuration: configuration)
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

        let direct = LivePitchPipeline(configuration: configuration).process(signal)

        let ring = SampleRingBuffer(minimumCapacity: 32_768)
        ring.write(signal)
        let drained = LivePitchPipeline(configuration: configuration).drain(ring)

        #expect(direct.map(\.rawFrequency) == drained.map(\.rawFrequency))
        #expect(direct.map(\.displayFrequency) == drained.map(\.displayFrequency))
        #expect(ring.availableCount == 0)
    }
}
