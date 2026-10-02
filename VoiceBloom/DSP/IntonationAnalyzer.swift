import Foundation

/// How melodic one phrase (a stretch of speech between pauses) was.
nonisolated struct PhraseIntonation: Sendable, Equatable {
    let startTime: Double
    let endTime: Double
    /// Seconds of voiced speech in the phrase.
    let voicedDuration: Double
    /// Average pitch (geometric mean) in Hz.
    let meanFrequency: Double
    /// Pitch variability: standard deviation in semitones around the phrase average.
    let standardDeviationSemitones: Double
    /// Highest minus lowest pitch, in semitones.
    let rangeSemitones: Double
    /// Pitch movements up/down of at least the movement threshold.
    let rises: Int
    let falls: Int

    var movementsPerSecond: Double {
        voicedDuration > 0 ? Double(rises + falls) / voicedDuration : 0
    }
}

nonisolated struct IntonationAnalyzerConfiguration: Sendable, Equatable {
    /// A pause at least this long ends a phrase. Gaps between words are
    /// usually shorter (~0.1–0.25 s), so this roughly splits sentences/clauses.
    var phraseEndPause = 0.35
    /// Phrases with less voiced speech than this are too short to judge.
    var minimumVoicedDuration = 0.6
    /// A rise or fall must cover at least this many semitones to count.
    var movementThresholdSemitones = 2.0
}

/// Splits the live pitch contour into phrases and measures their melody.
///
/// Pitch is converted to semitones (a musical, logarithmic scale), because
/// the ear hears a move from 100→200 Hz and 200→400 Hz as the same size step.
/// Variability is the standard deviation of those semitone values; rises and
/// falls are counted with hysteresis so small wobbles don't count.
nonisolated struct IntonationAnalyzer: Sendable {
    let configuration: IntonationAnalyzerConfiguration
    /// Seconds between analysis frames.
    let frameInterval: Double

    private var times: [Double] = []
    private var frequencies: [Double] = []
    private var lastVoicedTime: Double?

    init(frameInterval: Double, configuration: IntonationAnalyzerConfiguration = IntonationAnalyzerConfiguration()) {
        self.frameInterval = frameInterval
        self.configuration = configuration
    }

    /// True while a phrase is in progress.
    var isInPhrase: Bool { !frequencies.isEmpty }

    /// Feeds one frame. Pass the frame's filtered pitch, or nil when unvoiced.
    /// - Returns: A summary when this frame completes a phrase.
    mutating func process(time: Double, frequency: Double?) -> PhraseIntonation? {
        var completed: PhraseIntonation?
        if let lastVoicedTime, time - lastVoicedTime >= configuration.phraseEndPause, isInPhrase {
            completed = finishPhrase()
        }
        if let frequency, frequency > 0, frequency.isFinite {
            times.append(time)
            frequencies.append(frequency)
            lastVoicedTime = time
        }
        return completed
    }

    /// Ends the current phrase immediately (e.g. when listening stops).
    mutating func finishPhrase() -> PhraseIntonation? {
        defer {
            times.removeAll(keepingCapacity: true)
            frequencies.removeAll(keepingCapacity: true)
            lastVoicedTime = nil
        }
        return IntonationAnalyzer.summarize(
            times: times,
            frequencies: frequencies,
            frameInterval: frameInterval,
            configuration: configuration
        )
    }

    mutating func reset() {
        times.removeAll(keepingCapacity: true)
        frequencies.removeAll(keepingCapacity: true)
        lastVoicedTime = nil
    }

    /// Measures one phrase from its voiced frames.
    static func summarize(
        times: [Double],
        frequencies: [Double],
        frameInterval: Double,
        configuration: IntonationAnalyzerConfiguration = IntonationAnalyzerConfiguration()
    ) -> PhraseIntonation? {
        let count = min(times.count, frequencies.count)
        let voicedDuration = Double(count) * frameInterval
        guard count >= 2, voicedDuration >= configuration.minimumVoicedDuration,
              let start = times.first, let end = times.last
        else { return nil }

        // Semitones relative to the phrase's own average, so the result is
        // about melody, not about how high the voice is overall.
        let logs = frequencies.prefix(count).map { log2($0) }
        let meanLog = logs.reduce(0, +) / Double(count)
        let semitones = logs.map { 12 * ($0 - meanLog) }
        let variance = semitones.reduce(0) { $0 + $1 * $1 } / Double(count)
        let lowest = semitones.min() ?? 0
        let highest = semitones.max() ?? 0
        let movements = countMovements(semitones, threshold: configuration.movementThresholdSemitones)

        return PhraseIntonation(
            startTime: start,
            endTime: end,
            voicedDuration: voicedDuration,
            meanFrequency: pow(2, meanLog),
            standardDeviationSemitones: variance.squareRoot(),
            rangeSemitones: highest - lowest,
            rises: movements.rises,
            falls: movements.falls
        )
    }

    /// Counts rises and falls of at least `threshold` semitones.
    ///
    /// Hysteresis: once rising, the contour must drop `threshold` below its
    /// latest peak to count as a fall (and vice versa), so jitter around a
    /// level pitch never counts as movement.
    static func countMovements(_ semitones: [Double], threshold: Double) -> (rises: Int, falls: Int) {
        guard let first = semitones.first else { return (0, 0) }
        var rises = 0
        var falls = 0
        var low = first
        var high = first
        var trend = 0 // 0 = not yet known, 1 = rising, -1 = falling

        for value in semitones.dropFirst() {
            switch trend {
            case 1:
                if value > high {
                    high = value
                } else if high - value >= threshold {
                    falls += 1
                    trend = -1
                    low = value
                }
            case -1:
                if value < low {
                    low = value
                } else if value - low >= threshold {
                    rises += 1
                    trend = 1
                    high = value
                }
            default:
                low = min(low, value)
                high = max(high, value)
                if value - low >= threshold {
                    rises += 1
                    trend = 1
                    high = value
                } else if high - value >= threshold {
                    falls += 1
                    trend = -1
                    low = value
                }
            }
        }
        return (rises, falls)
    }
}
