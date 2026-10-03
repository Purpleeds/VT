import Foundation

// MARK: - 10 ms pitch grid

/// A pitch contour on a regular 10 ms grid (SPEC section 22.1: "full pitch
/// contour, 10 ms frames"), with the loudness at each step.
nonisolated struct PitchGrid: Sendable, Equatable {
    static let step = 0.01

    /// Semitones (MIDI), nil where there is no clear pitch.
    var midi: [Double?]
    /// Loudness (dBFS) at each step.
    var levels: [Double]

    init(midi: [Double?], levels: [Double]? = nil) {
        self.midi = midi
        self.levels = levels ?? [Double](repeating: -30, count: midi.count)
    }

    var count: Int { midi.count }
    var duration: Double { Double(count) * Self.step }
    var voicedCount: Int { midi.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    static func time(ofIndex index: Int) -> Double { Double(index) * step }

    /// Resamples analysis frames (about 10.7–11.6 ms apart, timed at their
    /// centres) onto the grid. Neighbouring voiced frames are interpolated.
    static func resample(_ frames: [TrackFeatureFrame], duration: Double) -> PitchGrid {
        let count = max(0, Int((duration / step).rounded(.down)))
        guard count > 0, frames.count >= 2 else {
            return PitchGrid(midi: [Double?](repeating: nil, count: count), levels: [Double](repeating: -120, count: count))
        }
        let firstTime = frames[0].time
        let interval = (frames[frames.count - 1].time - firstTime) / Double(frames.count - 1)
        guard interval > 0 else {
            return PitchGrid(midi: [Double?](repeating: nil, count: count), levels: [Double](repeating: -120, count: count))
        }
        var midi = [Double?](repeating: nil, count: count)
        var levels = [Double](repeating: -120, count: count)
        for index in 0..<count {
            let position = (time(ofIndex: index) - firstTime) / interval
            guard position >= -0.5, position <= Double(frames.count - 1) + 0.5 else { continue }
            let lower = min(max(Int(position.rounded(.down)), 0), frames.count - 1)
            let upper = min(lower + 1, frames.count - 1)
            let fraction = min(max(position - Double(lower), 0), 1)
            let a = frames[lower]
            let b = frames[upper]
            levels[index] = a.levelDb + (b.levelDb - a.levelDb) * fraction
            switch (a.midi, b.midi) {
            case let (first?, second?):
                midi[index] = first + (second - first) * fraction
            case let (first?, nil):
                midi[index] = fraction < 0.5 ? first : nil
            case let (nil, second?):
                midi[index] = fraction >= 0.5 ? second : nil
            case (nil, nil):
                midi[index] = nil
            }
        }
        return PitchGrid(midi: midi, levels: levels)
    }

    /// Median of each voiced point and its voiced neighbours (5 steps), which
    /// removes single-step glitches without moving note edges.
    func medianSmoothed(window: Int = 5) -> [Double?] {
        let half = max(0, window / 2)
        return midi.indices.map { index in
            guard midi[index] != nil else { return nil }
            var values: [Double] = []
            for other in max(0, index - half)...min(count - 1, index + half) {
                if let value = midi[other] {
                    values.append(value)
                }
            }
            return PitchMath.median(of: values)
        }
    }
}

// MARK: - Singing: notes

/// A run of steady pitch found in a contour.
nonisolated struct PitchRun: Sendable, Equatable {
    /// Grid indices, end inclusive.
    var startIndex: Int
    var endIndex: Int
    var values: [Double]

    var start: Double { PitchGrid.time(ofIndex: startIndex) }
    var end: Double { PitchGrid.time(ofIndex: endIndex + 1) }
    var duration: Double { end - start }
    var median: Double { PitchMath.median(of: values) ?? 0 }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

/// Splits a sung contour into notes (SPEC section 22.1): stable pitch
/// regions longer than ~80 ms, snapped to the nearest semitone (of the clip's
/// own tuning), with tiny gaps between equal notes merged.
nonisolated enum NoteSegmenter {
    /// A frame further than this (semitones) from the note's mean starts a new
    /// note once `confirmationSteps` frames in a row agree. Wide enough for
    /// ordinary vibrato.
    static let changeThreshold = 0.75
    static let confirmationSteps = 3
    /// Unvoiced gaps longer than this end a note.
    static let maximumGap = 0.05
    static let minimumNoteDuration = 0.08
    /// Equal notes closer than this are joined.
    static let mergeGap = 0.12

    /// Steady-pitch runs in the (median-smoothed) contour.
    static func runs(_ grid: PitchGrid) -> [PitchRun] {
        let smoothed = grid.medianSmoothed()
        let maximumGapSteps = Int((maximumGap / PitchGrid.step).rounded())
        var runs: [PitchRun] = []
        var current: PitchRun?
        var pending: [(index: Int, value: Double)] = []
        var gap = 0

        for (index, sample) in smoothed.enumerated() {
            guard let value = sample else {
                gap += 1
                if current != nil, gap > maximumGapSteps {
                    if let run = current {
                        runs.append(run)
                    }
                    current = nil
                    pending = []
                }
                continue
            }
            gap = 0
            guard var run = current else {
                current = PitchRun(startIndex: index, endIndex: index, values: [value])
                continue
            }
            if abs(value - run.mean) <= changeThreshold {
                pending = []
                run.endIndex = index
                run.values.append(value)
                current = run
            } else {
                pending.append((index, value))
                if pending.count >= confirmationSteps {
                    runs.append(run)
                    // The new note starts with the pending frames that agree
                    // with the newest one.
                    let newest = pending[pending.count - 1].value
                    let agreeing = pending.filter { abs($0.value - newest) <= changeThreshold }
                    let first = agreeing.first?.index ?? index
                    current = PitchRun(startIndex: first, endIndex: index, values: agreeing.map(\.value))
                    pending = []
                }
            }
        }
        if let run = current {
            runs.append(run)
        }
        return runs
    }

    /// The clip's tuning: how far (semitones, −0.5…0.5) its notes sit from
    /// equal temperament at A = 440 Hz, as a duration-weighted circular mean.
    static func tuningOffset(_ runs: [PitchRun]) -> Double {
        var x = 0.0
        var y = 0.0
        for run in runs {
            let angle = 2 * Double.pi * run.median
            x += run.duration * cos(angle)
            y += run.duration * sin(angle)
        }
        guard x != 0 || y != 0 else { return 0 }
        return atan2(y, x) / (2 * Double.pi)
    }

    /// How tightly the notes cluster around semitones (0 = no pattern,
    /// 1 = every note exactly on the grid, whatever the tuning).
    static func snapStrength(_ runs: [PitchRun]) -> Double {
        var x = 0.0
        var y = 0.0
        var total = 0.0
        for run in runs {
            let angle = 2 * Double.pi * run.median
            x += run.duration * cos(angle)
            y += run.duration * sin(angle)
            total += run.duration
        }
        guard total > 0 else { return 0 }
        return (x * x + y * y).squareRoot() / total
    }

    /// Flat note bars.
    static func notes(_ grid: PitchGrid) -> (bars: [TrackBar], tuningOffset: Double) {
        let found = runs(grid).filter { $0.duration >= minimumNoteDuration - 0.0001 }
        guard !found.isEmpty else { return ([], 0) }
        let offset = tuningOffset(found)
        var bars: [TrackBar] = []
        for run in found {
            let note = (run.median - offset).rounded()
            let pitch = note + offset
            if var last = bars.last, abs(last.midi - pitch) < 0.01, run.start - last.end <= mergeGap + 0.0001 {
                last.duration = run.end - last.start
                bars[bars.count - 1] = last
            } else {
                bars.append(TrackBar(index: bars.count, start: run.start, duration: run.duration, midi: pitch))
            }
        }
        return (bars, offset)
    }
}

// MARK: - Speech: curved segments

/// Groups a spoken contour into syllable/word segments drawn as curved bars
/// (SPEC section 22.1).
nonisolated enum SpeechSegmenter {
    /// Short unvoiced gaps inside a word are bridged.
    static let bridgeGap = 0.04
    static let minimumDuration = 0.08
    /// Longer stretches are split at their quietest point.
    static let maximumDuration = 0.8
    /// Contour points are kept every 20 ms.
    static let contourStep = 2

    static func segments(_ grid: PitchGrid) -> [TrackBar] {
        let smoothed = grid.medianSmoothed()
        let bridge = Int((bridgeGap / PitchGrid.step).rounded())

        // 1. Voiced stretches, bridging tiny gaps.
        var stretches: [ClosedRange<Int>] = []
        var start: Int?
        var lastVoiced = -1
        for (index, value) in smoothed.enumerated() where value != nil {
            if let current = start, index - lastVoiced - 1 > bridge {
                stretches.append(current...lastVoiced)
                start = index
            } else if start == nil {
                start = index
            }
            lastVoiced = index
        }
        if let current = start {
            stretches.append(current...lastVoiced)
        }

        // 2. Split long stretches at the quietest step in their middle half.
        let maximumSteps = Int((maximumDuration / PitchGrid.step).rounded())
        var pieces: [ClosedRange<Int>] = []
        var queue = stretches
        while !queue.isEmpty {
            let stretch = queue.removeFirst()
            guard stretch.count > maximumSteps else {
                pieces.append(stretch)
                continue
            }
            let lower = stretch.lowerBound + stretch.count / 4
            let upper = stretch.upperBound - stretch.count / 4
            var split = (stretch.lowerBound + stretch.upperBound) / 2
            var quietest = Double.infinity
            for index in lower...upper {
                let level = smoothed[index] == nil ? -200 : grid.levels[index]
                if level < quietest {
                    quietest = level
                    split = index
                }
            }
            let left = stretch.lowerBound...max(stretch.lowerBound, split - 1)
            let right = min(split, stretch.upperBound)...stretch.upperBound
            queue.insert(right, at: 0)
            queue.insert(left, at: 0)
        }

        // 3. Curved bars with interpolated contours.
        let minimumSteps = Int((minimumDuration / PitchGrid.step).rounded())
        var bars: [TrackBar] = []
        for piece in pieces where piece.count >= minimumSteps {
            let filled = interpolated(smoothed, in: piece)
            guard let median = PitchMath.median(of: filled) else { continue }
            var contour: [TrackContourPoint] = []
            var offset = 0
            while offset < filled.count {
                contour.append(TrackContourPoint(time: PitchGrid.time(ofIndex: piece.lowerBound + offset), midi: filled[offset]))
                offset += contourStep
            }
            let lastTime = PitchGrid.time(ofIndex: piece.upperBound)
            if let last = contour.last, last.time < lastTime - 0.0001, let final = filled.last {
                contour.append(TrackContourPoint(time: lastTime, midi: final))
            }
            bars.append(TrackBar(
                index: bars.count,
                start: PitchGrid.time(ofIndex: piece.lowerBound),
                duration: Double(piece.count) * PitchGrid.step,
                midi: median,
                contour: contour
            ))
        }
        return bars
    }

    /// The values in `range` with bridged gaps filled by straight lines.
    static func interpolated(_ values: [Double?], in range: ClosedRange<Int>) -> [Double] {
        var result: [Double] = []
        var previous: (index: Int, value: Double)?
        var waiting: [Int] = []
        for index in range {
            if let value = values[index] {
                if let before = previous {
                    for gapIndex in waiting {
                        let fraction = Double(gapIndex - before.index) / Double(index - before.index)
                        result.append(before.value + (value - before.value) * fraction)
                    }
                } else {
                    result.append(contentsOf: waiting.map { _ in value })
                }
                waiting = []
                result.append(value)
                previous = (index, value)
            } else {
                waiting.append(index)
            }
        }
        if let before = previous {
            result.append(contentsOf: waiting.map { _ in before.value })
        }
        return result
    }
}

// MARK: - Speech or singing?

nonisolated struct ClipTypeDetection: Sendable, Equatable {
    let kind: PitchTrackKind
    /// 0 = clearly speech, 1 = clearly singing.
    let singingScore: Double
    /// Share of voiced time on held, steady notes (vibrato smoothed out).
    let heldShare: Double
    /// How tightly notes cluster on semitones (0…1).
    let snapStrength: Double
    /// Voiced share between the first and last voiced moment.
    let voicedRatio: Double

    /// 0.5 (a guess) to 1 (certain).
    var confidence: Double {
        min(1, 0.5 + abs(singingScore - ClipTypeDetector.singingThreshold))
    }

    var isConfident: Bool { confidence >= 0.7 }
}

/// Tells speech from singing (SPEC section 22.1) from pitch stability, how
/// well pitches snap to semitones, and how much of the time is voiced.
nonisolated enum ClipTypeDetector {
    static let singingThreshold = 0.4
    /// Held notes: within this many semitones of their mean…
    static let heldTolerance = 0.35
    /// …for at least this long.
    static let heldDuration = 0.25
    /// A moving mean this long (about one vibrato cycle) removes vibrato.
    static let vibratoWindow = 17

    static func detect(_ grid: PitchGrid) -> ClipTypeDetection {
        let voicedIndices = grid.midi.indices.filter { grid.midi[$0] != nil }
        guard let first = voicedIndices.first, let last = voicedIndices.last, voicedIndices.count >= 20 else {
            return ClipTypeDetection(kind: .speech, singingScore: 0, heldShare: 0, snapStrength: 0, voicedRatio: 0)
        }
        let voicedRatio = Double(voicedIndices.count) / Double(last - first + 1)
        let held = heldShare(grid)
        let runs = NoteSegmenter.runs(grid).filter { $0.duration >= NoteSegmenter.minimumNoteDuration - 0.0001 }
        let snap = NoteSegmenter.snapStrength(runs)
        let score = 0.45 * clamp((held - 0.15) / 0.45)
            + 0.35 * clamp((snap - 0.3) / 0.5)
            + 0.2 * clamp((voicedRatio - 0.6) / 0.3)
        return ClipTypeDetection(
            kind: score >= singingThreshold ? .singing : .speech,
            singingScore: score,
            heldShare: held,
            snapStrength: snap,
            voicedRatio: voicedRatio
        )
    }

    /// Share of voiced steps that belong to held notes, measured on the
    /// contour with vibrato averaged out (speech glides, singing holds).
    static func heldShare(_ grid: PitchGrid) -> Double {
        let smoothed = movingMean(grid.medianSmoothed(), window: vibratoWindow)
        let minimumSteps = Int((heldDuration / PitchGrid.step).rounded())
        var voiced = 0
        var held = 0
        var run: [Double] = []
        var runSum = 0.0

        func close() {
            if run.count >= minimumSteps {
                held += run.count
            }
            run = []
            runSum = 0
        }

        for value in smoothed {
            guard let value else {
                close()
                continue
            }
            voiced += 1
            if !run.isEmpty, abs(value - runSum / Double(run.count)) <= heldTolerance {
                run.append(value)
                runSum += value
            } else {
                close()
                run = [value]
                runSum = value
            }
        }
        close()
        return voiced > 0 ? Double(held) / Double(voiced) : 0
    }

    /// Mean over each point's contiguous voiced neighbours.
    static func movingMean(_ values: [Double?], window: Int) -> [Double?] {
        let half = max(0, window / 2)
        return values.indices.map { index in
            guard let center = values[index] else { return nil }
            var sum = center
            var count = 1.0
            var other = index - 1
            while other >= max(0, index - half), let value = values[other] {
                sum += value
                count += 1
                other -= 1
            }
            other = index + 1
            while other <= min(values.count - 1, index + half), let value = values[other] {
                sum += value
                count += 1
                other += 1
            }
            return sum / count
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Background music

/// Whether a clip seems to have instruments behind the voice (SPEC section
/// 22.1: detect background music and offer to split first).
nonisolated enum BackgroundMusicCheck {
    /// Share of 10 ms steps that are real pauses (well below the voice).
    static func pauseShare(_ grid: PitchGrid) -> Double {
        let voicedLevels = grid.midi.indices.compactMap { grid.midi[$0] == nil ? nil : grid.levels[$0] }
        guard let voice = PitchMath.median(of: voicedLevels), grid.count > 0 else { return 1 }
        let quiet = grid.levels.filter { $0 < voice - 25 }.count
        return Double(quiet) / Double(grid.count)
    }

    /// - Parameters:
    ///   - stereo: The file's stereo image, when it has one.
    ///   - heldNoteShare: From the clip quality check (held notes under speech).
    static func hasMusic(
        kind: PitchTrackKind,
        pauseShare: Double,
        duration: Double,
        heldNoteShare: Double,
        stereo: SplitAssessment?
    ) -> Bool {
        if let stereo, !stereo.isMono, stereo.sideToMidDb > -25, stereo.pauseShare < 0.08 {
            return true
        }
        // Voices pause to breathe; a music bed doesn't.
        if duration >= 8, pauseShare < 0.03 {
            return true
        }
        // Steady notes under speech come from instruments (or singing).
        return kind == .speech && heldNoteShare > ClipQualityChecker.maximumHeldNoteShare
    }
}
