import Foundation

/// Running pitch statistics for the current practice session.
/// Only `.voiced` frames count, so silence and breaths never lower the score.
nonisolated struct PitchSessionStats: Sendable, Equatable {
    private(set) var voicedFrameCount = 0
    private(set) var inTargetFrameCount = 0
    private(set) var frequencySum = 0.0
    private(set) var minimumFrequency: Double?
    private(set) var maximumFrequency: Double?

    mutating func add(_ frame: VoiceFrame, target: PitchTargetZone) {
        guard frame.status == .voiced, let frequency = frame.filteredFrequency else { return }
        voicedFrameCount += 1
        frequencySum += frequency
        if target.contains(frequency) {
            inTargetFrameCount += 1
        }
        minimumFrequency = min(minimumFrequency ?? frequency, frequency)
        maximumFrequency = max(maximumFrequency ?? frequency, frequency)
    }

    /// Percentage (0–100) of voiced time spent inside the target zone.
    var percentInTarget: Double? {
        guard voicedFrameCount > 0 else { return nil }
        return Double(inTargetFrameCount) / Double(voicedFrameCount) * 100
    }

    var averageFrequency: Double? {
        guard voicedFrameCount > 0 else { return nil }
        return frequencySum / Double(voicedFrameCount)
    }

    /// Seconds of voiced audio, given the time between frames.
    func voicedDuration(frameInterval: Double) -> Double {
        Double(voicedFrameCount) * frameInterval
    }
}
