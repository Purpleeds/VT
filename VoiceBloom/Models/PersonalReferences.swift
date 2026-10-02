import Foundation

/// The user's own baseline and target values for the resonance, weight and
/// intonation scores (SPEC section 2: "scaled between the user's own baseline
/// and the target value").
///
/// Any value left nil falls back to the default references. Baselines come
/// from the Day 1 recording; targets from Settings or a target-voice profile.
nonisolated struct PersonalReferences: Sendable, Equatable, Codable {
    var baselineF2: Double?
    var baselineF3: Double?
    var targetF2: Double?
    var targetF3: Double?
    var baselineH1MinusH2: Double?
    var targetH1MinusH2: Double?
    var baselineIntonationSD: Double?
    var targetIntonationSD: Double?

    static let none = PersonalReferences()

    init(
        baselineF2: Double? = nil,
        baselineF3: Double? = nil,
        targetF2: Double? = nil,
        targetF3: Double? = nil,
        baselineH1MinusH2: Double? = nil,
        targetH1MinusH2: Double? = nil,
        baselineIntonationSD: Double? = nil,
        targetIntonationSD: Double? = nil
    ) {
        self.baselineF2 = baselineF2
        self.baselineF3 = baselineF3
        self.targetF2 = targetF2
        self.targetF3 = targetF3
        self.baselineH1MinusH2 = baselineH1MinusH2
        self.targetH1MinusH2 = targetH1MinusH2
        self.baselineIntonationSD = baselineIntonationSD
        self.targetIntonationSD = targetIntonationSD
    }

    init(profile: UserProfile) {
        self.init(
            baselineF2: profile.baselineF2,
            baselineF3: profile.baselineF3,
            targetF2: profile.targetF2,
            targetF3: profile.targetF3,
            baselineH1MinusH2: profile.baselineH1MinusH2,
            targetH1MinusH2: profile.targetH1MinusH2,
            baselineIntonationSD: profile.baselineIntonationSD,
            targetIntonationSD: profile.targetIntonationSD
        )
    }

    /// Minimum gap between baseline and target, so a baseline that's already
    /// near the target doesn't make tiny changes swing the score.
    static let minimumF2Gap = 120.0
    static let minimumF3Gap = 120.0
    static let minimumH1MinusH2Gap = 2.0
    static let minimumIntonationGap = 0.75

    /// Resonance reference for a meter mode.
    ///
    /// The personal values are measured on running speech, so they replace the
    /// `.speech` reference directly. Held vowels keep their own vowel-specific
    /// values, scaled by how far the user's speech differs from the defaults.
    func resonance(for mode: ResonanceMode) -> ResonanceReference {
        let speechDefault = ResonanceMode.speech.defaultReference
        let modeDefault = mode.defaultReference

        let targetF2 = targetF2 ?? speechDefault.targetF2
        let targetF3 = targetF3 ?? speechDefault.targetF3
        var baselineF2 = baselineF2 ?? speechDefault.baselineF2
        var baselineF3 = baselineF3 ?? speechDefault.baselineF3
        if targetF2 - baselineF2 < Self.minimumF2Gap {
            baselineF2 = targetF2 - Self.minimumF2Gap
        }
        if targetF3 - baselineF3 < Self.minimumF3Gap {
            baselineF3 = targetF3 - Self.minimumF3Gap
        }

        if mode == .speech {
            return ResonanceReference(baselineF2: baselineF2, targetF2: targetF2, baselineF3: baselineF3, targetF3: targetF3)
        }
        // Scale the vowel's defaults by the same ratios (formants scale with
        // vocal tract length, so ratios carry over between vowels).
        return ResonanceReference(
            baselineF2: modeDefault.baselineF2 * baselineF2 / speechDefault.baselineF2,
            targetF2: modeDefault.targetF2 * targetF2 / speechDefault.targetF2,
            baselineF3: modeDefault.baselineF3 * baselineF3 / speechDefault.baselineF3,
            targetF3: modeDefault.targetF3 * targetF3 / speechDefault.targetF3
        )
    }

    var weight: WeightReference {
        var reference = WeightReference.standard
        if let targetH1MinusH2 {
            reference.targetH1MinusH2 = targetH1MinusH2
        }
        if let baselineH1MinusH2 {
            reference.baselineH1MinusH2 = baselineH1MinusH2
        }
        if reference.targetH1MinusH2 - reference.baselineH1MinusH2 < Self.minimumH1MinusH2Gap {
            reference.baselineH1MinusH2 = reference.targetH1MinusH2 - Self.minimumH1MinusH2Gap
        }
        return reference
    }

    var intonation: IntonationReference {
        var reference = IntonationReference.standard
        if let targetIntonationSD {
            reference.targetStandardDeviation = targetIntonationSD
        }
        if let baselineIntonationSD {
            reference.baselineStandardDeviation = baselineIntonationSD
        }
        if reference.targetStandardDeviation - reference.baselineStandardDeviation < Self.minimumIntonationGap {
            reference.baselineStandardDeviation = max(0, reference.targetStandardDeviation - Self.minimumIntonationGap)
        }
        return reference
    }
}
