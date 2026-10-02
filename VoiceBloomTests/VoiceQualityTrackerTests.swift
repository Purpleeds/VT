import Foundation
import Testing
@testable import VoiceBloom

@Suite("VoiceQualityTracker (strain warnings)")
struct VoiceQualityTrackerTests {
    private let normal = VoiceQualityMeasurement(jitterPercent: 0.5, shimmerPercent: 3.0, harmonicsToNoiseDb: 20, cycleCount: 6)
    /// 50% rougher on every measure (HNR 3.5 dB lower = 1.5× the noise).
    private let rough = VoiceQualityMeasurement(
        jitterPercent: 0.75,
        shimmerPercent: 4.5,
        harmonicsToNoiseDb: 20 - 20 * log10(1.5),
        cycleCount: 6
    )

    private struct Segment {
        let measurement: VoiceQualityMeasurement?
        let seconds: Double
    }

    /// Feeds 20 measurements a second and evaluates after each.
    /// - Returns: When the warm-up completed and when warnings fired.
    private func run(_ segments: [Segment], on tracker: inout VoiceQualityTracker) -> (warmup: Double?, warnings: [Double], lastRatio: Double?) {
        var time = 0.0
        var warmup: Double?
        var warnings: [Double] = []
        var lastRatio: Double?
        for segment in segments {
            let end = time + segment.seconds
            while time < end - 1e-9 {
                if let measurement = segment.measurement, tracker.add(measurement, at: time) != nil, warmup == nil {
                    warmup = time
                }
                let evaluation = tracker.evaluate(now: time)
                if evaluation.shouldWarn {
                    warnings.append(time)
                }
                lastRatio = evaluation.assessment?.roughnessRatio
                time += 0.05
            }
        }
        return (warmup, warnings, lastRatio)
    }

    @Test("The first 200 measurements of a session define its warm-up")
    func warmup() throws {
        var tracker = VoiceQualityTracker(storedNorms: nil)
        #expect(tracker.isLearning)
        var earlySummaries = 0
        for index in 0..<199 {
            if tracker.add(normal, at: Double(index) * 0.05) != nil {
                earlySummaries += 1
            }
        }
        #expect(earlySummaries == 0)
        let completed = tracker.add(normal, at: 10)
        let summary = try #require(completed)
        #expect(summary.jitterPercent == 0.5)
        #expect(summary.sampleCount == 200)
        #expect(!tracker.isLearning)
        // Only once per session.
        let again = tracker.add(normal, at: 10.05)
        #expect(again == nil)
    }

    @Test("A steady voice never triggers a warning")
    func steadyVoice() throws {
        var tracker = VoiceQualityTracker(storedNorms: nil)
        let result = run([Segment(measurement: normal, seconds: 60)], on: &tracker)
        #expect(result.warnings.isEmpty)
        let ratio = try #require(result.lastRatio)
        #expect(abs(ratio - 1) < 1e-9)
    }

    @Test("Clearly rougher than normal for a while → one warning")
    func roughVoiceWarnsOnce() throws {
        var tracker = VoiceQualityTracker(storedNorms: nil)
        let result = run([
            Segment(measurement: normal, seconds: 15),
            Segment(measurement: rough, seconds: 45),
        ], on: &tracker)
        #expect(result.warnings.count == 1)
        let warning = try #require(result.warnings.first)
        // Needs the recent median to turn rough, then 10 s of sustained roughness.
        #expect(warning >= 25 && warning <= 40)
        let ratio = try #require(result.lastRatio)
        #expect(abs(ratio - 1.5) < 1e-6)
    }

    @Test("No second warning within the cooldown, even after recovering")
    func cooldown() {
        var tracker = VoiceQualityTracker(storedNorms: nil)
        let segments = [
            Segment(measurement: normal, seconds: 15),
            Segment(measurement: rough, seconds: 35),
            Segment(measurement: normal, seconds: 25),
            Segment(measurement: rough, seconds: 40),
        ]
        #expect(run(segments, on: &tracker).warnings.count == 1)

        var configuration = VoiceQualityTrackerConfiguration()
        configuration.warningCooldown = 10
        var shortCooldown = VoiceQualityTracker(storedNorms: nil, configuration: configuration)
        // Recovering re-arms the warning; with a short cooldown it can fire again.
        #expect(run(segments, on: &shortCooldown).warnings.count == 2)
    }

