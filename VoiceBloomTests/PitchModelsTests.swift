import Foundation
import Testing
@testable import VoiceBloom

/// Builds analysis frames for model tests.
nonisolated enum FrameFixture {
    static func frame(
        time: Double = 0,
        status: VoiceFrameStatus = .voiced,
        frequency: Double? = 200
    ) -> VoiceFrame {
        VoiceFrame(
            time: time,
            status: status,
            rawFrequency: frequency,
            aperiodicity: 0.05,
            filteredFrequency: status == .voiced ? frequency : nil,
            displayFrequency: frequency,
            levelDb: -20,
            peakDb: -12,
            noiseFloorDb: -60,
            gateThresholdDb: -52,
            isStable: status == .voiced,
            formants: nil,
            weight: nil,
            voiceQuality: nil,
            completedPhrase: nil,
            processingDuration: 0.0001
        )
    }
}

@Suite("PitchSessionStats")
struct PitchSessionStatsTests {
    @Test("Only voiced frames count toward % in target")
    func percentInTarget() throws {
        var stats = PitchSessionStats()
        #expect(stats.percentInTarget == nil)
        let target = PitchTargetZone.feminine // 180–220 Hz

        for frequency in [190.0, 200.0, 210.0, 150.0] {
            stats.add(FrameFixture.frame(frequency: frequency), target: target)
        }
        // Silence, noise, and held jumps are ignored.
        stats.add(FrameFixture.frame(status: .belowNoiseGate, frequency: nil), target: target)
        stats.add(FrameFixture.frame(status: .unpitched, frequency: nil), target: target)
        stats.add(FrameFixture.frame(status: .octaveJumpHeld, frequency: 400), target: target)

        #expect(stats.voicedFrameCount == 4)
        #expect(stats.inTargetFrameCount == 3)
        #expect(try #require(stats.percentInTarget) == 75)
        #expect(try #require(stats.averageFrequency) == 187.5)
        #expect(stats.minimumFrequency == 150)
        #expect(stats.maximumFrequency == 210)
        #expect(abs(stats.voicedDuration(frameInterval: 0.01) - 0.04) < 1e-12)
    }

    @Test("Target zone edges are inclusive")
    func edges() {
        let zone = PitchTargetZone(lowerBound: 180, upperBound: 220)
        #expect(zone.contains(180))
        #expect(zone.contains(220))
        #expect(!zone.contains(179.9))
        #expect(!zone.contains(220.1))
    }

    @Test("Target zone bounds are ordered")
    func orderedBounds() {
        let zone = PitchTargetZone(lowerBound: 220, upperBound: 180)
        #expect(zone.lowerBound == 180)
        #expect(zone.upperBound == 220)
        #expect(zone.formatted == "180–220 Hz")
    }
}

@Suite("PitchHistory")
struct PitchHistoryTests {
    @Test("Keeps the newest points in order when full")
    func ringOrder() {
        var history = PitchHistory(capacity: 4)
        #expect(history.latestTime == nil)
        for time in 0..<6 {
            history.append(PitchGraphPoint(frame: FrameFixture.frame(time: Double(time))))
        }
        #expect(history.count == 4)
        #expect(history.allPoints.map(\.time) == [2, 3, 4, 5])
        #expect(history.latestTime == 5)
    }

    @Test("Window query returns only points in range")
    func window() {
        var history = PitchHistory(capacity: 100)
        for time in 0..<10 {
            history.append(PitchGraphPoint(frame: FrameFixture.frame(time: Double(time))))
        }
        #expect(history.points(from: 3, through: 6).map(\.time) == [3, 4, 5, 6])
        history.removeAll()
        #expect(history.isEmpty)
        #expect(history.points(from: 0, through: 100).isEmpty)
    }

    @Test("Unvoiced frames leave a gap in the line; held jumps keep the previous value")
    func graphPointFromFrame() {
        #expect(PitchGraphPoint(frame: FrameFixture.frame(status: .belowNoiseGate, frequency: nil)).frequency == nil)
        #expect(PitchGraphPoint(frame: FrameFixture.frame(status: .unpitched, frequency: nil)).frequency == nil)
        let held = PitchGraphPoint(frame: FrameFixture.frame(status: .octaveJumpHeld, frequency: 200))
        #expect(held.frequency == 200)
        #expect(!held.isVoiced)
    }
}

@Suite("PitchGraphScale")
struct PitchGraphScaleTests {
    @Test("Log scale maps the range to 0...1")
    func mapping() {
        let scale = PitchGraphScale(lowerFrequency: 100, upperFrequency: 400)
        #expect(abs(scale.position(for: 100)) < 1e-12)
        #expect(abs(scale.position(for: 400) - 1) < 1e-12)
        // 200 Hz is one octave above 100 and one below 400: exactly halfway.
        #expect(abs(scale.position(for: 200) - 0.5) < 1e-12)
        #expect(scale.position(for: 50) == 0)
        #expect(scale.position(for: 1000) == 1)
    }

    @Test("Default range fits typical voices and the target zone", arguments: [PitchTargetZone.feminine, .androgynous])
    func defaultRange(target: PitchTargetZone) {
        let scale = PitchGraphScale(target: target)
        #expect(scale.lowerFrequency <= 85)
        #expect(scale.upperFrequency >= 300)
        #expect(scale.position(for: target.lowerBound) > 0)
        #expect(scale.position(for: target.upperBound) < 1)
        #expect(!scale.gridFrequencies.isEmpty)
    }
}
