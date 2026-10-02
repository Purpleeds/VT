import Foundation
import Testing
@testable import VoiceBloom

@Suite("SlipDetector")
struct SlipDetectorTests {
    private let frameInterval = 512.0 / 48_000

    private func detector(
        _ sensitivity: SlipSensitivity = .standard,
        pitch: Bool = true,
        resonance: Bool = true
    ) -> SlipDetector {
        SlipDetector(configuration: SlipDetectorConfiguration(
            target: .feminine,
            sensitivity: sensitivity,
            watchesPitch: pitch,
            watchesResonance: resonance
        ))
    }

    /// A stretch of frames with the same pitch (nil = silence).
    private struct Segment {
        let pitch: Double?
        let seconds: Double
    }

    /// Feeds pitch segments frame by frame; returns events with their times.
    private func run(_ segments: [Segment], on detector: inout SlipDetector) -> [(time: Double, event: SlipEvent)] {
        var events: [(time: Double, event: SlipEvent)] = []
        var time = 0.0
        for segment in segments {
            let end = time + segment.seconds
            while time < end - 1e-9 {
                for event in detector.process(time: time, frequency: segment.pitch, resonanceScore: nil) {
                    events.append((time, event))
                }
                time += frameInterval
            }
        }
        return events
    }

    @Test("Standard sensitivity: floor is one semitone under the target zone")
    func configuration() {
        let configuration = SlipDetectorConfiguration(target: .feminine, sensitivity: .standard)
        #expect(abs(configuration.pitchFloor - 180 * pow(2, -1.0 / 12)) < 1e-9)
        #expect(configuration.delay == 2)
        #expect(SlipDetectorConfiguration(target: .feminine, sensitivity: .sensitive).pitchFloor == 180)
        #expect(SlipDetectorConfiguration(target: .feminine, sensitivity: .gentle).delay == 3)
    }

    @Test("Staying in the target zone never alerts")
    func onTarget() {
        var detector = detector()
        #expect(run([Segment(pitch: 200, seconds: 5)], on: &detector).isEmpty)
        #expect(detector.activeSlips.isEmpty)
    }

    @Test("More than 2 seconds below the target alerts once")
    func slipsAfterDelay() throws {
        var detector = detector()
        let events = run([Segment(pitch: 200, seconds: 1), Segment(pitch: 150, seconds: 3)], on: &detector)
        #expect(events.count == 1)
        let first = try #require(events.first)
        #expect(first.event == .slipped(.pitch))
        // Slipping started at 1 s, so the alert comes at ~3 s.
        #expect(abs(first.time - 3.0) < 0.02)
        #expect(detector.activeSlips == [.pitch])
    }

    @Test("A short dip doesn't alert")
    func shortDip() {
        var detector = detector()
        let events = run([
            Segment(pitch: 200, seconds: 1),
            Segment(pitch: 150, seconds: 1.5),
            Segment(pitch: 200, seconds: 2),
        ], on: &detector)
        #expect(events.isEmpty)
    }

    @Test("Coming back on target ends the slip after a moment")
    func recovers() throws {
        var detector = detector()
        let events = run([
            Segment(pitch: 150, seconds: 2.5),
            Segment(pitch: 200, seconds: 1),
        ], on: &detector)
        #expect(events.map { $0.event } == [.slipped(.pitch), .recovered(.pitch)])
        let recovery = try #require(events.last)
        // Back on target at 2.5 s, recovered 0.3 s later.
        #expect(abs(recovery.time - 2.8) < 0.03)
        #expect(detector.activeSlips.isEmpty)
    }

    @Test("Brief moments on target don't cancel a slip in progress")
    func briefExcursions() {
        var detector = detector()
        let events = run([
            Segment(pitch: 150, seconds: 1.2),
            Segment(pitch: 200, seconds: 0.2),
            Segment(pitch: 150, seconds: 1.0),
        ], on: &detector)
        #expect(events.map { $0.event } == [.slipped(.pitch)])
    }

