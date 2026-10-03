import AVFoundation
import Foundation

/// Seconds on the audio hardware's host clock (the clock `AVAudioTime`
/// schedules against).
nonisolated enum HostClock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    static func hostTime(forSeconds seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: max(0, seconds))
    }
}

/// Maps host-clock seconds to the track's time, with speed, pauses and an
/// optional loop (the play range repeats).
nonisolated struct TrackClock: Sendable, Equatable {
    /// Track seconds where playing starts (and loops back to).
    let rangeStart: Double
    let rangeEnd: Double
    let speed: Double
    let loops: Bool
    /// Host seconds when the track was at `rangeStart` (moves on after pauses).
    private(set) var startHost: Double
    private(set) var pausedAt: Double?

    init(range: ClosedRange<Double>, speed: Double, loops: Bool, startHost: Double) {
        rangeStart = range.lowerBound
        rangeEnd = range.upperBound
        self.speed = max(speed, 0.01)
        self.loops = loops
        self.startHost = startHost
    }

    var isPaused: Bool { pausedAt != nil }
    var rangeLength: Double { max(rangeEnd - rangeStart, 0.001) }

    /// Track seconds played since the start, before looping.
    func elapsedTrackTime(atHost host: Double) -> Double {
        let now = pausedAt ?? host
        return max(0, (now - startHost) * speed)
    }

    /// Which time through the loop (0 for the first pass).
    func pass(atHost host: Double) -> Int {
        guard loops else { return 0 }
        return Int((elapsedTrackTime(atHost: host) / rangeLength).rounded(.down))
    }

    /// The track time at `host` (before the start it is earlier than
    /// `rangeStart`, so bars scroll in during the countdown).
    func trackTime(atHost host: Double) -> Double {
        let now = pausedAt ?? host
        let elapsed = (now - startHost) * speed
        guard elapsed >= 0 else { return rangeStart + elapsed }
        if loops {
            return rangeStart + elapsed.truncatingRemainder(dividingBy: rangeLength)
        }
        return rangeStart + elapsed
    }

    /// True once a non-looping track has played to its end.
    func isFinished(atHost host: Double) -> Bool {
        !loops && trackTime(atHost: host) >= rangeEnd
    }

    mutating func pause(atHost host: Double) {
        guard pausedAt == nil else { return }
        pausedAt = host
    }

    mutating func resume(atHost host: Double) {
        guard let pausedAt else { return }
        startHost += host - pausedAt
        self.pausedAt = nil
    }
}

/// Works out when each analysis frame was actually heard, from when frames
/// arrive. Frames are timed on the audio clock (`VoiceFrame.time`); the
/// smallest arrival delay seen recently is the processing pipeline's fixed
/// delay, so `frame.time + that offset` is when the frame's audio was complete.
nonisolated struct FrameTimeAligner: Sendable, Equatable {
    /// Minimum delays are tracked in buckets this long, so slow drift is
    /// followed.
    static let bucketDuration = 2.0

    private var currentMinimum: Double?
    private var previousMinimum: Double?
    private var bucketStart: Double?

    init() {}

    /// Records a frame that arrived at `arrivalHost`.
    mutating func observe(frameTime: Double, arrivalHost: Double) {
        let offset = arrivalHost - frameTime
        let start = bucketStart ?? arrivalHost
        if arrivalHost - start >= Self.bucketDuration {
            previousMinimum = currentMinimum
            currentMinimum = offset
            bucketStart = arrivalHost
        } else {
            bucketStart = start
            currentMinimum = min(currentMinimum ?? offset, offset)
        }
    }

    /// Host seconds minus audio-clock seconds, or nil before any frame.
    var offset: Double? {
        switch (currentMinimum, previousMinimum) {
        case let (current?, previous?):
            return min(current, previous)
        case let (current?, nil):
            return current
        case let (nil, previous?):
            return previous
        case (nil, nil):
            return nil
        }
    }

    /// When the middle of a frame reached the microphone (host seconds).
    /// - Parameter fixedDelay: Delay not seen in arrival times: half the
    ///   frame, the pitch median filter and the input hardware latency.
    func hostTime(ofFrameTime frameTime: Double, fixedDelay: Double) -> Double? {
        offset.map { frameTime + $0 - fixedDelay }
    }
}

/// The tap-along latency calibration (SPEC section 22.2): beats are played
/// at known times and the user taps with what they hear.
nonisolated enum LatencyCalibration {
    static let beatInterval = 60.0 / 90
    static let beatCount = 12
    /// The first beats are for getting into the rhythm.
    static let warmUpBeats = 2
    static let minimumTaps = 6

    /// Median delay (seconds) from each scheduled beat to the tap nearest to
    /// it, ignoring warm-up beats and taps more than 0.3 s from any beat.
    static func offset(beats: [Double], taps: [Double]) -> Double? {
        let counted = Array(beats.dropFirst(warmUpBeats))
        guard !counted.isEmpty else { return nil }
        var delays: [Double] = []
        for tap in taps {
            guard let nearest = counted.min(by: { abs($0 - tap) < abs($1 - tap) }) else { continue }
            let delay = tap - nearest
            if abs(delay) <= 0.3 {
                delays.append(delay)
            }
        }
        guard delays.count >= minimumTaps else { return nil }
        return PitchMath.median(of: delays)
    }
}

/// How far behind the app's timing the user's voice is (SPEC section 22.2:
/// a latency calibration and a manual offset in Settings). Device-specific,
/// so it lives in UserDefaults.
nonisolated struct PitchTrackLatency: Sendable, Equatable, Codable {
    static let key = "pitchTrack.latency"
    static let range = -100.0...500.0

    /// Nil uses the automatic estimate (the output route's reported delay).
    var customMilliseconds: Double?
    var calibratedAt: Date?

    static func load() -> PitchTrackLatency {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(PitchTrackLatency.self, from: data)
        else { return PitchTrackLatency() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Seconds to subtract from voice timestamps before scoring.
    /// - Parameter automatic: The automatic estimate (seconds).
    func offsetSeconds(automatic: Double) -> Double {
        if let customMilliseconds {
            return min(max(customMilliseconds, Self.range.lowerBound), Self.range.upperBound) / 1000
        }
        return automatic
    }

    /// The automatic estimate: what the output route reports (Bluetooth
    /// headphones add a lot), plus a little for reacting to the screen.
    static func automaticSeconds(outputLatency: Double, playsSound: Bool) -> Double {
        let visual = 0.03
        guard playsSound else { return visual }
        return max(visual, min(outputLatency, 0.5))
    }
}
