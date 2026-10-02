import Foundation
import Testing
@testable import VoiceBloom

@Suite("PitchMath")
struct PitchMathTests {
    @Test("Note names", arguments: [
        (440.0, "A4"),
        (261.63, "C4"),
        (196.0, "G3"),
        (233.08, "A♯3"),
        (110.0, "A2"),
        (82.41, "E2"),
        (523.25, "C5"),
    ])
    func noteNames(frequency: Double, expected: String) {
        #expect(PitchMath.noteName(for: frequency) == expected)
    }

    @Test("Spoken note names are VoiceOver-friendly")
    func spokenNames() {
        #expect(PitchMath.spokenNoteName(for: 233.08) == "A sharp 3")
        #expect(PitchMath.spokenNoteName(for: 196) == "G 3")
    }

    @Test("Invalid frequencies have no note")
    func invalidNotes() {
        #expect(PitchMath.noteName(for: 0) == nil)
        #expect(PitchMath.noteName(for: -100) == nil)
        #expect(PitchMath.noteName(for: .nan) == nil)
    }

    @Test("Semitone distances")
    func semitones() {
        #expect(abs(PitchMath.semitones(from: 100, to: 200) - 12) < 1e-9)
        #expect(abs(PitchMath.semitones(from: 200, to: 100) + 12) < 1e-9)
        #expect(abs(PitchMath.semitones(from: 440, to: 466.16) - 1) < 0.001)
        #expect(PitchMath.semitones(from: 0, to: 100) == 0)
    }

    @Test("MIDI conversion round-trips")
    func midiRoundTrip() {
        #expect(abs(PitchMath.midiNote(for: 440) - 69) < 1e-9)
        for note in stride(from: 30.0, through: 80.0, by: 7.5) {
            let frequency = PitchMath.frequency(forMidiNote: note)
            #expect(abs(PitchMath.midiNote(for: frequency) - note) < 1e-9)
        }
    }

    @Test("Cents from nearest note")
    func cents() throws {
        let inTune = try #require(PitchMath.centsFromNearestNote(for: 440))
        #expect(abs(inTune) < 1e-9)
        // A quarter of a semitone sharp of A4.
        let quarterSharp = PitchMath.frequency(forMidiNote: 69.25)
        let sharp = try #require(PitchMath.centsFromNearestNote(for: quarterSharp))
        #expect(abs(sharp - 25) < 1e-6)
    }

    @Test("Median")
    func median() {
        #expect(PitchMath.median(of: []) == nil)
        #expect(PitchMath.median(of: [3]) == 3)
        #expect(PitchMath.median(of: [5, 1, 3]) == 3)
        #expect(PitchMath.median(of: [4, 1, 3, 2]) == 2.5)
        #expect(PitchMath.median(of: [200, 200, 100, 200, 400]) == 200)
    }
}
