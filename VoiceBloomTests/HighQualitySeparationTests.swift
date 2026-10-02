import Foundation
import Testing
@testable import VoiceBloom

/// Stand-ins for the Core ML model: return the mix, nothing, or half.
nonisolated final class FakeMagnitudePredictor: MagnitudePredictor {
    nonisolated enum Behaviour {
        case identity
        case silence
        case half
    }

    let bins: Int
    let frames: Int
    let behaviour: Behaviour
    private(set) var calls = 0

    init(behaviour: Behaviour, bins: Int = 2049, frames: Int = 8) {
        self.behaviour = behaviour
        self.bins = bins
        self.frames = frames
    }

    func predictVocals(_ magnitude: [Float]) throws -> [Float] {
        calls += 1
        switch behaviour {
        case .identity: return magnitude
        case .silence: return [Float](repeating: 0, count: magnitude.count)
        case .half: return magnitude.map { $0 / 2 }
        }
    }
}

@Suite("High Quality engine (with stand-in models)")
struct HighQualitySeparationTests {
    private let rate = 44_100.0

    private func noise(_ count: Int) -> StereoBuffer {
        StereoBuffer(left: TestSignal.noise(count: count, amplitude: 0.5, seed: 3), right: TestSignal.noise(count: count, amplitude: 0.5, seed: 4))
    }

    private func largestError(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 1
    }

    @Test("Chunks match the model's frame count")
    func chunkSize() throws {
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .identity, frames: 432))
        #expect(engine.chunkSamples == 431 * 1024)
        #expect(abs(engine.chunkDuration - 10.0077) < 0.001)
        #expect(engine.kind == .highQuality)
    }

    @Test("A model that hears only vocals puts everything in the vocals")
    func identity() throws {
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .identity))
        // Shorter than a chunk: padded for the model, cropped after.
        let input = noise(5_000)
        let pair = try engine.separate(input, sampleRate: rate, quality: .fast)
        #expect(pair.vocals.count == 5_000)
        #expect(largestError(pair.vocals.left, input.left) < 1e-3)
        #expect(largestError(pair.vocals.right, input.right) < 1e-3)
        #expect((pair.backing.left.map { abs($0) }.max() ?? 1) < 1e-3)
    }

    @Test("A model that hears no vocals leaves everything in the backing")
    func silence() throws {
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .silence))
        let input = noise(7_168)
        let pair = try engine.separate(input, sampleRate: rate, quality: .fast)
        #expect((pair.vocals.left.map { abs($0) }.max() ?? 1) < 1e-6)
        #expect(largestError(pair.backing.left, input.left) < 1e-6)
    }

    @Test("Half the magnitude gives an even split, and the parts add up")
    func half() throws {
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .half))
        let input = noise(7_168)
        let pair = try engine.separate(input, sampleRate: rate, quality: .fast)
        #expect(largestError(pair.vocals.left, input.left.map { $0 / 2 }) < 1e-3)
        let sum = zip(pair.vocals.right, pair.backing.right).map { $0 + $1 }
        #expect(largestError(sum, input.right) < 1e-5)
    }

    @Test("Best runs a second, channel-swapped pass (or the larger model)")
    func best() throws {
        let fast = FakeMagnitudePredictor(behaviour: .identity)
        let engine = try SpectrogramMaskEngine(predictor: fast)
        let input = noise(3_000)
        let pair = try engine.separate(input, sampleRate: rate, quality: .best)
        #expect(fast.calls == 2)
        #expect(largestError(pair.vocals.left, input.left) < 1e-3)

        let small = FakeMagnitudePredictor(behaviour: .identity)
        let large = FakeMagnitudePredictor(behaviour: .silence)
        let withBest = try SpectrogramMaskEngine(predictor: small, bestPredictor: large)
        let bestPair = try withBest.separate(input, sampleRate: rate, quality: .best)
        #expect(large.calls == 1)
        #expect(small.calls == 1)
        #expect((bestPair.vocals.left.map { abs($0) }.max() ?? 1) < 1e-6)
    }

    @Test("Models with the wrong shape or audio at the wrong rate are refused")
    func refusals() throws {
        #expect(throws: HighQualityEngineError.unexpectedModel) {
            _ = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .identity, bins: 1025))
        }
        #expect(throws: HighQualityEngineError.unexpectedModel) {
            _ = try SpectrogramMaskEngine(
                predictor: FakeMagnitudePredictor(behaviour: .identity),
                bestPredictor: FakeMagnitudePredictor(behaviour: .identity, frames: 16)
            )
        }
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .identity))
        #expect(throws: HighQualityEngineError.wrongSampleRate) {
            _ = try engine.separate(noise(100), sampleRate: 48_000, quality: .fast)
        }
        #expect(CoreMLMagnitudePredictor.parseShape([1, 2, 2049, 432])?.frames == 432)
        #expect(CoreMLMagnitudePredictor.parseShape([1, 1, 2049, 432]) == nil)
        #expect(CoreMLMagnitudePredictor.parseShape([2, 2049, 432]) == nil)
    }

    @Test("Mask and layout helpers")
    func helpers() {
        #expect(SpectrogramMaskEngine.vocalMask(mixture: 1, vocals: 1) > 0.999)
        #expect(SpectrogramMaskEngine.vocalMask(mixture: 1, vocals: 0) == 0)
        #expect(abs(SpectrogramMaskEngine.vocalMask(mixture: 1, vocals: 0.5) - 0.5) < 1e-6)
        #expect(SpectrogramMaskEngine.vocalMask(mixture: 1, vocals: -1) == 0)
        #expect(SpectrogramMaskEngine.swapChannels([1, 2, 3, 4], bins: 1, frames: 2) == [3, 4, 1, 2])
    }

    @Test("Streams through the chunk runner like any engine")
    func throughRunner() throws {
        let engine = try SpectrogramMaskEngine(predictor: FakeMagnitudePredictor(behaviour: .identity))
        let input = noise(20_000)
        let sink = MemoryStereoSink(outputCount: 2)
        try ChunkedRunner.run(
            source: MemoryStereoSource(input, sampleRate: rate),
            chunkLength: engine.chunkSamples,
            overlap: 1_024,
            outputCount: 2,
            sink: sink,
            isCancelled: { false },
            progress: { _ in }
        ) { chunk in
            let pair = try engine.separate(chunk, sampleRate: rate, quality: .fast)
            return [pair.vocals, pair.backing]
        }
        #expect(sink.outputs[0].count == 20_000)
        #expect(largestError(sink.outputs[0].left, input.left) < 1e-3)
    }

    @Test("Without a bundled model, High Quality falls back to Basic and says why")
    func fallback() throws {
        #expect(!CoreMLSeparationEngine.isModelInstalled)
        #expect(!SeparationEngineFactory.isHighQualityAvailable)
        let choice = try #require(SeparationEngineFactory.make(.highQuality))
        #expect(choice.engine.kind == .basic)
        #expect(choice.fallbackReason == HighQualityEngineError.modelMissing.errorDescription)
        let basic = try #require(SeparationEngineFactory.make(.basic))
        #expect(basic.fallbackReason == nil)
    }
}
