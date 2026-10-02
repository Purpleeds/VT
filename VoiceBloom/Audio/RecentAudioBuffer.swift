import Foundation
import Synchronization

/// A stretch of captured audio with its place on the session timeline.
nonisolated struct AudioClip: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    /// Audio time (seconds, same clock as `VoiceFrame.time`) of the first sample.
    let startTime: Double

    var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    var endTime: Double { startTime + duration }
}

/// Keeps the last ~30 seconds of microphone audio in memory, so "save this"
/// can keep what was just said.
///
/// Written by the background analysis task and read on the main actor;
/// a mutex protects the ring (both sides are short and never real-time).
nonisolated final class RecentAudioBuffer: Sendable {
    let maximumDuration: Double

    nonisolated private struct State {
        var storage: [Float] = []
        var writeIndex = 0
        var count = 0
        var sampleRate = 48_000.0
        /// Audio time just after the newest sample.
        var endTime = 0.0
    }

    private let state = Mutex(State())

    init(maximumDuration: Double = 30) {
        self.maximumDuration = max(1, maximumDuration)
    }

    /// Clears the buffer for a new listening run.
    func reset(sampleRate: Double, startTime: Double) {
        let capacity = max(1, Int((sampleRate * maximumDuration).rounded(.up)))
        state.withLock { state in
            if state.storage.count != capacity {
                state.storage = [Float](repeating: 0, count: capacity)
            }
            state.writeIndex = 0
            state.count = 0
            state.sampleRate = sampleRate
            state.endTime = startTime
        }
    }

    /// Prepares for a listening run whose first sample is at `startTime`.
    ///
    /// When the run continues the same timeline shortly after the previous
    /// one (a pause and resume), the audio held so far is kept and the gap is
    /// filled with silence, so sample positions still match audio times.
    /// Otherwise the buffer starts empty.
    func begin(sampleRate: Double, startTime: Double, maximumGap: Double = 5) {
        let continues = state.withLock { state -> Bool in
            let gap = startTime - state.endTime
            guard state.sampleRate == sampleRate, state.count > 0, gap >= 0, gap <= maximumGap,
                  !state.storage.isEmpty
            else { return false }
            let capacity = state.storage.count
            let silence = Int((gap * sampleRate).rounded())
            for _ in 0..<min(silence, capacity) {
                state.storage[state.writeIndex] = 0
                state.writeIndex = (state.writeIndex + 1) % capacity
            }
            state.count = min(capacity, state.count + silence)
            state.endTime = startTime
            return true
        }
        if !continues {
            reset(sampleRate: sampleRate, startTime: startTime)
        }
    }

    /// Forgets the audio held so far (a new session) but keeps the timeline.
    func removeAll() {
        state.withLock { state in
            state.count = 0
        }
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        state.withLock { state in
            let capacity = state.storage.count
            guard capacity > 0 else { return }
            for sample in samples {
                state.storage[state.writeIndex] = sample
                state.writeIndex = (state.writeIndex + 1) % capacity
            }
            state.count = min(capacity, state.count + samples.count)
            state.endTime += Double(samples.count) / state.sampleRate
        }
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Seconds of audio currently held.
    var availableDuration: Double {
        state.withLock { state in
            state.sampleRate > 0 ? Double(state.count) / state.sampleRate : 0
        }
    }

    /// The newest `seconds` of audio (or all of it, if less is held), oldest first.
    func clip(lastSeconds seconds: Double) -> AudioClip? {
        state.withLock { state -> AudioClip? in
            let capacity = state.storage.count
            let wanted = min(state.count, Int((seconds * state.sampleRate).rounded()))
            guard capacity > 0, wanted > 0 else { return nil }
            var samples = [Float](repeating: 0, count: wanted)
            let first = (state.writeIndex - wanted + capacity) % capacity
            for offset in 0..<wanted {
                samples[offset] = state.storage[(first + offset) % capacity]
            }
            let startTime = state.endTime - Double(wanted) / state.sampleRate
            return AudioClip(samples: samples, sampleRate: state.sampleRate, startTime: startTime)
        }
    }
}

/// What the background analysis task hands every chunk of microphone audio
/// to, besides the analyzers: the recent-audio buffer and, when transcripts
/// are on, the speech recognizer.
nonisolated final class AudioTap: Sendable {
    let recentAudio: RecentAudioBuffer
    private let transcriber = Mutex<LiveTranscriber?>(nil)

    init(recentAudio: RecentAudioBuffer = RecentAudioBuffer()) {
        self.recentAudio = recentAudio
    }

    func setTranscriber(_ newTranscriber: LiveTranscriber?) {
        transcriber.withLock { $0 = newTranscriber }
    }

    /// Called once per listening run, before audio flows.
    func begin(sampleRate: Double, startTime: Double) {
        recentAudio.begin(sampleRate: sampleRate, startTime: startTime)
    }

    /// - Parameter startTime: Audio time of the first sample in `samples`.
    func consume(_ samples: UnsafeBufferPointer<Float>, startTime: Double) {
        recentAudio.append(samples)
        let current = transcriber.withLock { $0 }
        current?.append(samples, startTime: startTime)
    }
}
