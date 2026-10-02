import Foundation
import Testing
@testable import VoiceBloom

@Suite("PitchTracker")
struct PitchTrackerTests {
    private let frameInterval = 512.0 / 48_000

    private func run(_ values: [Double?]) -> [TrackedPitch] {
        var tracker = PitchTracker(frameInterval: frameInterval)
        return values.map { tracker.process($0) }
    }

    /// `count` frames of the same raw estimate (nil = unvoiced).
    private func frames(_ value: Double?, _ count: Int) -> [Double?] {
        [Double?](repeating: value, count: count)
    }

    @Test("A steady pitch passes straight through")
    func steadyPitch() {
        let results = run(frames(200, 10))
        for result in results {
            #expect(result.status == .voiced)
            #expect(result.filteredFrequency == 200)
            #expect(result.displayFrequency == 200)
        }
    }

    @Test("A one-frame octave error is held back and doesn't disturb the contour")
    func singleOctaveErrorRejected() {
        let results = run(frames(200, 10) + frames(100, 1) + frames(200, 3))
        #expect(results[10].status == .octaveJumpHeld)
        #expect(results[10].filteredFrequency == nil)
        // The display keeps showing the previous pitch instead of dropping an octave.
        #expect(results[10].displayFrequency == 200)
        #expect(results[11].status == .voiced)
        #expect(results[11].filteredFrequency == 200)
    }

    @Test("A two-frame octave jump is still rejected")
    func twoFrameJumpRejected() {
        let results = run(frames(200, 10) + frames(400, 2) + frames(200, 1))
        #expect(results[10].status == .octaveJumpHeld)
        #expect(results[11].status == .octaveJumpHeld)
        #expect(results[12].status == .voiced)
        #expect(results[12].filteredFrequency == 200)
    }

    @Test("A jump that lasts 3+ frames is accepted as real")
    func sustainedJumpAccepted() throws {
        let results = run(frames(200, 10) + [400, 401, 399, 400] as [Double?])
        #expect(results[10].status == .octaveJumpHeld)
        #expect(results[11].status == .octaveJumpHeld)
        #expect(results[12].status == .voiced)
        let filtered = try #require(results[12].filteredFrequency)
        #expect(abs(filtered - 400) < 1.5)
        // The display jumps straight to the new register (no slow slide from 200 Hz).
        let display = try #require(results[12].displayFrequency)
        #expect(abs(display - 400) < 1.5)
        #expect(results[13].status == .voiced)
    }

    @Test("Halving (e.g. YIN locking onto a subharmonic) is also rejected")
    func halvingRejected() {
        let results = run(frames(300, 8) + frames(150, 1) + frames(300, 1))
        #expect(results[8].status == .octaveJumpHeld)
        #expect(results[9].status == .voiced)
        #expect(results[9].filteredFrequency == 300)
    }

    @Test("Median filter removes a single-frame spike that isn't an octave jump")
    func medianRemovesSpike() {
        let results = run(frames(200, 5) + frames(240, 1) + frames(200, 3))
        for result in results {
            #expect(result.status == .voiced)
            #expect(result.filteredFrequency == 200)
        }
    }

    @Test("Normal pitch changes are followed without being held")
    func glideIsFollowed() throws {
        // One octave up over one second: fast for speech, but smooth.
        let glide: [Double?] = (0..<94).map { 150 * pow(2, Double($0) / 94) }
        let results = run(glide)
        #expect(results.allSatisfy { $0.status == .voiced })
        let last = try #require(results.last?.filteredFrequency)
        #expect(last > 280)
    }

    @Test("After a pause between words the contour starts fresh")
    func resetsAfterSilence() {
        let results = run(frames(200, 5) + frames(nil, 5) + frames(400, 1))
        #expect(results[5].status == .unvoiced)
        #expect(results[10].status == .voiced)
        #expect(results[10].filteredFrequency == 400)
    }

    @Test("A very short gap keeps the octave check active")
    func shortGapKeepsReference() {
        let results = run(frames(200, 5) + frames(nil, 2) + frames(400, 1))
        #expect(results[7].status == .octaveJumpHeld)
    }

    @Test("Smoothing approaches a new pitch gradually without overshooting")
    func smoothingConverges() throws {
        let results = run(frames(200, 10) + frames(220, 30))
        let display = results[10...].compactMap(\.displayFrequency)
        #expect(display.count == 30)
        // Monotonic rise, never above the target.
        for index in 1..<display.count {
            #expect(display[index] >= display[index - 1])
            #expect(display[index] <= 220)
        }
        let final = try #require(display.last)
        #expect(abs(final - 220) < 0.5)
        // Responsive: within 2 Hz after ~100 ms (10 frames).
        #expect(abs(display[11] - 220) < 2)
    }

    @Test("Smoothing factor follows the frame interval")
    func smoothingFactorFromTimeConstant() {
        let tracker = PitchTracker(frameInterval: frameInterval)
        let expected = 1 - exp(-frameInterval / 0.03)
        #expect(abs(tracker.smoothingFactor - expected) < 1e-12)
    }

    @Test("Invalid input is treated as unvoiced")
    func invalidInput() {
        let results = run([0, -5, Double.nan, Double.infinity])
        #expect(results.allSatisfy { $0.status == .unvoiced })
    }

    @Test("reset() forgets the previous pitch")
    func manualReset() {
        var tracker = PitchTracker(frameInterval: frameInterval)
        for _ in 0..<5 {
            _ = tracker.process(200)
        }
        tracker.reset()
        let result = tracker.process(400)
        #expect(result.status == .voiced)
        #expect(result.filteredFrequency == 400)
    }
}
