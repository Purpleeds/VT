import Foundation

/// Decides which frames are steady enough for formant and weight analysis.
///
/// Onsets, offsets and sudden pitch changes smear the spectrum, which makes
/// LPC formants and harmonic levels unreliable. A frame counts as stable when
/// it and the frames just before it are voiced, loud enough, and within a
/// narrow pitch range (slow glides still pass).
nonisolated struct VoiceStabilityTracker: Sendable {
    /// Consecutive voiced frames required, including the current one.
    let requiredFrames: Int
    /// Maximum pitch spread across those frames, in semitones.
    let maximumSpreadSemitones: Double

    private var recent: [Double] = []

    init(requiredFrames: Int = 3, maximumSpreadSemitones: Double = 1.0) {
        self.requiredFrames = max(1, requiredFrames)
        self.maximumSpreadSemitones = maximumSpreadSemitones
    }

    /// - Parameter frequency: The frame's filtered pitch, or nil if it isn't
    ///   a usable voiced frame (unvoiced, too quiet, or a held octave jump).
    /// - Returns: Whether this frame is stable.
    mutating func process(_ frequency: Double?) -> Bool {
        guard let frequency, frequency > 0, frequency.isFinite else {
            recent.removeAll(keepingCapacity: true)
            return false
        }
        recent.append(frequency)
        if recent.count > requiredFrames {
            recent.removeFirst(recent.count - requiredFrames)
        }
        guard recent.count >= requiredFrames,
              let lowest = recent.min(),
              let highest = recent.max()
        else { return false }
        return PitchMath.semitones(from: lowest, to: highest) <= maximumSpreadSemitones
    }

    mutating func reset() {
        recent.removeAll(keepingCapacity: true)
    }
}
