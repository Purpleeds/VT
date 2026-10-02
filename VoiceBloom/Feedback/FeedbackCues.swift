import Foundation

/// One haptic event: a tap (duration 0) or a soft buzz (duration > 0).
nonisolated struct HapticEventDescription: Sendable, Equatable {
    /// Start time within the pattern (seconds).
    let time: Double
    /// 0 for a transient tap, otherwise the length of a continuous buzz.
    let duration: Double
    /// Strength, 0...1.
    let intensity: Double
    /// 0 = round and dull, 1 = crisp.
    let sharpness: Double

    var isTransient: Bool { duration <= 0 }
}

/// A short haptic pattern, described as plain data so it can be tested
/// without a Taptic Engine.
nonisolated struct HapticPatternDescription: Sendable, Equatable {
    let events: [HapticEventDescription]

    /// When the last event ends (taps count as ~50 ms).
    var duration: Double {
        events.map { $0.time + max($0.duration, 0.05) }.max() ?? 0
    }

    /// Two soft, round taps: "pitch is drifting down".
    static let pitchSlip = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0, intensity: 0.55, sharpness: 0.3),
        HapticEventDescription(time: 0.16, duration: 0, intensity: 0.55, sharpness: 0.3),
    ])

    /// One soft, low buzz: "resonance is darkening".
    static let resonanceSlip = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0.28, intensity: 0.45, sharpness: 0.1),
    ])

    /// Both at once: buzz then two taps.
    static let bothSlip = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0.24, intensity: 0.45, sharpness: 0.1),
        HapticEventDescription(time: 0.32, duration: 0, intensity: 0.55, sharpness: 0.3),
        HapticEventDescription(time: 0.48, duration: 0, intensity: 0.55, sharpness: 0.3),
    ])

    /// A single light, crisp tap: "back on target".
    static let recovered = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0, intensity: 0.35, sharpness: 0.8),
    ])

    /// Two long, gentle swells: "take a break".
    static let strain = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0.4, intensity: 0.4, sharpness: 0.15),
        HapticEventDescription(time: 0.6, duration: 0.4, intensity: 0.4, sharpness: 0.15),
    ])

    /// One soft tap: eyes-free listening has started.
    static let started = HapticPatternDescription(events: [
        HapticEventDescription(time: 0, duration: 0, intensity: 0.4, sharpness: 0.5),
    ])
}

/// One note of a feedback chime.
nonisolated struct ToneNote: Sendable, Equatable {
    let frequency: Double
    let start: Double
    let duration: Double
}

/// A soft chime, rendered to samples on demand.
nonisolated struct ToneSequence: Sendable, Equatable {
    let notes: [ToneNote]
    /// Peak level of each note (full scale = 1).
    let amplitude: Double

    var duration: Double {
        notes.map { $0.start + $0.duration }.max() ?? 0
    }

    /// Renders mono samples. Each note has a 10 ms fade-in, a gentle decay
    /// and a 20 ms fade-out, so it starts and stops without clicks.
    func render(sampleRate: Double) -> [Float] {
        let count = max(0, Int((duration * sampleRate).rounded(.up)))
        var samples = [Double](repeating: 0, count: count)
        for note in notes {
            let first = max(0, Int((note.start * sampleRate).rounded()))
            let length = Int((note.duration * sampleRate).rounded())
            let omega = 2 * Double.pi * note.frequency / sampleRate
            for offset in 0..<max(0, length) {
                let index = first + offset
                guard index < count else { break }
                let time = Double(offset) / sampleRate
                let attack = min(1, time / 0.01)
                let release = min(1, (note.duration - time) / 0.02)
                let decay = exp(-3 * time / note.duration)
                let envelope = max(0, attack * release * decay)
                samples[index] += amplitude * envelope * sin(omega * Double(offset))
            }
        }
        return samples.map { Float(min(max($0, -1), 1)) }
    }

    /// Falling two-note chime: slipping.
    static let slip = ToneSequence(notes: [
        ToneNote(frequency: 784, start: 0, duration: 0.16),
        ToneNote(frequency: 659, start: 0.16, duration: 0.24),
    ], amplitude: 0.25)

    /// Rising two-note chime: back on target.
    static let recovered = ToneSequence(notes: [
        ToneNote(frequency: 659, start: 0, duration: 0.12),
        ToneNote(frequency: 880, start: 0.12, duration: 0.18),
    ], amplitude: 0.2)

    /// One soft, low note: take a break.
    static let strain = ToneSequence(notes: [
        ToneNote(frequency: 523, start: 0, duration: 0.5),
    ], amplitude: 0.22)

    /// Short high note: listening has started.
    static let started = ToneSequence(notes: [
        ToneNote(frequency: 880, start: 0, duration: 0.15),
    ], amplitude: 0.18)
}

/// Something the app tells the user without words.
nonisolated enum FeedbackCue: Sendable, Equatable {
    case slip(Set<SlipChannel>)
    case recovered
    case strain
    case started

    var haptic: HapticPatternDescription {
        switch self {
        case .slip(let channels):
            if channels.count > 1 { return .bothSlip }
            return channels.contains(.resonance) ? .resonanceSlip : .pitchSlip
        case .recovered: return .recovered
        case .strain: return .strain
        case .started: return .started
        }
    }

    var tone: ToneSequence {
        switch self {
        case .slip: .slip
        case .recovered: .recovered
        case .strain: .strain
        case .started: .started
        }
    }
}
