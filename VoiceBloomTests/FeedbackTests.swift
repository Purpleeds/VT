import Foundation
import Testing
@testable import VoiceBloom

@Suite("Feedback settings")
struct FeedbackSettingsTests {
    @Test("Defaults: haptic and visual on, sound off")
    func defaults() {
        let settings = FeedbackSettings()
        #expect(settings.hapticAlerts)
        #expect(settings.visualAlerts)
        #expect(!settings.soundAlerts)
        #expect(settings.sensitivity == .standard)
        #expect(settings.strainWarnings)
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        var settings = FeedbackSettings()
        settings.soundAlerts = true
        settings.sensitivity = .gentle
        settings.resonanceSlipAlerts = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(FeedbackSettings.self, from: data) == settings)
    }

    @Test("Missing keys fall back to defaults")
    func missingKeys() throws {
        let empty = try JSONDecoder().decode(FeedbackSettings.self, from: Data("{}".utf8))
        #expect(empty == FeedbackSettings())
        let partial = try JSONDecoder().decode(FeedbackSettings.self, from: Data(#"{"soundAlerts": true}"#.utf8))
        #expect(partial.soundAlerts)
        #expect(partial.hapticAlerts)
    }

    @Test("Slip configuration follows the settings")
    func slipConfiguration() {
        var settings = FeedbackSettings()
        settings.sensitivity = .sensitive
        settings.pitchSlipAlerts = false
        let configuration = settings.slipConfiguration(target: .androgynous)
        #expect(configuration.pitchFloor == 150)
        #expect(configuration.delay == 1.2)
        #expect(!configuration.watchesPitch)
        #expect(configuration.watchesResonance)
    }

    @Test("Store saves and loads, with defaults when empty")
    @MainActor
    func store() throws {
        let suite = "VoiceBloomTests.feedback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FeedbackSettingsStore.load(from: defaults) == FeedbackSettings())
        var settings = FeedbackSettings()
        settings.visualAlerts = false
        FeedbackSettingsStore.save(settings, to: defaults)
        #expect(FeedbackSettingsStore.load(from: defaults) == settings)
    }
}

@Suite("Feedback cues")
struct FeedbackCueTests {
    private let allPatterns: [HapticPatternDescription] = [
        .pitchSlip, .resonanceSlip, .bothSlip, .recovered, .strain, .started,
    ]

    @Test("Haptic patterns are short, gentle and valid")
    func patternsAreValid() {
        for pattern in allPatterns {
            #expect(!pattern.events.isEmpty)
            #expect(pattern.duration > 0 && pattern.duration < 1.2)
            for event in pattern.events {
                #expect((0...1).contains(event.intensity))
                #expect((0...1).contains(event.sharpness))
                // "Gentle": never full strength.
                #expect(event.intensity <= 0.6)
                #expect(event.time >= 0)
            }
        }
    }

    @Test("Pitch and resonance slips feel different")
    func distinctPatterns() {
        #expect(HapticPatternDescription.pitchSlip.events.allSatisfy(\.isTransient))
        #expect(HapticPatternDescription.pitchSlip.events.count == 2)
        #expect(HapticPatternDescription.resonanceSlip.events.contains { !$0.isTransient })
        #expect(FeedbackCue.slip([.pitch]).haptic == .pitchSlip)
        #expect(FeedbackCue.slip([.resonance]).haptic == .resonanceSlip)
        #expect(FeedbackCue.slip([.pitch, .resonance]).haptic == .bothSlip)
        #expect(FeedbackCue.recovered.haptic == .recovered)
    }

    @Test("Chimes render without clicks and stay soft", arguments: [ToneSequence.slip, .recovered, .strain, .started])
    func tones(tone: ToneSequence) throws {
        let samples = tone.render(sampleRate: 48_000)
        #expect(samples.count == Int((tone.duration * 48_000).rounded(.up)))
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.01)
        #expect(Double(peak) <= tone.amplitude + 1e-6)
        // Fades in and out: the very first and last samples are near silent.
        let first = try #require(samples.first)
        let last = try #require(samples.last)
        #expect(abs(first) < 0.01)
        #expect(abs(last) < 0.02)
    }

    @Test("Tone duration covers every note")
    func toneDuration() {
        #expect(abs(ToneSequence.slip.duration - 0.4) < 1e-12)
        #expect(ToneSequence(notes: [], amplitude: 0.2).render(sampleRate: 48_000).isEmpty)
    }
}
