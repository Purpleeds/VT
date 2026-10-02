import Foundation
import Testing
@testable import VoiceBloom

@Suite("SignalLevel and noise floor")
struct SignalLevelTests {
    @Test("RMS of a sine is amplitude / √2")
    func sineRMS() {
        // 200 Hz at 48 kHz: 4800 samples is exactly 20 periods.
        let signal = TestSignal.sine(frequency: 200, count: 4800, amplitude: 0.5)
        let rms = SignalLevel.rms(signal)
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 1e-4)
        #expect(abs(SignalLevel.decibels(fromAmplitude: rms) - (-9.03)) < 0.01)
    }

    @Test("Silence and empty input")
    func silence() {
        #expect(SignalLevel.rms([]) == 0)
        #expect(SignalLevel.rms(TestSignal.silence(count: 512)) == 0)
        #expect(SignalLevel.decibels(fromAmplitude: 0) == SignalLevel.silenceDb)
        #expect(SignalLevel.decibels(fromAmplitude: 1) == 0)
    }

    @Test("Voice gate opens only above floor + margin")
    func gate() {
        #expect(SignalLevel.isAboveGate(levelDb: -50, noiseFloorDb: -60, marginDb: 8))
        #expect(SignalLevel.isAboveGate(levelDb: -52, noiseFloorDb: -60, marginDb: 8))
        #expect(!SignalLevel.isAboveGate(levelDb: -55, noiseFloorDb: -60, marginDb: 8))
    }

    @Test("Noise floor drops quickly to a quieter room")
    func floorFallsFast() {
        var estimator = NoiseFloorEstimator(initialFloorDb: -60)
        for _ in 0..<20 {
            estimator.update(levelDb: -80, elapsed: 0.01)
        }
        #expect(abs(estimator.floorDb - -80) < 0.1)
    }

    @Test("Noise floor rises slowly, so speech can't drag it up")
    func floorRisesSlowly() {
        var estimator = NoiseFloorEstimator(initialFloorDb: -60, riseRateDbPerSecond: 2)
        // One second of loud speech in 10 ms steps.
        for _ in 0..<100 {
            estimator.update(levelDb: -20, elapsed: 0.01)
        }
        #expect(abs(estimator.floorDb - -58) < 0.01)
    }

    @Test("Noise floor never rises above the current level")
    func floorCappedByLevel() {
        var estimator = NoiseFloorEstimator(initialFloorDb: -60, riseRateDbPerSecond: 100)
        estimator.update(levelDb: -59, elapsed: 1)
        #expect(estimator.floorDb == -59)
    }

    @Test("Noise floor stays within sane limits")
    func floorClamped() {
        var estimator = NoiseFloorEstimator(initialFloorDb: -60, fallCoefficient: 1)
        estimator.update(levelDb: -200, elapsed: 0.01)
        #expect(estimator.floorDb == NoiseFloorEstimator.lowestFloorDb)
        let loud = NoiseFloorEstimator(initialFloorDb: 0)
        #expect(loud.floorDb == NoiseFloorEstimator.highestFloorDb)
    }
}
