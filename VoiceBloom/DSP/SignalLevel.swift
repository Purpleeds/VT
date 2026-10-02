import Accelerate
import Foundation

/// Loudness helpers. Levels are in dBFS: 0 dB is a full-scale signal and
/// quieter sounds are negative (a quiet room is around −60 to −70 dBFS).
nonisolated enum SignalLevel {
    /// Level reported for digital silence.
    static let silenceDb = -120.0

    /// Root-mean-square amplitude of the samples.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(base, 1, &result, vDSP_Length(samples.count))
        return Double(result)
    }

    static func rms(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Converts an RMS amplitude to dBFS.
    static func decibels(fromAmplitude amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else { return silenceDb }
        return max(silenceDb, 20 * log10(amplitude))
    }

    /// Voice activity detection: a frame only counts as possible voice when it is
    /// at least `marginDb` louder than the room's noise floor.
    static func isAboveGate(levelDb: Double, noiseFloorDb: Double, marginDb: Double) -> Bool {
        levelDb >= noiseFloorDb + marginDb
    }
}

/// Tracks the background noise level of the room while listening.
///
/// The estimate drops quickly whenever a quieter frame arrives (pauses between
/// words reveal the true background level) and creeps upward slowly otherwise,
/// so sustained speech can't drag it up to the voice level. Stage 2's mic
/// calibration will seed this with a measured value.
nonisolated struct NoiseFloorEstimator: Sendable, Equatable {
    static let defaultFloorDb = -60.0
    static let lowestFloorDb = -100.0
    static let highestFloorDb = -25.0

    private(set) var floorDb: Double
    /// How fast the estimate may rise toward louder frames (dB per second).
    var riseRateDbPerSecond: Double
    /// Fraction (0...1) of the gap closed per frame when a quieter frame arrives.
    var fallCoefficient: Double

    init(
        initialFloorDb: Double = NoiseFloorEstimator.defaultFloorDb,
        riseRateDbPerSecond: Double = 2,
        fallCoefficient: Double = 0.3
    ) {
        floorDb = min(max(initialFloorDb, Self.lowestFloorDb), Self.highestFloorDb)
        self.riseRateDbPerSecond = riseRateDbPerSecond
        self.fallCoefficient = min(max(fallCoefficient, 0), 1)
    }

    /// - Parameters:
    ///   - levelDb: Level of the newest frame in dBFS.
    ///   - elapsed: Seconds since the previous update (the hop duration).
    mutating func update(levelDb: Double, elapsed: Double) {
        guard levelDb.isFinite else { return }
        if levelDb < floorDb {
            floorDb += (levelDb - floorDb) * fallCoefficient
        } else {
            floorDb = min(levelDb, floorDb + riseRateDbPerSecond * max(0, elapsed))
        }
        floorDb = min(max(floorDb, Self.lowestFloorDb), Self.highestFloorDb)
    }
}
