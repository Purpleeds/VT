import Foundation

/// One moment of the user's voice, timed on the track's clock (seconds from
/// the track start, after the latency offset).
nonisolated struct TrackVoiceSample: Sendable, Equatable {
    var time: Double
    /// Semitones (MIDI), nil when there is no clear pitch.
    var midi: Double?
    var f2: Double?
    var f3: Double?
    /// 0–100 on the user's weight scale.
    var weightScore: Double?

    init(time: Double, midi: Double?, f2: Double? = nil, f3: Double? = nil, weightScore: Double? = nil) {
        self.time = time
        self.midi = midi
        self.f2 = f2
        self.f3 = f3
        self.weightScore = weightScore
    }
}

/// How close the voice is to the bar right now (SPEC section 22.2: green on,
/// yellow close, red off).
nonisolated enum BarZone: Sendable, Equatable {
    case on
    case close
    case off

    init(errorCents: Double, toleranceCents: Double) {
        let distance = abs(errorCents)
        if distance <= toleranceCents {
            self = .on
        } else if distance <= 2 * toleranceCents {
            self = .close
        } else {
            self = .off
        }
    }

    var title: String {
        switch self {
        case .on: "On"
        case .close: "Close"
        case .off: "Off"
        }
    }
}

/// Live feedback for the bar under the "now" line.
nonisolated struct LiveBarFeedback: Sendable, Equatable {
    let barIndex: Int
    let zone: BarZone
    /// Positive when the voice is above the bar.
    let errorCents: Double

    /// "Go higher" when flat, "go lower" when sharp; nil when on.
    var hintGoesHigher: Bool? {
        zone == .on ? nil : errorCents < 0
    }
}

/// Scores for one bar (0–100; nil where there was nothing to measure).
nonisolated struct BarScore: Sendable, Equatable, Identifiable, Codable {
    let index: Int
    /// Accuracy including how much of the bar was sung (this is the fill).
    let pitchAccuracy: Double
    /// Average distance from the bar while singing (cents).
    let averageCentsOff: Double?
    /// Average signed distance (cents, negative = flat).
    let averageSignedCents: Double?
    let stability: Double?
    /// Seconds the note started after the bar (negative = early).
    let timingOffset: Double?
    let timing: Double?
    let resonanceMatch: Double?
    let weightMatch: Double?
    let overall: Double

    var id: Int { index }
    var isHit: Bool { pitchAccuracy >= PitchTrackScorer.hitThreshold }
}

/// Totals for a play-through (SPEC section 22.4).
nonisolated struct TrackScoreResult: Sendable, Equatable, Codable {
    let bars: [BarScore]
    let pitchAccuracy: Double
    let stability: Double?
    let timing: Double?
    let resonanceMatch: Double?
    let weightMatch: Double?
    let overall: Double
    let stars: Int
    /// 0–100.
    let percentBarsHit: Double
    let longestCombo: Int
    /// Highest and lowest bars hit cleanly (semitones).
    let highestComfortableMidi: Double?
    let lowestComfortableMidi: Double?

    static func stars(for score: Double) -> Int {
        switch score {
        case 90...: 5
        case 75..<90: 4
        case 60..<75: 3
        case 40..<60: 2
        default: 1
        }
    }
}