    @Test("Stored norms from 2+ sessions are used right away")
    func storedNorms() throws {
        let norms = VoiceQualityNorms(jitterPercent: 0.5, shimmerPercent: 3, harmonicsToNoiseDb: 20, sessionCount: 2)
        var tracker = VoiceQualityTracker(storedNorms: norms)
        #expect(!tracker.isLearning)
        #expect(tracker.reference?.usesStoredNorms == true)
        let result = run([Segment(measurement: rough, seconds: 40)], on: &tracker)
        #expect(result.warnings.count == 1)
        #expect((result.warnings.first ?? 0) < 20)
    }

    @Test("Norms from a single session aren't trusted yet")
    func youngNorms() {
        let norms = VoiceQualityNorms(jitterPercent: 0.5, shimmerPercent: 3, harmonicsToNoiseDb: 20, sessionCount: 1)
        var tracker = VoiceQualityTracker(storedNorms: norms)
        #expect(tracker.isLearning)
        // This session's own (rough) start becomes the reference, so no warning.
        #expect(run([Segment(measurement: rough, seconds: 40)], on: &tracker).warnings.isEmpty)
    }

    @Test("Too little recent voice gives no assessment")
    func tooLittleData() {
        var tracker = VoiceQualityTracker(storedNorms: nil)
        _ = run([Segment(measurement: normal, seconds: 15)], on: &tracker)
        // A long silence empties the 20 s window.
        let evaluation = tracker.evaluate(now: 60)
        #expect(evaluation.assessment == nil)
        #expect(!evaluation.shouldWarn)
    }

    @Test("Roughness ratio averages the three measures")
    func ratio() throws {
        let recent = VoiceQualitySummary(jitterPercent: 0.6, shimmerPercent: 3.6, harmonicsToNoiseDb: 18, sampleCount: 100)
        let reference = VoiceQualitySummary(jitterPercent: 0.5, shimmerPercent: 3.0, harmonicsToNoiseDb: 20, sampleCount: 100)
        let ratio = try #require(VoiceQualityTracker.roughnessRatio(recent: recent, reference: reference))
        let expected = (1.2 + 1.2 + pow(10, 2.0 / 20)) / 3
        #expect(abs(ratio - expected) < 1e-12)
        let empty = VoiceQualitySummary(jitterPercent: nil, shimmerPercent: nil, harmonicsToNoiseDb: nil, sampleCount: 0)
        #expect(VoiceQualityTracker.roughnessRatio(recent: empty, reference: reference) == nil)
    }

    @Test("Norms start from a full summary and then blend slowly")
    func normsBlend() throws {
        let partial = VoiceQualitySummary(jitterPercent: 0.5, shimmerPercent: nil, harmonicsToNoiseDb: 20, sampleCount: 200)
        #expect(VoiceQualityNorms(summary: partial) == nil)
        let first = try #require(VoiceQualityNorms(summary: VoiceQualitySummary(jitterPercent: 0.5, shimmerPercent: 3, harmonicsToNoiseDb: 20, sampleCount: 200)))
        #expect(first.sessionCount == 1)
        let next = first.blended(with: VoiceQualitySummary(jitterPercent: 1.0, shimmerPercent: 3, harmonicsToNoiseDb: nil, sampleCount: 200))
        #expect(abs(next.jitterPercent - 0.65) < 1e-12)
        #expect(next.harmonicsToNoiseDb == 20)
        #expect(next.sessionCount == 2)
    }

    @Test("Norms store saves and loads")
    @MainActor
    func normsStore() throws {
        let suite = "VoiceBloomTests.norms.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VoiceQualityNormsStore.load(from: defaults) == nil)
        let norms = VoiceQualityNorms(jitterPercent: 0.4, shimmerPercent: 2.5, harmonicsToNoiseDb: 22, sessionCount: 3)
        VoiceQualityNormsStore.save(norms, to: defaults)
        #expect(VoiceQualityNormsStore.load(from: defaults) == norms)
    }
}
