import Foundation

/// The per-frame values a saved clip's statistics are computed from.
nonisolated struct FrameRecord: Sendable, Equatable {
    let time: Double
    /// Filtered pitch of a voiced frame (nil for silence, noise, held jumps).
    let pitch: Double?
    /// Resonance score of this frame's formants (stable frames only).
    let resonanceScore: Double?
    /// Weight score of this frame (stable frames only).
    let weightScore: Double?
}

/// Recent frame records, trimmed to a time window.
nonisolated struct FrameLog: Sendable {
    let duration: Double
    private(set) var records: [FrameRecord] = []

    init(duration: Double = 40) {
        self.duration = duration
    }

    mutating func append(_ record: FrameRecord) {
        records.append(record)
        // Trim in chunks so most appends are O(1).
        if let first = records.first, record.time - first.time > duration + 5 {
            let cutoff = record.time - duration
            if let firstKept = records.firstIndex(where: { $0.time >= cutoff }) {
                records.removeFirst(firstKept)
            }
        }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
    }
}

/// Statistics for one saved recording.
nonisolated struct ClipStats: Sendable, Equatable {
    let averagePitch: Double?
    let percentInTarget: Double?
    let resonanceScore: Double?
    let weightScore: Double?
    /// Average melody score of the clip's phrases (as the live meter scores them).
    let intonationScore: Double?
    let target: PitchTargetZone
    let voicedDuration: Double

    static func compute(
        records: [FrameRecord],
        from start: Double,
        through end: Double,
        target: PitchTargetZone,
        frameInterval: Double,
        intonation: IntonationReference = .standard
    ) -> ClipStats {
        let inRange = records.filter { $0.time >= start && $0.time <= end }
        let voiced = inRange.filter { $0.pitch != nil }
        let pitches = voiced.compactMap(\.pitch)

        let average = Self.mean(pitches)
        let inTarget = pitches.isEmpty ? nil : Double(pitches.filter(target.contains).count) / Double(pitches.count) * 100
        let resonanceScores = inRange.compactMap(\.resonanceScore)
        let weightScores = inRange.compactMap(\.weightScore)

        // Split the clip into phrases at pauses, exactly like live analysis.
        var phrases = IntonationAnalyzer(frameInterval: frameInterval)
        var phraseScores: [Double] = []
        for record in inRange {
            if let phrase = phrases.process(time: record.time, frequency: record.pitch) {
                phraseScores.append(intonation.score(standardDeviationSemitones: phrase.standardDeviationSemitones))
            }
        }
        if let lastPhrase = phrases.finishPhrase() {
            phraseScores.append(intonation.score(standardDeviationSemitones: lastPhrase.standardDeviationSemitones))
        }

        return ClipStats(
            averagePitch: average,
            percentInTarget: inTarget,
            resonanceScore: Self.mean(resonanceScores),
            weightScore: Self.mean(weightScores),
            intonationScore: Self.mean(phraseScores),
            target: target,
            voicedDuration: Double(pitches.count) * frameInterval
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// A clip ready to be saved: audio, statistics and transcript.
nonisolated struct RecentClip: Sendable, Equatable {
    let audio: AudioClip
    let stats: ClipStats
    let transcript: String?
}
