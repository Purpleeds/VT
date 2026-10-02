import Foundation
import Testing
@testable import VoiceBloom

@Suite("RecentAudioBuffer")
struct RecentAudioBufferTests {
    /// 10 samples per second keeps the numbers easy to follow.
    private let sampleRate = 10.0

    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map { Float($0) }
    }

    @Test("A clip has the newest samples and their place on the timeline")
    func clipTiming() throws {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        buffer.reset(sampleRate: sampleRate, startTime: 100)
        buffer.append(ramp(0..<20))
        #expect(buffer.availableDuration == 2)

        let clip = try #require(buffer.clip(lastSeconds: 1))
        #expect(clip.samples == ramp(10..<20))
        #expect(abs(clip.startTime - 101) < 1e-9)
        #expect(abs(clip.endTime - 102) < 1e-9)
        #expect(abs(clip.duration - 1) < 1e-9)
    }

    @Test("Only the last few seconds are kept")
    func wrapsAround() throws {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        buffer.reset(sampleRate: sampleRate, startTime: 0)
        buffer.append(ramp(0..<25))
        buffer.append(ramp(25..<47))
        #expect(buffer.availableDuration == 3)

        let clip = try #require(buffer.clip(lastSeconds: 10))
        #expect(clip.samples == ramp(17..<47))
        #expect(abs(clip.startTime - 1.7) < 1e-9)
        #expect(abs(clip.endTime - 4.7) < 1e-9)
    }

    @Test("Nothing to clip before any audio arrives")
    func emptyBuffer() {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        #expect(buffer.clip(lastSeconds: 1) == nil)
        buffer.reset(sampleRate: sampleRate, startTime: 0)
        #expect(buffer.clip(lastSeconds: 1) == nil)
    }

    @Test("Resuming after a pause keeps the audio and fills the gap with silence")
    func continuesAfterPause() throws {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        buffer.begin(sampleRate: sampleRate, startTime: 0)
        buffer.append(ramp(1..<11))  // 0.0–1.0 s
        buffer.begin(sampleRate: sampleRate, startTime: 1.3)
        buffer.append(ramp(21..<26))  // 1.3–1.8 s

        let clip = try #require(buffer.clip(lastSeconds: 3))
        #expect(clip.samples == ramp(1..<11) + [0, 0, 0] + ramp(21..<26))
        #expect(abs(clip.startTime - 0) < 1e-9)
        #expect(abs(clip.endTime - 1.8) < 1e-9)
    }

    @Test("A new timeline or sample rate starts empty")
    func restartsWhenDiscontinuous() throws {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        buffer.begin(sampleRate: sampleRate, startTime: 50)
        buffer.append(ramp(0..<10))

        // Earlier start time (the session was reset).
        buffer.begin(sampleRate: sampleRate, startTime: 0)
        buffer.append(ramp(100..<105))
        let afterReset = try #require(buffer.clip(lastSeconds: 3))
        #expect(afterReset.samples == ramp(100..<105))
        #expect(abs(afterReset.startTime - 0) < 1e-9)

        // Different sample rate (another microphone).
        buffer.begin(sampleRate: 20, startTime: 0.6)
        buffer.append(ramp(200..<204))
        let afterRouteChange = try #require(buffer.clip(lastSeconds: 3))
        #expect(afterRouteChange.samples == ramp(200..<204))
        #expect(afterRouteChange.sampleRate == 20)
    }

    @Test("removeAll forgets audio but keeps the timeline")
    func removeAll() throws {
        let buffer = RecentAudioBuffer(maximumDuration: 3)
        buffer.reset(sampleRate: sampleRate, startTime: 0)
        buffer.append(ramp(0..<10))
        buffer.removeAll()
        #expect(buffer.clip(lastSeconds: 3) == nil)
        buffer.append(ramp(10..<15))
        let clip = try #require(buffer.clip(lastSeconds: 3))
        #expect(clip.samples == ramp(10..<15))
        #expect(abs(clip.startTime - 1.0) < 1e-9)
    }

    @Test("The audio tap fills the recent-audio buffer")
    func tapRecordsAudio() throws {
        let tap = AudioTap(recentAudio: RecentAudioBuffer(maximumDuration: 3))
        tap.begin(sampleRate: sampleRate, startTime: 5)
        let samples = ramp(0..<8)
        samples.withUnsafeBufferPointer { tap.consume($0, startTime: 5) }
        let clip = try #require(tap.recentAudio.clip(lastSeconds: 3))
        #expect(clip.samples == samples)
        #expect(abs(clip.startTime - 5) < 1e-9)
    }
}
