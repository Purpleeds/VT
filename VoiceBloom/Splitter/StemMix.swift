import Foundation

/// What the mixer plays (SPEC section 23.2: A/B between original, vocals
/// and backing, plus the custom mix).
nonisolated enum StemListenMode: String, CaseIterable, Identifiable, Sendable {
    case mix
    case original
    case vocals
    case backing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: "Mix"
        case .original: "Original"
        case .vocals: "Vocals"
        case .backing: "Backing"
        }
    }
}

nonisolated enum StemPart: String, CaseIterable, Identifiable, Sendable {
    case vocals
    case backing

    var id: String { rawValue }
    var title: String { self == .vocals ? "Vocals" : "Backing" }
}

/// Mixer state: per-part volume (0–150 %), mute and solo, and the A/B mode.
/// "Original" is both parts at 100 %: the parts add back up to the source.
nonisolated struct StemMixSettings: Sendable, Equatable {
    static let volumeRange: ClosedRange<Double> = 0...1.5

    var vocalsVolume = 1.0
    var backingVolume = 1.0
    var vocalsMuted = false
    var backingMuted = false
    var vocalsSolo = false
    var backingSolo = false
    var mode = StemListenMode.mix

    func volume(_ part: StemPart) -> Double {
        part == .vocals ? vocalsVolume : backingVolume
    }

    func isMuted(_ part: StemPart) -> Bool {
        part == .vocals ? vocalsMuted : backingMuted
    }

    func isSolo(_ part: StemPart) -> Bool {
        part == .vocals ? vocalsSolo : backingSolo
    }

    /// The gain each part plays at right now.
    func gain(_ part: StemPart) -> Double {
        switch mode {
        case .original:
            return 1
        case .vocals:
            return part == .vocals ? 1 : 0
        case .backing:
            return part == .backing ? 1 : 0
        case .mix:
            let anySolo = vocalsSolo || backingSolo
            if anySolo, !isSolo(part) {
                return 0
            }
            if isMuted(part) {
                return 0
            }
            return min(max(volume(part), Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
        }
    }

    /// Gain in decibels for an EQ unit (silence handled separately).
    static func decibels(forGain gain: Double) -> Float {
        guard gain > 0.0001 else { return -96 }
        return Float(min(max(20 * log10(gain), -96), 24))
    }
}

/// Loop selection inside a track.
nonisolated struct LoopRange: Sendable, Equatable {
    var start: Double
    var end: Double

    static let minimumLength = 0.5

    /// A valid loop inside 0…duration, at least half a second long.
    static func make(start: Double, end: Double, duration: Double) -> LoopRange? {
        guard duration > minimumLength else { return nil }
        let lower = min(max(0, min(start, end)), duration)
        let upper = min(max(0, max(start, end)), duration)
        guard upper - lower >= minimumLength else { return nil }
        return LoopRange(start: lower, end: upper)
    }

    /// Where playback continues from `time` (wraps back to the start at the end).
    func position(after time: Double) -> Double {
        time >= end || time < start ? start : time
    }
}

/// Byte sizes for the storage screen.
nonisolated enum StorageFormat {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
