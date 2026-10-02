import Foundation

/// Saved result of a microphone calibration.
nonisolated struct MicCalibration: Codable, Sendable, Equatable {
    /// Background level of the room in dBFS (median of 5 quiet seconds).
    var noiseFloorDb: Double
    /// Typical level of the user's "aah" in dBFS.
    var voiceLevelDb: Double
    /// Loudest sample during the "aah", in dBFS.
    var voicePeakDb: Double
    /// Microphone the calibration was made with.
    var inputName: String
    var inputKind: AudioInputKind
    var date: Date

    /// Voice level above the room noise, in dB.
    var signalToNoiseDb: Double { voiceLevelDb - noiseFloorDb }

    /// Calibration only applies to the kind of mic it was measured with.
    func applies(to route: AudioRouteInfo?) -> Bool {
        guard let route else { return true }
        return route.inputKind == inputKind
    }
}

// MARK: - Assessment

nonisolated enum NoiseVerdict: Sendable, Equatable {
    case quiet
    case acceptable
    case tooNoisy
}

nonisolated struct NoiseAssessment: Sendable, Equatable {
    /// Median level of the quiet period (dBFS).
    let floorDb: Double
    /// Difference between loud and quiet moments (90th − 10th percentile, dB).
    let spreadDb: Double
    let verdict: NoiseVerdict
    /// True if the noise came and went (a door, a passing car) while measuring.
    let isUnsteady: Bool
}

nonisolated enum VoiceLevelVerdict: Sendable, Equatable {
    case good
    case tooQuiet
    case tooLoud
}

nonisolated struct VoiceLevelAssessment: Sendable, Equatable {
    /// Median level of the voiced frames (dBFS).
    let levelDb: Double
    /// Loudest sample (dBFS).
    let peakDb: Double
    /// Voice level minus noise floor (dB).
    let signalToNoiseDb: Double
    let verdict: VoiceLevelVerdict
}

/// Pure functions that judge calibration measurements.
///
/// Thresholds are starting points for an iPhone mic in measurement mode
/// (no automatic gain), to be fine-tuned on real devices.
nonisolated enum MicCalibrationAnalysis {
    /// Room noise at or below this level is "quiet".
    static let quietFloorDb = -60.0
    /// Room noise above this level is "too noisy".
    static let noisyFloorDb = -48.0
    /// Spread larger than this means the noise wasn't steady.
    static let unsteadySpreadDb = 12.0
    /// The voice should be at least this far above the room noise.
    static let minimumSignalToNoiseDb = 15.0
    /// Voices quieter than this are hard to analyze accurately.
    static let minimumVoiceLevelDb = -45.0
    /// Peaks above this risk clipping (distortion).
    static let clippingPeakDb = -1.0

    static func assessNoise(levels: [Double]) -> NoiseAssessment? {
        let finite = levels.filter(\.isFinite)
        guard let median = percentile(finite, 0.5),
              let low = percentile(finite, 0.1),
              let high = percentile(finite, 0.9)
        else { return nil }

        let verdict: NoiseVerdict
        if median <= quietFloorDb {
            verdict = .quiet
        } else if median <= noisyFloorDb {
            verdict = .acceptable
        } else {
            verdict = .tooNoisy
        }
        let spread = high - low
        return NoiseAssessment(
            floorDb: median,
            spreadDb: spread,
            verdict: verdict,
            isUnsteady: spread > unsteadySpreadDb
        )
    }

    static func assessVoice(levels: [Double], peakDb: Double, noiseFloorDb: Double) -> VoiceLevelAssessment? {
        guard let median = percentile(levels.filter(\.isFinite), 0.5) else { return nil }
        let signalToNoise = median - noiseFloorDb
        let verdict: VoiceLevelVerdict
        if peakDb >= clippingPeakDb {
            verdict = .tooLoud
        } else if median < minimumVoiceLevelDb || signalToNoise < minimumSignalToNoiseDb {
            verdict = .tooQuiet
        } else {
            verdict = .good
        }
        return VoiceLevelAssessment(
            levelDb: median,
            peakDb: peakDb,
            signalToNoiseDb: signalToNoise,
            verdict: verdict
        )
    }

    /// Linear-interpolated percentile (0...1) of the values.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    /// Whether a frame sounds like a steady "aah" rather than noise.
    static func isVoiced(_ frame: VoiceFrame, noiseFloorDb: Double) -> Bool {
        frame.rawFrequency != nil
            && frame.aperiodicity < 0.25
            && frame.levelDb >= noiseFloorDb + 10
    }
}

// MARK: - Storage

/// Keeps the calibration on this device. (Moves into the SwiftData user
/// profile when data storage is added.)
@MainActor
enum MicCalibrationStore {
    private static let key = "micCalibration.v1"

    static func load(from defaults: UserDefaults = .standard) -> MicCalibration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MicCalibration.self, from: data)
    }

    static func save(_ calibration: MicCalibration?, to defaults: UserDefaults = .standard) {
        guard let calibration else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(calibration) {
            defaults.set(data, forKey: key)
        }
    }
}
