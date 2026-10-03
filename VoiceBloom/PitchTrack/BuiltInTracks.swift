import Foundation

/// Generated exercises so the mode works without uploads (SPEC section
/// 22.1: sirens, slides, 5-note scales, arpeggios, held notes in the target
/// zone, and speech intonation patterns), built around the target zone.
nonisolated enum BuiltInTrack: String, CaseIterable, Identifiable, Sendable {
    case siren
    case slides
    case fiveNoteScale
    case arpeggio
    case heldNotes
    case risingQuestions
    case fallingStatements
    case excitedSpeech

    var id: String { rawValue }

    /// A fixed id, so attempts can refer to built-in tracks like saved ones.
    var trackID: UUID {
        let suffix: String
        switch self {
        case .siren: suffix = "001"
        case .slides: suffix = "002"
        case .fiveNoteScale: suffix = "003"
        case .arpeggio: suffix = "004"
        case .heldNotes: suffix = "005"
        case .risingQuestions: suffix = "006"
        case .fallingStatements: suffix = "007"
        case .excitedSpeech: suffix = "008"
        }
        return UUID(uuidString: "B0117000-0000-4000-8000-000000000\(suffix)") ?? UUID()
    }

    var title: String {
        switch self {
        case .siren: "Siren"
        case .slides: "Slides"
        case .fiveNoteScale: "5-Note Scale"
        case .arpeggio: "Arpeggio"
        case .heldNotes: "Held Notes"
        case .risingQuestions: "Questions Rise"
        case .fallingStatements: "Statements Fall"
        case .excitedSpeech: "Excited Speech"
        }
    }

    var detail: String {
        switch self {
        case .siren: "A smooth slide up and down through your range, on an “ng” or “oo”."
        case .slides: "Glide from note to note without bumps."
        case .fiveNoteScale: "Do–re–mi–fa–so and back, stepping up a semitone each time."
        case .arpeggio: "Jump between the notes of a chord, up and back down."
        case .heldNotes: "Hold steady notes inside your target zone."
        case .risingQuestions: "Short questions that lift at the end."
        case .fallingStatements: "Calm statements that settle down at the end."
        case .excitedSpeech: "Lively phrases with big ups and downs."
        }
    }

    var systemImage: String {
        switch self {
        case .siren: "waveform.path"
        case .slides: "arrow.up.right"
        case .fiveNoteScale: "stairs"
        case .arpeggio: "music.note.list"
        case .heldNotes: "minus"
        case .risingQuestions: "questionmark.bubble"
        case .fallingStatements: "text.bubble"
        case .excitedSpeech: "exclamationmark.bubble"
        }
    }

    /// Intonation patterns are speech; the rest are pitch exercises.
    var isSpeechPattern: Bool {
        switch self {
        case .risingQuestions, .fallingStatements, .excitedSpeech: true
        case .siren, .slides, .fiveNoteScale, .arpeggio, .heldNotes: false
        }
    }

    static func track(id: UUID) -> BuiltInTrack? {
        allCases.first { $0.trackID == id }
    }

    /// The exercise's bars around the target zone. Resonance and weight
    /// targets are the user's own targets (score 100).
    func content(target: PitchTargetZone, references: PersonalReferences) -> PitchTrackContent {
        let low = PitchMath.midiNote(for: target.lowerBound)
        let high = PitchMath.midiNote(for: target.upperBound)
        let center = (low + high) / 2
        let speechReference = references.resonance(for: .speech)
        let resonance = BarResonance(f1: nil, f2: speechReference.targetF2, f3: speechReference.targetF3, score: 100)
        var builder = BarListBuilder(resonance: resonance)

        switch self {
        case .siren:
            let bottom = (low - 3).rounded()
            let top = (high + 3).rounded()
            for cycle in 0..<2 {
                let start = 0.5 + Double(cycle) * 5
                builder.curve(start: start, duration: 4, points: 41) { fraction in
                    // Up and back down on a smooth (cosine) path.
                    bottom + (top - bottom) * (1 - cos(2 * Double.pi * fraction)) / 2
                }
            }
        case .slides:
            let notes = [low.rounded(), center.rounded(), high.rounded(), (high + 2).rounded(), center.rounded(), low.rounded()]
            var time = 0.5
            for pair in zip(notes, notes.dropFirst()) {
                builder.curve(start: time, duration: 1.6, points: 17) { fraction in
                    // Hold the first note briefly, glide, then settle.
                    let glide = min(max((fraction - 0.25) / 0.5, 0), 1)
                    let eased = (1 - cos(Double.pi * glide)) / 2
                    return pair.0 + (pair.1 - pair.0) * eased
                }
                time += 2.1
            }
        case .fiveNoteScale:
            let steps = [0.0, 2, 4, 5, 7, 5, 4, 2, 0]
            var time = 0.5
            for root in [low.rounded() - 2, low.rounded() - 1, low.rounded()] {
                for step in steps {
                    builder.note(start: time, duration: 0.5, midi: root + step)
                    time += 0.6
                }
                time += 0.8
            }
        case .arpeggio:
            let steps = [0.0, 4, 7, 12, 7, 4, 0]
            var time = 0.5
            for root in [center.rounded() - 7, center.rounded() - 5] {
                for (index, step) in steps.enumerated() {
                    let isTop = index == 3
                    builder.note(start: time, duration: isTop ? 1.0 : 0.55, midi: root + step)
                    time += isTop ? 1.15 : 0.7
                }
                time += 0.8
            }
        case .heldNotes:
            var time = 0.5
            for note in [low.rounded(), center.rounded(), high.rounded(), center.rounded()] {
                builder.note(start: time, duration: 2.5, midi: note)
                time += 3.5
            }
        case .risingQuestions:
            builder.phrases(Self.questions, base: center, time: 0.5, shape: .rising)
        case .fallingStatements:
            builder.phrases(Self.statements, base: center, time: 0.5, shape: .falling)
        case .excitedSpeech:
            builder.phrases(Self.exclamations, base: center, time: 0.5, shape: .excited)
        }

        let bars = builder.bars
        let duration = (bars.last?.end ?? 0) + 1
        return PitchTrackContent(kind: .builtIn, duration: duration, bars: bars)
    }

    static let questions = [
        ["Are", "you", "coming", "tonight?"],
        ["Did", "you", "find", "it?"],
        ["Is", "this", "seat", "free?"],
        ["Can", "I", "help", "you?"],
    ]

    static let statements = [
        ["I'll", "see", "you", "tomorrow."],
        ["The", "train", "leaves", "at", "six."],
        ["That", "sounds", "good", "to", "me."],
        ["We", "can", "start", "now."],
    ]

    static let exclamations = [
        ["That's", "amazing", "news!"],
        ["I", "can't", "believe", "it!"],
        ["Look", "at", "this!"],
        ["We", "actually", "won!"],
    ]
}

