import Foundation

/// Converts a measurement into a 0...1 position between a starting point
/// (the user's baseline) and a goal (the target).
nonisolated enum ScoreScale {
    /// 0 at `baseline`, 1 at `target`, clamped. Works whichever direction the
    /// target lies in. `logarithmic` compares ratios, which suits frequencies.
    static func position(of value: Double, baseline: Double, target: Double, logarithmic: Bool = false) -> Double {
        guard value.isFinite, baseline != target else { return 0 }
        let fraction: Double
        if logarithmic {
            guard value > 0, baseline > 0, target > 0 else { return 0 }
            fraction = log(value / baseline) / log(target / baseline)
        } else {
            fraction = (value - baseline) / (target - baseline)
        }
        return min(max(fraction, 0), 1)
    }
}

// MARK: - Resonance

/// What the resonance meter compares against.
///
/// Formant frequencies depend heavily on the vowel, so a sustained "ee" needs
/// different reference values than running speech (which mixes all vowels).
nonisolated enum ResonanceMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case speech
    case ee
    case ih
    case ay
    case ah

    var id: String { rawValue }

    /// Menu title.
    var title: String {
        switch self {
        case .speech: "Speech (any words)"
        case .ee: "“ee” as in see"
        case .ih: "“ih” as in sit"
        case .ay: "“ay” as in say"
        case .ah: "“ah” as in father"
        }
    }

    /// Compact label for the meter header.
    var shortTitle: String {
        switch self {
        case .speech: "Speech"
        case .ee: "“ee”"
        case .ih: "“ih”"
        case .ay: "“ay”"
        case .ah: "“ah”"
        }
    }

    /// What the user should do for this mode to measure well.
    var prompt: String {
        switch self {
        case .speech: "Talk or read aloud"
        case .ee: "Hold a long “ee”"
        case .ih: "Hold a long “ih”"
        case .ay: "Hold a long “ay”"
        case .ah: "Hold a long “ah”"
        }
    }

    /// Default reference values: approximate adult male averages as the
    /// starting point and approximate adult female averages as the target,
    /// rounded from classic vowel studies (Peterson & Barney 1952;
    /// Hillenbrand et al. 1995). Later stages replace the baseline with the
    /// user's own recording and the target with a target-voice profile.
    var defaultReference: ResonanceReference {
        switch self {
        case .speech: ResonanceReference(baselineF2: 1_500, targetF2: 1_760, baselineF3: 2_500, targetF3: 2_860)
        case .ee: ResonanceReference(baselineF2: 2_300, targetF2: 2_760, baselineF3: 3_000, targetF3: 3_370)
        case .ih: ResonanceReference(baselineF2: 2_030, targetF2: 2_370, baselineF3: 2_680, targetF3: 3_050)
        case .ay: ResonanceReference(baselineF2: 2_090, targetF2: 2_530, baselineF3: 2_690, targetF3: 3_050)
        case .ah: ResonanceReference(baselineF2: 1_330, targetF2: 1_550, baselineF3: 2_520, targetF3: 2_815)
        }
    }

    /// Seconds of stable frames the meter averages. Speech mixes vowels, so it
    /// needs a longer window for the vowel differences to even out.
    var averagingWindow: Double {
        self == .speech ? 2.5 : 1.0
    }
}

/// Baseline and target formant values for the resonance score.
nonisolated struct ResonanceReference: Sendable, Equatable {
    let baselineF2: Double
    let targetF2: Double
    let baselineF3: Double
    let targetF3: Double

    /// 0 at the baseline, 100 at the target. F2 counts most (it moves the most
    /// when resonance brightens); F3 adds stability.
    func score(f2: Double, f3: Double?) -> Double {
        let f2Position = ScoreScale.position(of: f2, baseline: baselineF2, target: targetF2, logarithmic: true)
        guard let f3 else { return 100 * f2Position }
        let f3Position = ScoreScale.position(of: f3, baseline: baselineF3, target: targetF3, logarithmic: true)
        return 100 * (0.65 * f2Position + 0.35 * f3Position)
    }
}

// MARK: - Weight

/// Baseline and target values for the vocal weight score.
///
/// Higher H1–H2 and a steeper (more negative) spectral tilt mean a lighter
/// voice. The defaults are provisional starting points in the range reported
/// for adult speakers (H1*–H2* is typically several dB higher in women than
/// in men); the user's baseline recording will replace them in a later stage.
nonisolated struct WeightReference: Sendable, Equatable {
    var baselineH1MinusH2 = 5.0
    var targetH1MinusH2 = 11.0
    var baselineTilt = -4.0
    var targetTilt = -8.0

    static let standard = WeightReference()

    /// 0 = as heavy as the baseline, 100 = as light as the target.
    func score(h1MinusH2: Double, spectralTilt: Double?) -> Double {
        let harmonicPosition = ScoreScale.position(of: h1MinusH2, baseline: baselineH1MinusH2, target: targetH1MinusH2)
        guard let spectralTilt else { return 100 * harmonicPosition }
        let tiltPosition = ScoreScale.position(of: spectralTilt, baseline: baselineTilt, target: targetTilt)
        return 100 * (0.7 * harmonicPosition + 0.3 * tiltPosition)
    }
}

// MARK: - Intonation

/// Baseline and target pitch variability for the intonation score.
///
/// Fairly flat speech varies by about 2 semitones (standard deviation);
/// expressive speech commonly varies by 3.5 or more. Provisional defaults,
/// replaced later by the user's baseline and target-voice profile.
nonisolated struct IntonationReference: Sendable, Equatable {
    var baselineStandardDeviation = 2.0
    var targetStandardDeviation = 3.5

    static let standard = IntonationReference()

    /// 0 = as flat as the baseline, 100 = as melodic as the target.
    func score(standardDeviationSemitones: Double) -> Double {
        100 * ScoreScale.position(
            of: standardDeviationSemitones,
            baseline: baselineStandardDeviation,
            target: targetStandardDeviation
        )
    }
}

// MARK: - Zones

/// Coarse band of a 0–100 score, so meters can show a word, not just a color.
nonisolated enum MeterZone: Sendable, Equatable {
    case low
    case middle
    case high

    init(score: Double) {
        if score < 34 {
            self = .low
        } else if score < 67 {
            self = .middle
        } else {
            self = .high
        }
    }
}
