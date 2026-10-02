import Foundation

/// Synthetic test signals with known frequencies.
nonisolated enum TestSignal {
    /// Pitches from a low bass speaking voice up to a high soprano speaking voice.
    static let speakingFrequencies: [Double] = [
        65.41, 82.41, 98.0, 110.0, 130.81, 155.56, 180.0, 196.0, 220.0, 246.94, 261.63, 329.63, 392.0, 440.0, 493.88,
    ]

    static func sine(
        frequency: Double,
        sampleRate: Double = 48_000,
        count: Int,
        amplitude: Double = 0.5,
        phase: Double = 0.3
    ) -> [Float] {
        (0..<count).map { index in
            let time = Double(index) / sampleRate
            return Float(amplitude * sin(2 * .pi * frequency * time + phase))
        }
    }

    /// A sawtooth is rich in harmonics, much like the buzz of the vocal folds,
    /// so it is a harder (more realistic) test than a pure sine.
    static func sawtooth(
        frequency: Double,
        sampleRate: Double = 48_000,
        count: Int,
        amplitude: Double = 0.5,
        phaseOffset: Double = 0.17
    ) -> [Float] {
        (0..<count).map { index in
            let cycles = frequency * Double(index) / sampleRate + phaseOffset
            let phase = cycles - cycles.rounded(.down)
            return Float(amplitude * (2 * phase - 1))
        }
    }

    /// Deterministic white noise in −amplitude...amplitude.
    static func noise(count: Int, amplitude: Double = 0.1, seed: UInt64 = 0x5EED) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            Float(Double.random(in: -amplitude...amplitude, using: &generator))
        }
    }

    static func silence(count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    /// Sample-by-sample sum of two signals of the same length.
    static func mix(_ first: [Float], _ second: [Float]) -> [Float] {
        zip(first, second).map { $0 + $1 }
    }
}

/// Small, fast, reproducible random number generator (SplitMix64).
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
