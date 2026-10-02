import Foundation

/// How the app alerts the user while practicing.
nonisolated struct FeedbackSettings: Codable, Sendable, Equatable {
    /// Gentle Core Haptics taps when the voice slips.
    var hapticAlerts = true
    /// Soft chimes when the voice slips. Off by default: the mic hears them,
    /// so those moments are left out of the analysis (headphones avoid that).
    var soundAlerts = false
    /// Subtle on-screen color change and message.
    var visualAlerts = true
    /// Alert when pitch drops below the target zone.
    var pitchSlipAlerts = true
    /// Alert when resonance darkens toward the old voice.
    var resonanceSlipAlerts = true
    var sensitivity: SlipSensitivity = .standard
    /// Show "Your voice sounds tired" when roughness clearly increases.
    var strainWarnings = true
    /// In eyes-free mode, add soft chimes to the haptics.
    var eyesFreeTones = false

    init() {}

    nonisolated private enum CodingKeys: String, CodingKey {
        case hapticAlerts, soundAlerts, visualAlerts, pitchSlipAlerts, resonanceSlipAlerts
        case sensitivity, strainWarnings, eyesFreeTones
    }

    /// Missing keys fall back to defaults, so adding settings later never
    /// wipes the ones already saved.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FeedbackSettings()
        hapticAlerts = try container.decodeIfPresent(Bool.self, forKey: .hapticAlerts) ?? defaults.hapticAlerts
        soundAlerts = try container.decodeIfPresent(Bool.self, forKey: .soundAlerts) ?? defaults.soundAlerts
        visualAlerts = try container.decodeIfPresent(Bool.self, forKey: .visualAlerts) ?? defaults.visualAlerts
        pitchSlipAlerts = try container.decodeIfPresent(Bool.self, forKey: .pitchSlipAlerts) ?? defaults.pitchSlipAlerts
        resonanceSlipAlerts = try container.decodeIfPresent(Bool.self, forKey: .resonanceSlipAlerts) ?? defaults.resonanceSlipAlerts
        sensitivity = try container.decodeIfPresent(SlipSensitivity.self, forKey: .sensitivity) ?? defaults.sensitivity
        strainWarnings = try container.decodeIfPresent(Bool.self, forKey: .strainWarnings) ?? defaults.strainWarnings
        eyesFreeTones = try container.decodeIfPresent(Bool.self, forKey: .eyesFreeTones) ?? defaults.eyesFreeTones
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hapticAlerts, forKey: .hapticAlerts)
        try container.encode(soundAlerts, forKey: .soundAlerts)
        try container.encode(visualAlerts, forKey: .visualAlerts)
        try container.encode(pitchSlipAlerts, forKey: .pitchSlipAlerts)
        try container.encode(resonanceSlipAlerts, forKey: .resonanceSlipAlerts)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(strainWarnings, forKey: .strainWarnings)
        try container.encode(eyesFreeTones, forKey: .eyesFreeTones)
    }

    /// Slip detection settings for the given target zone.
    func slipConfiguration(target: PitchTargetZone) -> SlipDetectorConfiguration {
        SlipDetectorConfiguration(
            target: target,
            sensitivity: sensitivity,
            watchesPitch: pitchSlipAlerts,
            watchesResonance: resonanceSlipAlerts
        )
    }
}

/// Keeps feedback settings on this device (moves into Settings / SwiftData later).
@MainActor
enum FeedbackSettingsStore {
    private static let key = "feedbackSettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> FeedbackSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(FeedbackSettings.self, from: data)
        else { return FeedbackSettings() }
        return settings
    }

    static func save(_ settings: FeedbackSettings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