/// Intonation shapes for the built-in speech patterns.
nonisolated enum IntonationShape: Sendable {
    case rising
    case falling
    case excited
}

/// Collects bars for a built-in track.
nonisolated struct BarListBuilder: Sendable {
    let resonance: BarResonance
    private(set) var bars: [TrackBar] = []

    init(resonance: BarResonance) {
        self.resonance = resonance
    }

    mutating func note(start: Double, duration: Double, midi: Double) {
        bars.append(TrackBar(index: bars.count, start: start, duration: duration, midi: midi, resonance: resonance, weightScore: 100))
    }

    /// A curved bar whose pitch follows `shape` (fraction 0…1 → semitones).
    mutating func curve(start: Double, duration: Double, points: Int, word: String? = nil, shape: (Double) -> Double) {
        let count = max(points, 2)
        let contour = (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            return TrackContourPoint(time: start + duration * fraction, midi: shape(fraction))
        }
        let median = PitchMath.median(of: contour.map(\.midi)) ?? 0
        bars.append(TrackBar(
            index: bars.count,
            start: start,
            duration: duration,
            midi: median,
            contour: contour,
            resonance: resonance,
            weightScore: 100,
            word: word
        ))
    }

    /// One curved bar per word, with a gentle downdrift across the phrase and
    /// the phrase's shape on the last word.
    mutating func phrases(_ phrases: [[String]], base: Double, time start: Double, shape: IntonationShape) {
        var time = start
        for words in phrases {
            for (index, word) in words.enumerated() {
                let isLast = index == words.count - 1
                let duration = min(0.65, 0.2 + 0.06 * Double(word.count)) + (isLast ? 0.2 : 0)
                let drift = -0.5 * Double(index)
                let level: Double
                switch shape {
                case .rising, .falling:
                    level = base + 1 + drift
                case .excited:
                    // Stressed words jump up; the rest sit lower.
                    level = base + (word.count >= 5 ? 4 : 0) + drift
                }
                curve(start: time, duration: duration, points: 9, word: word) { fraction in
                    switch shape {
                    case .rising:
                        return isLast ? level + 4 * fraction * fraction : level - 0.5 * fraction
                    case .falling:
                        return isLast ? level + 0.5 - 4 * fraction : level + 0.3 * sin(Double.pi * fraction)
                    case .excited:
                        return level + 2 * sin(Double.pi * fraction)
                    }
                }
                time += duration + 0.08
            }
            time += 1.0
        }
    }
}
