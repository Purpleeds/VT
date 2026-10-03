import Foundation
import Synchronization

// MARK: - Settings

/// Clear Mic settings (SPEC section 24.8). Kept in UserDefaults like the mic
/// calibration, because they belong to this iPhone's microphone.
nonisolated struct ClearMicSettings: Sendable, Equatable, Codable {
    var strength: ClearMicStrength = .off
    /// Live analysis on the enhanced audio (true) or the raw audio (false,
    /// for comparing). Clear Mic Off always analyzes raw audio.
    var analyzesEnhancedAudio = true
    /// Lets Bluetooth headset microphones be used (off: AirPods only play
    /// sound and the iPhone's mic records, as before).
    var allowsBluetoothInput = false
    /// The input picked in Mic Check (`AVAudioSessionPortDescription.uid`).
    var preferredInputUID: String?
    var systemCheck: SystemModeCheckResult?
    /// Set only while the System Mode Check records with System mode (never saved).
    var isTestingSystemMode = false

    init() {}

    nonisolated private enum CodingKeys: String, CodingKey {
        case strength
        case analyzesEnhancedAudio
        case allowsBluetoothInput
        case preferredInputUID
        case systemCheck
    }

    /// Missing or unknown values fall back to the defaults, so settings saved
    /// by another version still load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawStrength = try container.decodeIfPresent(String.self, forKey: .strength)
        strength = rawStrength.flatMap { ClearMicStrength(rawValue: $0) } ?? .off
        analyzesEnhancedAudio = try container.decodeIfPresent(Bool.self, forKey: .analyzesEnhancedAudio) ?? true
        allowsBluetoothInput = try container.decodeIfPresent(Bool.self, forKey: .allowsBluetoothInput) ?? false
        preferredInputUID = try container.decodeIfPresent(String.self, forKey: .preferredInputUID)
        systemCheck = try? container.decodeIfPresent(SystemModeCheckResult.self, forKey: .systemCheck)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strength.rawValue, forKey: .strength)
        try container.encode(analyzesEnhancedAudio, forKey: .analyzesEnhancedAudio)
        try container.encode(allowsBluetoothInput, forKey: .allowsBluetoothInput)
        try container.encodeIfPresent(preferredInputUID, forKey: .preferredInputUID)
        try container.encodeIfPresent(systemCheck, forKey: .systemCheck)
    }

    /// System mode is only offered once the check has passed on this iPhone.
    var isSystemModeAvailable: Bool { systemCheck?.passed == true }

    /// The strength actually used (System falls back to Light until the
    /// check passes).
    var effectiveStrength: ClearMicStrength {
        strength == .system && !isSystemModeAvailable && !isTestingSystemMode ? .light : strength
    }

    /// The strength to show in the picker.
    var displayedStrength: ClearMicStrength {
        strength == .system && !isSystemModeAvailable ? .light : strength
    }

    var isEnhancing: Bool { effectiveStrength != .off }

    var captureOptions: CaptureOptions {
        CaptureOptions(
            voiceProcessing: effectiveStrength == .system,
            allowsBluetoothInput: allowsBluetoothInput,
            preferredInputUID: preferredInputUID
        )
    }
}

