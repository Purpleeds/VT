import Foundation

/// Everything worth saving about the current practice session, captured
/// from `LiveVoiceMonitor` as plain values.
nonisolated struct SessionSnapshot: Sendable, Equatable {
    let id: UUID
    let startDate: Date
    /// Seconds spent listening (pauses excluded).
    let activeDuration: Double
    /// Seconds of clearly voiced sound.
    let voicedDuration: Double
    let averagePitch: Double?
    let minimumPitch: Double?
    let maximumPitch: Double?
    let percentInTarget: Double?
    let target: PitchTargetZone
    let resonanceScore: Double?
    let brightResonancePercent: Double?
    let resonanceMode: ResonanceMode
    let weightScore: Double?
    let intonationScore: Double?
    let jitterPercent: Double?
    let shimmerPercent: Double?
    let harmonicsToNoiseDb: Double?
    let slipAlertCount: Int
    let strainWarningCount: Int

    /// Builds a snapshot from the monitor's session statistics.
    init(
        id: UUID,
        startDate: Date,
        activeDuration: Double,
        frameInterval: Double,
        stats: VoiceSessionStats,
        voiceQuality: VoiceQualitySummary?,
        target: PitchTargetZone,
        resonanceMode: ResonanceMode,
        slipAlertCount: Int,
        strainWarningCount: Int
    ) {
        self.id = id
        self.startDate = startDate
        self.activeDuration = activeDuration
        voicedDuration = stats.pitch.voicedDuration(frameInterval: frameInterval)
        averagePitch = stats.pitch.averageFrequency
        minimumPitch = stats.pitch.minimumFrequency
        maximumPitch = stats.pitch.maximumFrequency
        percentInTarget = stats.pitch.percentInTarget
        self.target = target
        resonanceScore = stats.resonance.mean
        brightResonancePercent = stats.brightResonance.percent
        self.resonanceMode = resonanceMode
        weightScore = stats.weight.mean
        intonationScore = stats.intonation.mean
        jitterPercent = voiceQuality?.jitterPercent
        shimmerPercent = voiceQuality?.shimmerPercent
        harmonicsToNoiseDb = voiceQuality?.harmonicsToNoiseDb
        self.slipAlertCount = slipAlertCount
        self.strainWarningCount = strainWarningCount
    }
}