    @Test("Gaps between words don't reset, but a real pause does")
    func pauses() {
        var shortGap = detector()
        let withShortGap = run([
            Segment(pitch: 150, seconds: 1.2),
            Segment(pitch: nil, seconds: 0.5),
            Segment(pitch: 150, seconds: 1.0),
        ], on: &shortGap)
        #expect(withShortGap.map { $0.event } == [.slipped(.pitch)])

        var longPause = detector()
        let withLongPause = run([
            Segment(pitch: 150, seconds: 1.5),
            Segment(pitch: nil, seconds: 1.5),
            Segment(pitch: 150, seconds: 1.0),
        ], on: &longPause)
        #expect(withLongPause.isEmpty)
    }

    @Test("A pause quietly clears an active slip (no “recovered” cue)")
    func pauseClearsSlip() {
        var detector = detector()
        let events = run([
            Segment(pitch: 150, seconds: 2.5),
            Segment(pitch: nil, seconds: 1.5),
        ], on: &detector)
        #expect(events.map { $0.event } == [.slipped(.pitch)])
        #expect(detector.activeSlips.isEmpty)
    }

    @Test("Sensitivity changes the delay and how far below counts")
    func sensitivity() {
        var gentle = detector(.gentle)
        // 165 Hz is below standard's floor (169.9) but above gentle's (160.4).
        #expect(run([Segment(pitch: 165, seconds: 4)], on: &gentle).isEmpty)
        var gentleLow = detector(.gentle)
        let gentleEvents = run([Segment(pitch: 150, seconds: 3.2)], on: &gentleLow)
        #expect(gentleEvents.map { $0.event } == [.slipped(.pitch)])
        #expect((gentleEvents.first?.time ?? 0) >= 3.0)

        var sensitive = detector(.sensitive)
        // Just under the zone counts, and only ~1.2 s is needed.
        let sensitiveEvents = run([Segment(pitch: 176, seconds: 1.5)], on: &sensitive)
        #expect(sensitiveEvents.map { $0.event } == [.slipped(.pitch)])
    }

    @Test("Turned-off channels never alert")
    func disabled() {
        var detector = detector(pitch: false)
        #expect(run([Segment(pitch: 120, seconds: 4)], on: &detector).isEmpty)
    }

    @Test("Resonance slips when the reading stays dark")
    func resonance() {
        var detector = detector()
        var events: [SlipEvent] = []
        var time = 0.0
        // A dark reading on roughly every other frame (stable frames only).
        while time < 2.6 {
            let index = Int((time / frameInterval).rounded())
            let score: Double? = index.isMultiple(of: 2) ? 20 : nil
            events += detector.process(time: time, frequency: 200, resonanceScore: score)
            time += frameInterval
        }
        #expect(events == [.slipped(.resonance)])
        #expect(detector.activeSlips == [.resonance])
    }

    @Test("Turning a channel off clears its slip")
    func disablingClears() {
        var detector = detector()
        _ = run([Segment(pitch: 150, seconds: 2.5)], on: &detector)
        #expect(detector.activeSlips == [.pitch])
        detector.configuration = SlipDetectorConfiguration(target: .feminine, watchesPitch: false)
        #expect(detector.activeSlips.isEmpty)
    }
}

@Suite("Time-in-target tallies")
struct TallyTests {
    @Test("Timed tally keeps only the last window")
    func timedTally() {
        var tally = TimedTally(duration: 10)
        #expect(tally.fraction == nil)
        for second in 0..<10 {
            tally.add(second < 5, at: Double(second))
        }
        #expect(tally.fraction == 0.5)
        // Five more misses push the early hits out of the 10 s window.
        for second in 10..<15 {
            tally.add(false, at: Double(second))
        }
        #expect(tally.count == 11)
        #expect(tally.hitCount == 0)
        tally.removeAll()
        #expect(tally.fraction == nil)
    }

    @Test("Zone tally percent")
    func zoneTally() {
        var tally = ZoneTally()
        #expect(tally.percent == nil)
        tally.add(true)
        tally.add(true)
        tally.add(false)
        tally.add(true)
        #expect(tally.percent == 75)
    }
}
