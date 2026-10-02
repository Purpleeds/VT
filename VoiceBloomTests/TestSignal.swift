import Foundation
@testable import VoiceBloom

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

    /// A sum of harmonics of `fundamental` with the given amplitudes
    /// (amplitudes[0] is H1). Phases are staggered so peaks don't align.
    static func harmonicSeries(
        fundamental: Double,
        amplitudes: [Double],
        sampleRate: Double = 48_000,
        count: Int
    ) -> [Float] {
        var output = [Double](repeating: 0, count: count)
        for (index, amplitude) in amplitudes.enumerated() {
            let omega = 2 * Double.pi * Double(index + 1) * fundamental / sampleRate
            let phase = 0.3 * Double(index)
            for sample in 0..<count {
                output[sample] += amplitude * cos(omega * Double(sample) + phase)
            }
        }
        return output.map { Float(0.3 * $0) }
    }

    /// A synthetic vowel, built the way speech is produced (source–filter model):
    /// 1. Source: harmonics of F0 falling 12 dB/octave, like the glottal pulse.
    /// 2. Filter: one two-pole resonator per formant (the vocal tract).
    /// 3. Radiation: a first difference (+6 dB/octave), like sound leaving the lips.
    /// The result is normalized to a 0.5 peak.
    static func vowel(_ vowel: TestVowel, sampleRate: Double = 48_000, count: Int) -> [Float] {
        var signal = [Double](repeating: 0, count: count)
        var harmonic = 1
        while Double(harmonic) * vowel.fundamental < 0.45 * sampleRate {
            let amplitude = 1 / Double(harmonic * harmonic)
            let omega = 2 * Double.pi * Double(harmonic) * vowel.fundamental / sampleRate
            for sample in 0..<count {
                signal[sample] += amplitude * cos(omega * Double(sample))
            }
            harmonic += 1
        }

        for formant in vowel.formants {
            let radius = exp(-Double.pi * formant.bandwidth / sampleRate)
            let theta = 2 * Double.pi * formant.frequency / sampleRate
            let feedback1 = 2 * radius * cos(theta)
            let feedback2 = -radius * radius
            let gain = 1 - feedback1 - feedback2
            var previous = 0.0
            var beforePrevious = 0.0
            for sample in 0..<count {
                let value = gain * signal[sample] + feedback1 * previous + feedback2 * beforePrevious
                signal[sample] = value
                beforePrevious = previous
                previous = value
            }
        }

        var radiated = [Double](repeating: 0, count: count)
        var last = 0.0
        for sample in 0..<count {
            radiated[sample] = signal[sample] - last
            last = signal[sample]
        }

        let peak = radiated[(count / 3)...].map { abs($0) }.max() ?? 1
        let scale = peak > 0 ? 0.5 / peak : 1
        return radiated.map { Float($0 * scale) }
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

/// A synthetic vowel description with known formants.
nonisolated struct TestVowel: Sendable, CustomStringConvertible {
    let name: String
    let fundamental: Double
    /// F1–F5 (F4 and F5 make the spectrum realistic up to ~5 kHz).
    let formants: [Formant]

    var description: String { name }

    init(_ name: String, fundamental: Double, _ formants: [(Double, Double)]) {
        self.name = name
        self.fundamental = fundamental
        self.formants = formants.map { Formant(frequency: $0.0, bandwidth: $0.1) }
    }

    /// Formant values close to published adult averages.
    static let maleEE = TestVowel("male ee", fundamental: 120, [(270, 60), (2290, 100), (3010, 120), (3700, 180), (4500, 250)])
    static let maleAH = TestVowel("male ah", fundamental: 120, [(730, 80), (1090, 90), (2440, 120), (3400, 180), (4400, 250)])
    static let maleOO = TestVowel("male oo", fundamental: 120, [(300, 60), (870, 80), (2240, 120), (3300, 180), (4300, 250)])
    static let maleAE = TestVowel("male ae", fundamental: 110, [(660, 80), (1720, 100), (2410, 120), (3500, 180), (4500, 250)])
    static let femaleEE = TestVowel("female ee", fundamental: 210, [(310, 70), (2790, 110), (3310, 140), (4300, 200), (5000, 250)])
    static let femaleAH = TestVowel("female ah", fundamental: 210, [(850, 90), (1220, 100), (2810, 130), (4000, 200), (4900, 250)])
    static let femaleAE = TestVowel("female ae", fundamental: 220, [(860, 90), (2050, 110), (2850, 130), (4100, 200), (4950, 250)])
    static let femaleOO = TestVowel("female oo", fundamental: 200, [(370, 70), (950, 90), (2670, 130), (3900, 200), (4900, 250)])

    static let all: [TestVowel] = [maleEE, maleAH, maleOO, maleAE, femaleEE, femaleAH, femaleAE, femaleOO]
}