/// Scores the voice against the bars while the track plays (SPEC section
/// 22.4: pitch accuracy, stability, timing, resonance and weight match).
///
/// Feed samples in time order with `add`, call `advance(to:)` as the track
/// moves on, and read `result()` at the end. Plain value type: tested with
/// fake pitch data.
nonisolated struct PitchTrackScorer: Sendable {
    /// A bar counts as hit at this pitch accuracy.
    static let hitThreshold = 60.0
    /// Perfect bars (for the optional haptic) score at least this.
    static let perfectThreshold = 90.0
    /// Share of a bar that must be sung for full marks (edges are forgiven).
    static let coverageForFullMarks = 0.85
    /// Timing: full marks within 50 ms, none at 300 ms.
    static let timingGrace = 0.05
    static let timingSpan = 0.25
    /// Notes may start up to this early.
    static let earlyWindow = 0.3
    /// A bar is scored this long after it ends (late samples still count).
    static let settleTime = 0.25

    let bars: [TrackBar]
    let toleranceCents: Double
    let scoresResonanceAndWeight: Bool
    /// Seconds between samples (the analysis hop).
    let sampleInterval: Double

    private var samples: [[TrackVoiceSample]]
    private var preBarSamples: [[TrackVoiceSample]]
    private var finished: [Int: BarScore] = [:]
    private var order: [Int]
    private var nextToFinish = 0
    private(set) var combo = 0
    private(set) var longestCombo = 0
    private(set) var latest: LiveBarFeedback?

    init(bars: [TrackBar], difficulty: TrackDifficulty, scoresResonanceAndWeight: Bool, sampleInterval: Double) {
        self.bars = bars
        toleranceCents = difficulty.toleranceCents
        self.scoresResonanceAndWeight = scoresResonanceAndWeight
        self.sampleInterval = max(sampleInterval, 0.001)
        samples = Array(repeating: [], count: bars.count)
        preBarSamples = Array(repeating: [], count: bars.count)
        order = bars.indices.sorted { bars[$0].start < bars[$1].start }
    }

    /// Credit (0…1) for one sample: full within half the tolerance, half at
    /// the tolerance, none at twice the tolerance.
    static func credit(errorCents: Double, toleranceCents: Double) -> Double {
        let distance = abs(errorCents)
        let tolerance = max(toleranceCents, 1)
        if distance <= tolerance / 2 {
            return 1
        }
        if distance <= tolerance {
            return 1 - (distance - tolerance / 2) / (tolerance / 2) * 0.5
        }
        if distance <= 2 * tolerance {
            return 0.5 * (1 - (distance - tolerance) / tolerance)
        }
        return 0
    }

    // MARK: Feeding

    mutating func add(_ sample: TrackVoiceSample) {
        latest = nil
        for position in order {
            let bar = bars[position]
            if sample.time >= bar.start, sample.time < bar.end {
                samples[position].append(sample)
                if let midi = sample.midi {
                    let error = (midi - bar.targetMidi(at: sample.time)) * 100
                    latest = LiveBarFeedback(barIndex: position, zone: BarZone(errorCents: error, toleranceCents: toleranceCents), errorCents: error)
                }
            } else if sample.time >= bar.start - Self.earlyWindow, sample.time < bar.start {
                preBarSamples[position].append(sample)
            }
            if bar.start > sample.time + Self.earlyWindow {
                break
            }
        }
    }

    /// Scores bars that ended a moment before `time`.
    /// - Returns: The bars finished by this call.
    @discardableResult
    mutating func advance(to time: Double) -> [BarScore] {
        var newlyFinished: [BarScore] = []
        while nextToFinish < order.count {
            let position = order[nextToFinish]
            guard bars[position].end + Self.settleTime <= time else { break }
            let score = scoreBar(position)
            finished[position] = score
            newlyFinished.append(score)
            if score.isHit {
                combo += 1
                longestCombo = max(longestCombo, combo)
            } else {
                combo = 0
            }
            nextToFinish += 1
        }
        return newlyFinished
    }

    /// How full a bar is drawn (0…1): credit so far over a fully sung bar.
    func fill(forBar position: Int) -> Double {
        if let score = finished[position] {
            return score.pitchAccuracy / 100
        }
        guard bars.indices.contains(position) else { return 0 }
        return min(1, creditSum(position) / expectedCredit(position))
    }

    func score(forBar position: Int) -> BarScore? {
        finished[position]
    }

    // MARK: Results

    /// Scores the bars that started before `endTime` (all of them by
    /// default, unfinished ones too) and the totals.
    func result(through endTime: Double = .infinity) -> TrackScoreResult {
        let included = order.filter { bars[$0].start < endTime }
        let scores = included.map { finished[$0] ?? scoreBar($0) }
        let totalDuration = included.reduce(0.0) { $0 + bars[$1].duration }
        var weightedPitch = 0.0
        for (position, score) in zip(included, scores) {
            weightedPitch += score.pitchAccuracy * bars[position].duration
        }
        let pitch = totalDuration > 0 ? weightedPitch / totalDuration : 0
        let stability = Self.mean(scores.compactMap(\.stability))
        let timing = Self.mean(scores.compactMap(\.timing))
        let resonance = scoresResonanceAndWeight ? Self.mean(scores.compactMap(\.resonanceMatch)) : nil
        let weight = scoresResonanceAndWeight ? Self.mean(scores.compactMap(\.weightMatch)) : nil
        let overall = Self.combine(pitch: pitch, stability: stability, timing: timing, resonance: resonance, weight: weight)

        var run = 0
        var longest = 0
        for score in scores {
            run = score.isHit ? run + 1 : 0
            longest = max(longest, run)
        }
        let comfortable = zip(included, scores)
            .filter { $0.1.pitchAccuracy >= 70 && ($0.1.stability ?? 100) >= 50 }
            .map { bars[$0.0].midi }

        return TrackScoreResult(
            bars: scores,
            pitchAccuracy: pitch,
            stability: stability,
            timing: timing,
            resonanceMatch: resonance,
            weightMatch: weight,
            overall: overall,
            stars: TrackScoreResult.stars(for: overall),
            percentBarsHit: scores.isEmpty ? 0 : Double(scores.filter(\.isHit).count) / Double(scores.count) * 100,
            longestCombo: longest,
            highestComfortableMidi: comfortable.max(),
            lowestComfortableMidi: comfortable.min()
        )
    }

    /// Weighted average of the parts that were measured.
    static func combine(pitch: Double, stability: Double?, timing: Double?, resonance: Double?, weight: Double?) -> Double {
        var parts: [(value: Double, weight: Double)] = [(pitch, 0.5)]
        if let stability { parts.append((stability, 0.15)) }
        if let timing { parts.append((timing, 0.15)) }
        if let resonance { parts.append((resonance, 0.1)) }
        if let weight { parts.append((weight, 0.1)) }
        let total = parts.reduce(0) { $0 + $1.weight }
        return parts.reduce(0) { $0 + $1.value * $1.weight } / total
    }

    // MARK: One bar

    private func expectedCredit(_ position: Int) -> Double {
        max(1, bars[position].duration / sampleInterval * Self.coverageForFullMarks)
    }

    private func creditSum(_ position: Int) -> Double {
        let bar = bars[position]
        return samples[position].reduce(0) { sum, sample in
            guard let midi = sample.midi else { return sum }
            let error = (midi - bar.targetMidi(at: sample.time)) * 100
            return sum + Self.credit(errorCents: error, toleranceCents: toleranceCents)
        }
    }

    private func scoreBar(_ position: Int) -> BarScore {
        let bar = bars[position]
        let barSamples = samples[position]
        let accuracy = 100 * min(1, creditSum(position) / expectedCredit(position))

        let errors = barSamples.compactMap { sample in
            sample.midi.map { ($0 - bar.targetMidi(at: sample.time)) * 100 }
        }
        let averageOff = Self.mean(errors.map(abs))
        let averageSigned = Self.mean(errors)

        // Stability: how steady the voice is while on the note.
        var stability: Double?
        let onNote = errors.filter { abs($0) <= 2 * toleranceCents }
        if onNote.count >= 10, let mean = Self.mean(onNote) {
            let deviation = (onNote.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(onNote.count)).squareRoot()
            stability = 100 * Self.clamp(1 - (deviation - 15) / 60)
        }

        // Timing: when the voice first settles near the bar's pitch.
        let onset = onsetTime(position)
        let timing = onset.map { 100 * Self.clamp(1 - (abs($0 - bar.start) - Self.timingGrace) / Self.timingSpan) }

        var resonanceMatch: Double?
        var weightMatch: Double?
        if scoresResonanceAndWeight {
            let f2 = PitchMath.median(of: barSamples.compactMap(\.f2))
            let f3 = PitchMath.median(of: barSamples.compactMap(\.f3))
            if barSamples.compactMap(\.f2).count >= 3 {
                var parts: [(Double, Double)] = []
                if let mine = f2, let target = bar.resonance?.f2 {
                    parts.append((TargetComparison.ratioMatch(mine, target, tolerance: 1.25), 0.6))
                }
                if let mine = f3, let target = bar.resonance?.f3 {
                    parts.append((TargetComparison.ratioMatch(mine, target, tolerance: 1.25), 0.4))
                }
                let total = parts.reduce(0) { $0 + $1.1 }
                if total > 0 {
                    resonanceMatch = parts.reduce(0) { $0 + $1.0 * $1.1 } / total
                }
            }
            let weights = barSamples.compactMap(\.weightScore)
            if weights.count >= 3, let mine = PitchMath.median(of: weights), let target = bar.weightScore {
                weightMatch = TargetComparison.differenceMatch(mine, target, tolerance: 50)
            }
        }

        let overall = Self.combine(pitch: accuracy, stability: stability, timing: timing, resonance: resonanceMatch, weight: weightMatch)
        return BarScore(
            index: position,
            pitchAccuracy: accuracy,
            averageCentsOff: averageOff,
            averageSignedCents: averageSigned,
            stability: stability,
            timingOffset: onset.map { $0 - bar.start },
            timing: timing,
            resonanceMatch: resonanceMatch,
            weightMatch: weightMatch,
            overall: overall
        )
    }

    /// First time (from up to 0.3 s early, but not inside the previous bar)
    /// that three samples in a row sit near the bar's pitch.
    private func onsetTime(_ position: Int) -> Double? {
        let bar = bars[position]
        // Skip timing when the bar continues the previous note at the same
        // pitch: there's no new start to hear.
        let previousIndex = order.firstIndex(of: position).flatMap { $0 > 0 ? order[$0 - 1] : nil }
        var earliest = bar.start - Self.earlyWindow
        if let previousIndex {
            let previous = bars[previousIndex]
            if !bar.isCurved, !previous.isCurved, abs(previous.midi - bar.midi) < 0.5, bar.start - previous.end < 0.15 {
                return nil
            }
            earliest = max(earliest, previous.end)
        }
        let band = min(max(2 * toleranceCents, 50), 100)
        let candidates = (preBarSamples[position] + samples[position]).filter { $0.time >= earliest }
        guard candidates.count >= 3 else { return nil }
        for start in 0...(candidates.count - 3) {
            let run = candidates[start..<(start + 3)]
            let isNear = run.allSatisfy { sample in
                guard let midi = sample.midi else { return false }
                return abs((midi - bar.targetMidi(at: max(sample.time, bar.start))) * 100) < band
            }
            if isNear {
                return candidates[start].time
            }
        }
        return nil
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Makes the samples a perfect singer would produce (the Debug option and
/// the scoring tests).
nonisolated enum PerfectVoice {
    /// A sample at `time` on whatever bar is there (nil pitch between bars).
    static func sample(at time: Double, bars: [TrackBar]) -> TrackVoiceSample {
        let bar = bars.first { time >= $0.start && time < $0.end }
        return TrackVoiceSample(
            time: time,
            midi: bar.map { $0.targetMidi(at: time) },
            f2: bar?.resonance?.f2,
            f3: bar?.resonance?.f3,
            weightScore: bar?.weightScore
        )
    }
}
