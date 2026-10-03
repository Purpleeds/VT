import Foundation

/// Pitch ranges in semitones (MIDI note numbers) and transposition advice
/// (SPEC section 22.1: compare the track's range to the user's comfortable
/// range and suggest transposing).
nonisolated enum TrackRange {
    /// Lowest and highest pitch the bars ask for. Curved bars use the 5th and
    /// 95th percentiles of their contours so a stray glide doesn't count.
    static func span(of bars: [TrackBar]) -> ClosedRange<Double>? {
        guard !bars.isEmpty else { return nil }
        var values: [Double] = []
        for bar in bars {
            if bar.isCurved {
                values.append(contentsOf: bar.contour.map(\.midi))
            } else {
                values.append(bar.midi)
            }
        }
        let sorted = values.sorted()
        let hasCurves = bars.contains { $0.isCurved }
        guard let low = hasCurves ? TakeAnalyzer.percentile(sorted, 0.05) : sorted.first,
              let high = hasCurves ? TakeAnalyzer.percentile(sorted, 0.95) : sorted.last
        else { return nil }
        return low...high
    }

    /// Semitones by which `track` lies outside `comfort` (0 when inside).
    static func overshoot(_ track: ClosedRange<Double>, comfort: ClosedRange<Double>, shift: Int = 0) -> Double {
        let low = track.lowerBound + Double(shift)
        let high = track.upperBound + Double(shift)
        return max(0, comfort.lowerBound - low) + max(0, high - comfort.upperBound)
    }

    /// The transposition (−12…12) that best fits the track into the comfortable
    /// range: least time outside it, then the most centred, then the smallest.
    static func bestFit(_ track: ClosedRange<Double>, comfort: ClosedRange<Double>) -> Int {
        let comfortCenter = (comfort.lowerBound + comfort.upperBound) / 2
        let trackCenter = (track.lowerBound + track.upperBound) / 2
        var best = 0
        var bestKey = (Double.infinity, Double.infinity, Int.max)
        for shift in TrackSettings.transposeRange {
            let key = (
                (overshoot(track, comfort: comfort, shift: shift) * 100).rounded() / 100,
                (abs(trackCenter + Double(shift) - comfortCenter) * 100).rounded() / 100,
                abs(shift)
            )
            if key < bestKey {
                bestKey = key
                best = shift
            }
        }
        return best
    }

    /// Advice for the track: nil when it already fits (within a semitone).
    static func suggestion(_ track: ClosedRange<Double>, comfort: ClosedRange<Double>, current: Int) -> Int? {
        guard overshoot(track, comfort: comfort, shift: current) > 1 else { return nil }
        let best = bestFit(track, comfort: comfort)
        return best == current ? nil : best
    }

    /// e.g. "G3–C5".
    static func label(_ range: ClosedRange<Double>) -> String {
        let low = PitchMath.noteName(for: PitchMath.frequency(forMidiNote: range.lowerBound)) ?? ""
        let high = PitchMath.noteName(for: PitchMath.frequency(forMidiNote: range.upperBound)) ?? ""
        return low == high ? low : "\(low)–\(high)"
    }
}

/// One finished session's pitch range, for the comfortable-range estimate.
nonisolated struct SessionPitchRange: Sendable, Equatable {
    let low: Double
    let high: Double
    /// Seconds of voice in the session.
    let voicedDuration: Double
}

/// The pitch range the user reaches comfortably, from their history.
nonisolated enum ComfortRange {
    /// Sessions with less voice than this are ignored.
    static let minimumVoicedSeconds = 20.0

    /// Median low and high of recent sessions, widened to include the target
    /// zone; falls back to the baseline recording and the target zone.
    /// - Returns: Semitones (MIDI).
    static func estimate(
        sessions: [SessionPitchRange],
        baselineLow: Double?,
        baselineHigh: Double?,
        target: PitchTargetZone
    ) -> ClosedRange<Double> {
        let useful = sessions.filter { $0.voicedDuration >= minimumVoicedSeconds && $0.low > 0 && $0.high >= $0.low }
        var low: Double
        var high: Double
        if useful.count >= 3, let medianLow = PitchMath.median(of: useful.map(\.low)), let medianHigh = PitchMath.median(of: useful.map(\.high)) {
            low = medianLow
            high = medianHigh
        } else if let baselineLow, let baselineHigh, baselineLow > 0, baselineHigh >= baselineLow {
            low = baselineLow
            high = baselineHigh
        } else {
            low = target.lowerBound * pow(2, -3.0 / 12)
            high = target.upperBound * pow(2, 3.0 / 12)
        }
        low = min(low, target.lowerBound)
        high = max(high, target.upperBound)
        let lowMidi = PitchMath.midiNote(for: low)
        let highMidi = PitchMath.midiNote(for: high)
        // At least an octave: speaking ranges are narrow, but singing practice
        // reaches a little further.
        let center = (lowMidi + highMidi) / 2
        let half = max((highMidi - lowMidi) / 2, 6)
        return (center - half)...(center + half)
    }
}