nonisolated enum ClearMicSettingsStore {
    static let key = "clearMic.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> ClearMicSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ClearMicSettings.self, from: data)
        else { return ClearMicSettings() }
        return settings
    }

    static func save(_ settings: ClearMicSettings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The saved room-noise profile (one, for the mic it was measured with).
nonisolated enum ClearMicProfileStore {
    static let key = "clearMic.noiseProfile.v1"

    static func load(from defaults: UserDefaults = .standard) -> ClearMicNoiseProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ClearMicNoiseProfile.self, from: data)
    }

    /// The saved profile when it fits the current sample rate and mic.
    static func load(sampleRate: Double, fftSize: Int, inputKind: AudioInputKind?, from defaults: UserDefaults = .standard) -> ClearMicNoiseProfile? {
        guard let profile = load(from: defaults),
              profile.matches(sampleRate: sampleRate, fftSize: fftSize),
              profile.inputKind == nil || inputKind == nil || profile.inputKind == inputKind
        else { return nil }
        return profile
    }

    static func save(_ profile: ClearMicNoiseProfile?, to defaults: UserDefaults = .standard) {
        guard let profile, let data = try? JSONEncoder().encode(profile) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Live status shared with the analysis thread

/// What the analysis thread reports about the microphone.
nonisolated struct ClearMicLiveStatus: Sendable, Equatable {
    /// Raw input level (dBFS, about the last 50 ms).
    var inputLevelDb = SignalLevel.silenceDb
    /// Loudest raw sample of the last ~1.5 s (dBFS; 0 = clipping).
    var peakDb = SignalLevel.silenceDb
    /// Raw background noise level (dBFS).
    var noiseFloorDb: Double?
    /// True while the live analysis hears enhanced audio.
    var isEnhancing = false
    var isGateOpen = true
    var isNoiseKnown = false
    /// 0…1 while "Sample Room Noise" runs.
    var captureProgress: Double?
    /// Extra delay of the enhanced audio (seconds; 0 when analyzing raw).
    var latency = 0.0

    var isClipping: Bool { peakDb >= MicCalibrationAnalysis.clippingPeakDb }
}

/// The meeting point of the main actor and the analysis thread: requests go
/// one way (strength changes, "sample room noise"), status and noise
/// profiles the other. Short locked sections, never on the audio I/O thread.
nonisolated final class ClearMicControl: Sendable {
    nonisolated struct State: Sendable {
        var parameters: ClearMicParameters?
        var revision = 0
        var captureRequest: Double?
        var status = ClearMicLiveStatus()
        var capturedProfile: ClearMicNoiseProfile?
        var latestProfile: ClearMicNoiseProfile?
    }

    private let state = Mutex(State())

    init() {}

    // Main actor side

    /// The processing to use from now on (nil = pass-through).
    func setParameters(_ parameters: ClearMicParameters?) {
        state.withLock { state in
            state.parameters = parameters
            state.revision += 1
        }
    }

    func requestNoiseCapture(seconds: Double) {
        state.withLock { $0.captureRequest = seconds }
    }

    var status: ClearMicLiveStatus {
        state.withLock { $0.status }
    }

    /// A freshly sampled room-noise profile, once.
    func takeCapturedProfile() -> ClearMicNoiseProfile? {
        state.withLock { state in
            let profile = state.capturedProfile
            state.capturedProfile = nil
            return profile
        }
    }

    /// The most recent learned profile (for saving).
    var latestProfile: ClearMicNoiseProfile? {
        state.withLock { $0.latestProfile }
    }

    /// Forgets the profiles waiting to be saved ("Delete All Data").
    func clearProfiles() {
        state.withLock { state in
            state.capturedProfile = nil
            state.latestProfile = nil
        }
    }

    // Analysis side

    /// New parameters when they changed since `revision`.
    func parameters(after revision: Int) -> (revision: Int, parameters: ClearMicParameters?)? {
        state.withLock { state -> (revision: Int, parameters: ClearMicParameters?)? in
            if state.revision == revision {
                return nil
            }
            return (revision: state.revision, parameters: state.parameters)
        }
    }

    var currentParameters: (revision: Int, parameters: ClearMicParameters?) {
        state.withLock { state -> (revision: Int, parameters: ClearMicParameters?) in
            (revision: state.revision, parameters: state.parameters)
        }
    }

    func takeCaptureRequest() -> Double? {
        state.withLock { state in
            let request = state.captureRequest
            state.captureRequest = nil
            return request
        }
    }

    func publish(_ status: ClearMicLiveStatus) {
        state.withLock { $0.status = status }
    }

    func publishCaptured(_ profile: ClearMicNoiseProfile) {
        state.withLock { state in
            state.capturedProfile = profile
            state.latestProfile = profile
        }
    }

    func publishLatest(_ profile: ClearMicNoiseProfile) {
        state.withLock { $0.latestProfile = profile }
    }
}

// MARK: - Noisy-room suggestion

/// A gentle hint when the room is loud (SPEC section 24.6).
nonisolated enum NoiseSuggestion: String, Sendable, Equatable {
    case turnOnClearMic
    case tryStrong
    case findQuieterSpot

    var title: String {
        switch self {
        case .turnOnClearMic: "It’s noisy here"
        case .tryStrong: "Still noisy"
        case .findQuieterSpot: "Very noisy here"
        }
    }

    var message: String {
        switch self {
        case .turnOnClearMic:
            "Background noise can throw off your readings. Turn on Clear Mic, or move somewhere quieter."
        case .tryStrong:
            "Clear Mic Strong handles loud places better, or try a quieter spot."
        case .findQuieterSpot:
            "Even with Clear Mic, this much noise makes readings less reliable. A quieter spot will help most."
        }
    }

    var actionTitle: String? {
        switch self {
        case .turnOnClearMic: "Turn On Clear Mic"
        case .tryStrong: "Use Strong"
        case .findQuieterSpot: nil
        }
    }

    /// The strength the action switches to.
    var suggestedStrength: ClearMicStrength? {
        switch self {
        case .turnOnClearMic: .light
        case .tryStrong: .strong
        case .findQuieterSpot: nil
        }
    }
}

/// Decides when to show the suggestion: noise above the strength's
/// threshold for 8 seconds, at most once per session.
nonisolated struct NoiseSuggestionTracker: Sendable, Equatable {
    static let sustainSeconds = 8.0

    private var noisySince: Double?
    private(set) var hasSuggested = false

    init() {}

    static func threshold(for strength: ClearMicStrength) -> Double {
        switch strength {
        case .off: -50
        case .light, .system: -42
        case .strong: -38
        }
    }

    static func suggestion(for strength: ClearMicStrength) -> NoiseSuggestion {
        switch strength {
        case .off: .turnOnClearMic
        case .light, .system: .tryStrong
        case .strong: .findQuieterSpot
        }
    }

    /// - Parameter time: Seconds on any steady clock.
    /// - Returns: A suggestion the first time the noise has stayed high long enough.
    mutating func update(noiseFloorDb: Double?, strength: ClearMicStrength, time: Double) -> NoiseSuggestion? {
        guard !hasSuggested, let noiseFloorDb, noiseFloorDb > Self.threshold(for: strength) else {
            noisySince = nil
            return nil
        }
        let start = noisySince ?? time
        noisySince = start
        guard time - start >= Self.sustainSeconds else { return nil }
        hasSuggested = true
        return Self.suggestion(for: strength)
    }

    /// A new practice session may suggest again.
    mutating func reset() {
        noisySince = nil
        hasSuggested = false
    }
}

/// Background noise badge (SPEC section 24.5), with the calibration's thresholds.
nonisolated enum MicNoiseBadge: String, Sendable, Equatable {
    case great
    case ok
    case tooNoisy

    init(noiseFloorDb: Double) {
        if noiseFloorDb <= MicCalibrationAnalysis.quietFloorDb {
            self = .great
        } else if noiseFloorDb <= MicCalibrationAnalysis.noisyFloorDb {
            self = .ok
        } else {
            self = .tooNoisy
        }
    }

    var title: String {
        switch self {
        case .great: "Great"
        case .ok: "OK"
        case .tooNoisy: "Too noisy"
        }
    }

    var systemImage: String {
        switch self {
        case .great: "checkmark.circle.fill"
        case .ok: "circle.lefthalf.filled"
        case .tooNoisy: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - System Mode Check

/// The numbers the System Mode Check compares for one take.
nonisolated struct PitchTakeMeasure: Sendable, Equatable, Codable {
    var medianPitch: Double?
    var voicedSeconds: Double
    /// Spread of the pitch around its median (cents, standard deviation).
    var pitchSpreadCents: Double?
    var sampleRate: Double

    init(medianPitch: Double?, voicedSeconds: Double, pitchSpreadCents: Double?, sampleRate: Double) {
        self.medianPitch = medianPitch
        self.voicedSeconds = voicedSeconds
        self.pitchSpreadCents = pitchSpreadCents
        self.sampleRate = sampleRate
    }

    init(take: TakeResult, sampleRate: Double) {
        medianPitch = take.medianPitch
        voicedSeconds = take.voicedDuration
        self.sampleRate = sampleRate
        if let median = take.medianPitch, median > 0, take.contour.count >= 5 {
            let cents = take.contour.map { 1_200 * log2($0.frequency / median) }
            let mean = cents.reduce(0, +) / Double(cents.count)
            let variance = cents.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(cents.count)
            pitchSpreadCents = variance.squareRoot()
        } else {
            pitchSpreadCents = nil
        }
    }
}

/// The result, saved so System mode can be offered (SPEC section 24.4).
nonisolated struct SystemModeCheckResult: Sendable, Equatable, Codable {
    var date: Date
    var passed: Bool
    /// Sample rate with voice processing on (Hz).
    var systemSampleRate: Double
    var normalSampleRate: Double
    var pitchDifferenceCents: Double?
    /// Voiced time with System ÷ with Light.
    var voicedRatio: Double?
    var reason: String
}

nonisolated enum SystemModeCheck {
    static let maximumPitchDifferenceCents = 15.0
    static let minimumVoicedRatio = 0.8
    static let maximumSpreadRatio = 1.5
    static let minimumSampleRate = 32_000.0

    /// Compares the same steady hum recorded with System and with Light.
    static func evaluate(
        system: PitchTakeMeasure,
        normal: PitchTakeMeasure,
        voiceProcessingWorked: Bool,
        date: Date = Date()
    ) -> SystemModeCheckResult {
        func result(_ passed: Bool, _ reason: String, difference: Double? = nil, ratio: Double? = nil) -> SystemModeCheckResult {
            SystemModeCheckResult(
                date: date,
                passed: passed,
                systemSampleRate: system.sampleRate,
                normalSampleRate: normal.sampleRate,
                pitchDifferenceCents: difference,
                voicedRatio: ratio,
                reason: reason
            )
        }
        guard voiceProcessingWorked else {
            return result(false, "iOS voice processing couldn’t start on this microphone.")
        }
        guard system.sampleRate >= minimumSampleRate else {
            return result(false, "Voice processing lowers the audio to \(system.sampleRate.roundedInt) Hz, too little for accurate resonance.")
        }
        guard let systemPitch = system.medianPitch, let normalPitch = normal.medianPitch, normal.voicedSeconds > 1 else {
            return result(false, "Not enough steady voice was heard. Hum a little louder and try again.")
        }
        let difference = 1_200 * log2(systemPitch / normalPitch)
        let ratio = system.voicedSeconds / normal.voicedSeconds
        guard abs(difference) <= maximumPitchDifferenceCents else {
            return result(false, "Pitch read \(abs(difference).roundedInt) cents differently with voice processing.", difference: difference, ratio: ratio)
        }
        guard ratio >= minimumVoicedRatio else {
            return result(false, "Voice processing muted part of your held note (it treats steady tones as noise).", difference: difference, ratio: ratio)
        }
        if let systemSpread = system.pitchSpreadCents, let normalSpread = normal.pitchSpreadCents,
           systemSpread > max(normalSpread, 5) * maximumSpreadRatio {
            return result(false, "Pitch was less steady with voice processing.", difference: difference, ratio: ratio)
        }
        return result(true, "Pitch matched within \(abs(difference).roundedInt) cents and your held note came through.", difference: difference, ratio: ratio)
    }
}
