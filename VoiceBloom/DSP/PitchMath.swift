import Foundation

/// Musical helpers: semitone distances, note names, and small statistics.
nonisolated enum PitchMath {
    /// Concert pitch: A4 = 440 Hz (MIDI note 69).
    static let referenceFrequency = 440.0
    static let referenceMidiNote = 69.0

    private static let sharpNoteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let spokenNoteNames = [
        "C", "C sharp", "D", "D sharp", "E", "F", "F sharp", "G", "G sharp", "A", "A sharp", "B",
    ]

    /// Distance in semitones from `from` to `to` (positive when `to` is higher).
    static func semitones(from: Double, to: Double) -> Double {
        guard from > 0, to > 0 else { return 0 }
        return 12 * log2(to / from)
    }

    /// Continuous MIDI note number (69 = A4). 196 Hz → 55.0 (G3).
    static func midiNote(for frequency: Double) -> Double {
        referenceMidiNote + semitones(from: referenceFrequency, to: frequency)
    }

    static func frequency(forMidiNote note: Double) -> Double {
        referenceFrequency * pow(2, (note - referenceMidiNote) / 12)
    }

    /// Nearest note name with octave, e.g. "G3" or "A♯3".
    static func noteName(for frequency: Double) -> String? {
        guard let note = nearestNote(for: frequency) else { return nil }
        return "\(sharpNoteNames[note.index])\(note.octave)"
    }

    /// Note name written for VoiceOver, e.g. "G sharp 3".
    static func spokenNoteName(for frequency: Double) -> String? {
        guard let note = nearestNote(for: frequency) else { return nil }
        return "\(spokenNoteNames[note.index]) \(note.octave)"
    }

    /// How far `frequency` is from its nearest note, in cents (−50...+50).
    static func centsFromNearestNote(for frequency: Double) -> Double? {
        guard frequency > 0, frequency.isFinite else { return nil }
        let note = midiNote(for: frequency)
        return (note - note.rounded()) * 100
    }

    /// Median of the values, or nil when empty.
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func nearestNote(for frequency: Double) -> (index: Int, octave: Int)? {
        guard frequency > 0, frequency.isFinite else { return nil }
        let note = Int(midiNote(for: frequency).rounded())
        let index = ((note % 12) + 12) % 12
        // MIDI 60 is C4, so octave = floor(note / 12) − 1.
        let octave = Int((Double(note) / 12).rounded(.down)) - 1
        return (index, octave)
    }
}
