import Foundation

nonisolated enum PitchFrameStatus: Sendable, Equatable {
    /// Loud enough and clearly pitched; counts toward statistics.
    case voiced
    /// Loud enough, but no clear pitch (breath, noise, whisper, consonant).
    case unpitched
    /// Too quiet: below the noise floor plus the voice-activity margin.
    case belowNoiseGate
    /// Sudden octave jump that is being held until it proves real.
    case octaveJumpHeld

    var displayName: String {
        switch self {
        case .voiced: "Voiced"
        case .unpitched: "No clear pitch"
        case .belowNoiseGate: "Below noise gate"
        case .octaveJumpHeld: "Octave jump held"
        }
    }
}

/// Everything the live pipeline knows about one ~43 ms analysis frame.
nonisolated struct PitchFrame: Sendable, Equatable {
    /// Seconds since listening started (centre of the frame).
    var time: Double
    var status: PitchFrameStatus
    /// Raw YIN output before gating and filtering (Hz).
    var rawFrequency: Double?
    /// YIN aperiodicity of the frame (0 = perfectly periodic, 1 = noise).
    var aperiodicity: Double
    /// Median-filtered pitch (Hz); set only for `.voiced` frames.
    var filteredFrequency: Double?
    /// Smoothed pitch for display (Hz); also set while a jump is held.
    var displayFrequency: Double?
    /// Frame loudness in dBFS.
    var levelDb: Double
    /// Current noise-floor estimate in dBFS.
    var noiseFloorDb: Double
    /// Level a frame must reach to count as possible voice (floor + margin).
    var gateThresholdDb: Double
    /// Wall-clock seconds spent analyzing this frame (for the debug screen).
    var processingDuration: Double

    var isVoiced: Bool { status == .voiced }
}
