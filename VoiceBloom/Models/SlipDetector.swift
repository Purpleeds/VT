import Foundation

/// What can slip back toward the old voice.
nonisolated enum SlipChannel: String, CaseIterable, Sendable, Hashable {
    case pitch
    case resonance
}

/// How quickly slip alerts react.
nonisolated enum SlipSensitivity: String, CaseIterable, Identifiable, Sendable, Codable {
    case gentle
    case standard
    case sensitive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .sensitive: "Sensitive"
        }
    }

    var detail: String {
        switch self {
        case .gentle: "Alerts after 3 seconds well below your target."
        case .standard: "Alerts after 2 seconds below your target."
        case .sensitive: "Alerts after about 1 second at the edge of your target."
        }
    }

    /// Seconds in the old range before an alert.
    var delay: Double {
        switch self {
        case .gentle: 3
        case .standard: 2
        case .sensitive: 1.2
        }
    }

    /// How far below the target zone (in semitones) pitch must drop to count.
    var pitchToleranceSemitones: Double {
        switch self {
        case .gentle: 2
        case .standard: 1
        case .sensitive: 0
        }
    }

    /// Resonance scores below this count as dark (back toward the old voice).
    var resonanceThreshold: Double {
        switch self {
        case .gentle: 20
        case .standard: 34
        case .sensitive: 45
        }
    }
}

nonisolated struct SlipDetectorConfiguration: Sendable, Equatable {
    /// Seconds in the old range before an alert.
    var delay: Double
    /// Seconds back on target before a slip counts as recovered.
    var recoveryTime = 0.3
    /// A pause this long (no observations) quietly clears a slip.
    var silenceReset = 1.0
    /// Pitches below this (Hz) count as the old range.
    var pitchFloor: Double
    /// Resonance scores below this count as the old range.
    var resonanceThreshold: Double
    var watchesPitch = true
    var watchesResonance = true

    init(
        target: PitchTargetZone,
        sensitivity: SlipSensitivity = .standard,
        watchesPitch: Bool = true,
        watchesResonance: Bool = true
    ) {
        delay = sensitivity.delay
        pitchFloor = target.lowerBound * pow(2, -sensitivity.pitchToleranceSemitones / 12)
        resonanceThreshold = sensitivity.resonanceThreshold
        self.watchesPitch = watchesPitch
        self.watchesResonance = watchesResonance
    }
}

nonisolated enum SlipEvent: Sendable, Equatable {
    case slipped(SlipChannel)
    case recovered(SlipChannel)
}

/// Tracks one channel (pitch or resonance) through on-target → drifting → slipped.
nonisolated struct SlipChannelTracker: Sendable, Equatable {
    private(set) var isSlipped = false
    private var lowSince: Double?
    private var okSince: Double?
    private var lastObservation: Double?

    nonisolated enum Change: Sendable, Equatable {
        case slipped
        case recovered
    }

    /// - Parameter isLow: true when this frame is in the old range, false when
    ///   on target, nil when there's nothing to judge (silence, no measurement).
    mutating func observe(isLow: Bool?, at time: Double, configuration: SlipDetectorConfiguration) -> Change? {
        guard let isLow else {
            // A real pause (not just the gap between words) quietly clears
            // everything: the user stopped speaking, they didn't recover.
            if let lastObservation, time - lastObservation >= configuration.silenceReset {
                self = SlipChannelTracker()
            }
            return nil
        }
        lastObservation = time

        if isLow {
            okSince = nil
            let start = lowSince ?? time
            lowSince = start
            if !isSlipped, time - start >= configuration.delay {
                isSlipped = true
                return .slipped
            }
        } else {
            // Brief moments on target don't cancel a drift; a steady return does.
            let start = okSince ?? time
            okSince = start
            if time - start >= configuration.recoveryTime {
                lowSince = nil
                if isSlipped {
                    isSlipped = false
                    return .recovered
                }
            }
        }
        return nil
    }
}

/// Watches pitch and resonance for slips back toward the old voice: more
/// than `delay` seconds below the target, ignoring brief dips and the gaps
/// between words.
nonisolated struct SlipDetector: Sendable {
    var configuration: SlipDetectorConfiguration {
        didSet {
            if !configuration.watchesPitch { pitch = SlipChannelTracker() }
            if !configuration.watchesResonance { resonance = SlipChannelTracker() }
        }
    }
    private var pitch = SlipChannelTracker()
    private var resonance = SlipChannelTracker()

    init(configuration: SlipDetectorConfiguration) {
        self.configuration = configuration
    }

    var activeSlips: Set<SlipChannel> {
        var active: Set<SlipChannel> = []
        if pitch.isSlipped { active.insert(.pitch) }
        if resonance.isSlipped { active.insert(.resonance) }
        return active
    }

    /// - Parameters:
    ///   - frequency: Filtered pitch of a voiced frame, or nil if unvoiced.
    ///   - resonanceScore: The current resonance reading (0–100) when this frame
    ///     brought a new formant measurement, otherwise nil.
    mutating func process(time: Double, frequency: Double?, resonanceScore: Double?) -> [SlipEvent] {
        var events: [SlipEvent] = []
        if configuration.watchesPitch {
            let isLow = frequency.map { $0 < configuration.pitchFloor }
            if let change = pitch.observe(isLow: isLow, at: time, configuration: configuration) {
                events.append(change == .slipped ? .slipped(.pitch) : .recovered(.pitch))
            }
        }
        if configuration.watchesResonance {
            let isLow = resonanceScore.map { $0 < configuration.resonanceThreshold }
            if let change = resonance.observe(isLow: isLow, at: time, configuration: configuration) {
                events.append(change == .slipped ? .slipped(.resonance) : .recovered(.resonance))
            }
        }
        return events
    }

    mutating func reset() {
        pitch = SlipChannelTracker()
        resonance = SlipChannelTracker()
    }
}

// MARK: - Time-in-target tallies

/// Fraction of hits among the observations of the last `duration` seconds.
nonisolated struct TimedTally: Sendable, Equatable {
    let duration: Double
    private var times: [Double] = []
    private var hits: [Bool] = []
    private(set) var hitCount = 0

    init(duration: Double) {
        self.duration = duration
    }

    var count: Int { times.count }

    /// 0...1, or nil with no observations.
    var fraction: Double? {
        times.isEmpty ? nil : Double(hitCount) / Double(times.count)
    }

    mutating func add(_ hit: Bool, at time: Double) {
        times.append(time)
        hits.append(hit)
        if hit { hitCount += 1 }
        let cutoff = time - duration
        var dropped = 0
        while dropped < times.count, times[dropped] < cutoff {
            if hits[dropped] { hitCount -= 1 }
            dropped += 1
        }
        if dropped > 0 {
            times.removeFirst(dropped)
            hits.removeFirst(dropped)
        }
    }

    mutating func removeAll() {
        times.removeAll(keepingCapacity: true)
        hits.removeAll(keepingCapacity: true)
        hitCount = 0
    }
}

/// Session-long count of observations inside a zone.
nonisolated struct ZoneTally: Sendable, Equatable {
    private(set) var total = 0
    private(set) var inZone = 0

    mutating func add(_ isInZone: Bool) {
        total += 1
        if isInZone { inZone += 1 }
    }

    /// 0–100, or nil with no observations.
    var percent: Double? {
        total > 0 ? Double(inZone) / Double(total) * 100 : nil
    }
}
