import Foundation

/// Values from the last few seconds, for robust (median) meter readings.
nonisolated struct RollingWindow: Sendable, Equatable {
    /// Seconds of history kept, measured back from the newest value.
    var duration: Double
    private(set) var times: [Double] = []
    private(set) var values: [Double] = []

    init(duration: Double) {
        self.duration = duration
    }

    var latestTime: Double? { times.last }
    var isEmpty: Bool { values.isEmpty }

    mutating func add(_ value: Double, at time: Double) {
        guard value.isFinite else { return }
        times.append(time)
        values.append(value)
        let cutoff = time - duration
        if let firstKept = times.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            times.removeFirst(firstKept)
            values.removeFirst(firstKept)
        }
    }

    /// Median of the values within `duration` of the newest one.
    var median: Double? { PitchMath.median(of: values) }

    mutating func removeAll() {
        times.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }
}

/// How recently a meter last received a measurement.
nonisolated enum MeterFreshness {
    /// A reading older than this (seconds) is shown dimmed.
    static let liveInterval = 0.6

    static func isLive(latest: Double?, now: Double) -> Bool {
        guard let latest else { return false }
        return now - latest <= liveInterval
    }
}

// MARK: - Resonance

nonisolated struct ResonanceReading: Sendable, Equatable {
    let score: Double
    /// Median F2 over the averaging window (Hz).
    let f2: Double
    /// Median F3 over the averaging window (Hz), if available.
    let f3: Double?
    let isLive: Bool
}

/// Turns per-frame formants into a steady resonance reading.
nonisolated struct ResonanceMeter: Sendable {
    private(set) var mode: ResonanceMode
    private(set) var reference: ResonanceReference
    private var f2Window: RollingWindow
    private var f3Window: RollingWindow

    init(mode: ResonanceMode = .speech) {
        self.mode = mode
        reference = mode.defaultReference
        f2Window = RollingWindow(duration: mode.averagingWindow)
        f3Window = RollingWindow(duration: mode.averagingWindow)
    }

    /// Switching mode changes the reference values and clears old values.
    mutating func setMode(_ newMode: ResonanceMode) {
        guard newMode != mode else { return }
        self = ResonanceMeter(mode: newMode)
    }

    mutating func add(_ formants: FormantMeasurement, at time: Double) {
        f2Window.add(formants.f2.frequency, at: time)
        if let f3 = formants.f3 {
            f3Window.add(f3.frequency, at: time)
        }
    }

    /// Score for a single frame (used for session averages).
    func score(for formants: FormantMeasurement) -> Double {
        reference.score(f2: formants.f2.frequency, f3: formants.f3?.frequency)
    }

    func reading(now: Double) -> ResonanceReading? {
        guard let f2 = f2Window.median else { return nil }
        let f3 = f3Window.median
        return ResonanceReading(
            score: reference.score(f2: f2, f3: f3),
            f2: f2,
            f3: f3,
            isLive: MeterFreshness.isLive(latest: f2Window.latestTime, now: now)
        )
    }

    mutating func reset() {
        f2Window.removeAll()
        f3Window.removeAll()
    }
}

// MARK: - Weight

nonisolated struct WeightReading: Sendable, Equatable {
    let score: Double
    /// Median H1–H2 (corrected when formants were available), in dB.
    let h1MinusH2: Double
    /// Median spectral tilt in dB/octave.
    let spectralTilt: Double?
    let isLive: Bool
}

/// Turns per-frame weight measurements into a steady reading.
nonisolated struct WeightMeter: Sendable {
    var reference: WeightReference
    private var harmonicWindow = RollingWindow(duration: 1.0)
    private var tiltWindow = RollingWindow(duration: 1.0)

    init(reference: WeightReference = .standard) {
        self.reference = reference
    }

    mutating func add(_ weight: WeightMeasurement, at time: Double) {
        harmonicWindow.add(weight.effectiveH1MinusH2, at: time)
        if let tilt = weight.spectralTilt {
            tiltWindow.add(tilt, at: time)
        }
    }

    func score(for weight: WeightMeasurement) -> Double {
        reference.score(h1MinusH2: weight.effectiveH1MinusH2, spectralTilt: weight.spectralTilt)
    }

    func reading(now: Double) -> WeightReading? {
        guard let harmonics = harmonicWindow.median else { return nil }
        let tilt = tiltWindow.median
        return WeightReading(
            score: reference.score(h1MinusH2: harmonics, spectralTilt: tilt),
            h1MinusH2: harmonics,
            spectralTilt: tilt,
            isLive: MeterFreshness.isLive(latest: harmonicWindow.latestTime, now: now)
        )
    }

    mutating func reset() {
        harmonicWindow.removeAll()
        tiltWindow.removeAll()
    }
}

// MARK: - Intonation

nonisolated struct IntonationReading: Sendable, Equatable {
    let score: Double
    let phrase: PhraseIntonation
    /// False once the phrase is more than a few seconds old.
    let isRecent: Bool
}

/// Scores each completed phrase.
nonisolated struct IntonationMeter: Sendable {
    var reference: IntonationReference
    /// A phrase stays "recent" this many seconds after it ends.
    let recentInterval = 8.0
    private(set) var lastPhrase: PhraseIntonation?

    init(reference: IntonationReference = .standard) {
        self.reference = reference
    }

    /// Records a finished phrase and returns its score.
    @discardableResult
    mutating func add(_ phrase: PhraseIntonation) -> Double {
        lastPhrase = phrase
        return score(for: phrase)
    }

    func score(for phrase: PhraseIntonation) -> Double {
        reference.score(standardDeviationSemitones: phrase.standardDeviationSemitones)
    }

    func reading(now: Double) -> IntonationReading? {
        guard let lastPhrase else { return nil }
        return IntonationReading(
            score: score(for: lastPhrase),
            phrase: lastPhrase,
            isRecent: now - lastPhrase.endTime <= recentInterval
        )
    }

    mutating func reset() {
        lastPhrase = nil
    }
}

// MARK: - Session averages

/// Running mean of a score.
nonisolated struct ScoreAverage: Sendable, Equatable {
    private(set) var sum = 0.0
    private(set) var count = 0

    mutating func add(_ score: Double) {
        guard score.isFinite else { return }
        sum += score
        count += 1
    }

    var mean: Double? { count > 0 ? sum / Double(count) : nil }
}

/// Everything measured during the current practice session.
nonisolated struct VoiceSessionStats: Sendable, Equatable {
    var pitch = PitchSessionStats()
    /// Mean per-frame resonance score of stable frames.
    var resonance = ScoreAverage()
    /// Mean per-frame weight score of stable frames.
    var weight = ScoreAverage()
    /// Mean score of completed phrases.
    var intonation = ScoreAverage()
}
