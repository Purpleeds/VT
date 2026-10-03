import Foundation

/// What track building keeps from each analysis frame.
nonisolated struct TrackFeatureFrame: Sendable, Equatable {
    /// Seconds from the start of the analyzed section (frame centre).
    var time: Double
    /// Semitones (MIDI) when clearly voiced.
    var midi: Double?
    var levelDb: Double
    var f1: Double?
    var f2: Double?
    var f3: Double?
    /// 0–100 on the user's weight scale.
    var weightScore: Double?

    init(time: Double, midi: Double?, levelDb: Double, f1: Double? = nil, f2: Double? = nil, f3: Double? = nil, weightScore: Double? = nil) {
        self.time = time
        self.midi = midi
        self.levelDb = levelDb
        self.f1 = f1
        self.f2 = f2
        self.f3 = f3
        self.weightScore = weightScore
    }
}

/// A word and when it was said (seconds from the start of the clip).
nonisolated struct TranscribedWord: Sendable, Equatable, Codable {
    var text: String
    var start: Double
    var duration: Double
    /// 0…1 when the recognizer reports it.
    var confidence: Double?

    var end: Double { start + duration }

    /// Average confidence of the words that report one.
    static func averageConfidence(_ words: [TranscribedWord]) -> Double? {
        let values = words.compactMap(\.confidence)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// Everything measured in a clip, before it becomes bars. Keeping the frames
/// lets the user switch between speech and singing without re-analyzing.
nonisolated struct PitchTrackAnalysis: Sendable {
    let duration: Double
    let frames: [TrackFeatureFrame]
    let grid: PitchGrid
    let detection: ClipTypeDetection
    let quality: ClipQualityReport
    /// Share of 10 ms steps that are pauses (see `BackgroundMusicCheck`).
    let pauseShare: Double

    /// The bars for `kind`, each with the clip's resonance, weight and
    /// loudness in that stretch.
    func content(as kind: PitchTrackKind, references: PersonalReferences) -> PitchTrackContent {
        switch kind {
        case .singing:
            let notes = NoteSegmenter.notes(grid)
            let bars = PitchTrackBuilder.addFeatures(to: notes.bars, frames: frames, references: references)
            return PitchTrackContent(kind: .singing, duration: duration, bars: bars, tuningOffsetCents: notes.tuningOffset * 100)
        case .speech, .builtIn:
            let bars = PitchTrackBuilder.addFeatures(to: SpeechSegmenter.segments(grid), frames: frames, references: references)
            return PitchTrackContent(kind: .speech, duration: duration, bars: bars)
        }
    }

    func hasMusic(kind: PitchTrackKind, stereo: SplitAssessment?) -> Bool {
        BackgroundMusicCheck.hasMusic(
            kind: kind,
            pauseShare: pauseShare,
            duration: duration,
            heldNoteShare: quality.heldNoteShare,
            stereo: stereo
        )
    }

    var hasMultipleSpeakers: Bool {
        quality.warnings.contains(.multipleSpeakers)
    }
}

nonisolated enum PitchTrackError: LocalizedError, Sendable, Equatable {
    case noVoice
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVoice: "No clear voice was found in this part. Choose a section where someone is talking or singing."
        case .cancelled: "Making the track was cancelled."
        }
    }
}

/// Turns a clip into a Pitch Track (SPEC section 22.1), reusing the live
/// analysis pipeline (pitch, formants, weight) offline.
nonisolated enum PitchTrackBuilder {
    /// Fewer voiced steps than this (0.5 s) isn't enough for a track.
    static let minimumVoicedSteps = 50

    /// Analyzes the clip (slow: run off the main thread).
    /// - Parameters:
    ///   - isCancelled: Checked between chunks; cancelling throws.
    ///   - progress: The current step and its progress (0…1).
    static func analyze(
        _ clip: AudioClip,
        references: PersonalReferences,
        isCancelled: () -> Bool = { false },
        progress: (TrackBuildStage, Double) -> Void = { _, _ in }
    ) throws -> PitchTrackAnalysis {
        let rate = clip.sampleRate
        let configuration = AnalysisConfiguration(sampleRate: rate, minimumFrequency: 60, maximumFrequency: 1_000)
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        let weightReference = references.weight
        var frames: [TrackFeatureFrame] = []
        var summaries: [ClipFrameSummary] = []
        frames.reserveCapacity(Int(clip.duration * configuration.framesPerSecond) + 1)

        let chunk = 8_192
        var position = 0
        progress(.detectingPitch, 0)
        while position < clip.samples.count {
            if isCancelled() {
                throw PitchTrackError.cancelled
            }
            let next = min(clip.samples.count, position + chunk)
            let produced = clip.samples.withUnsafeBufferPointer { buffer in
                pipeline.process(UnsafeBufferPointer(rebasing: buffer[position..<next]))
            }
            for frame in produced {
                let pitch = frame.status == .voiced ? frame.filteredFrequency : nil
                frames.append(TrackFeatureFrame(
                    time: frame.time,
                    midi: pitch.map(PitchMath.midiNote(for:)),
                    levelDb: frame.levelDb,
                    f1: frame.formants?.f1.frequency,
                    f2: frame.formants?.f2.frequency,
                    f3: frame.formants?.f3?.frequency,
                    weightScore: frame.weight.map {
                        weightReference.score(h1MinusH2: $0.effectiveH1MinusH2, spectralTilt: $0.spectralTilt)
                    }
                ))
                summaries.append(ClipFrameSummary(frame))
            }
            position = next
            progress(.detectingPitch, Double(position) / Double(max(clip.samples.count, 1)))
        }

        progress(.measuringResonance, 0)
        let grid = PitchGrid.resample(frames, duration: clip.duration)
        guard grid.voicedCount >= minimumVoicedSteps else { throw PitchTrackError.noVoice }
        let phrases = VoicedSpans.phrases(summaries, frameInterval: configuration.hopDuration)
        let quality = ClipQualityChecker.check(
            frames: summaries,
            phrases: phrases,
            frameInterval: configuration.hopDuration,
            duration: clip.duration,
            clippedFraction: ClipQualityChecker.clippedFraction(clip.samples)
        )
        progress(.measuringResonance, 1)

        if isCancelled() {
            throw PitchTrackError.cancelled
        }
        progress(.buildingTrack, 0)
        let detection = ClipTypeDetector.detect(grid)
        let analysis = PitchTrackAnalysis(
            duration: clip.duration,
            frames: frames,
            grid: grid,
            detection: detection,
            quality: quality,
            pauseShare: BackgroundMusicCheck.pauseShare(grid)
        )
        progress(.buildingTrack, 1)
        return analysis
    }

    /// Adds each bar's median formants, resonance score, weight score and
    /// loudness from the frames inside it.
    static func addFeatures(to bars: [TrackBar], frames: [TrackFeatureFrame], references: PersonalReferences) -> [TrackBar] {
        let resonanceReference = references.resonance(for: .speech)
        var lowerIndex = 0
        return bars.map { bar in
            var result = bar
            while lowerIndex < frames.count, frames[lowerIndex].time < bar.start {
                lowerIndex += 1
            }
            var index = lowerIndex
            var f1: [Double] = []
            var f2: [Double] = []
            var f3: [Double] = []
            var weights: [Double] = []
            var levels: [Double] = []
            while index < frames.count, frames[index].time < bar.end {
                let frame = frames[index]
                if let value = frame.f1 { f1.append(value) }
                if let value = frame.f2 { f2.append(value) }
                if let value = frame.f3 { f3.append(value) }
                if let value = frame.weightScore { weights.append(value) }
                if frame.midi != nil { levels.append(frame.levelDb) }
                index += 1
            }
            let medianF2 = PitchMath.median(of: f2)
            let medianF3 = PitchMath.median(of: f3)
            if medianF2 != nil || medianF3 != nil {
                result.resonance = BarResonance(
                    f1: PitchMath.median(of: f1),
                    f2: medianF2,
                    f3: medianF3,
                    score: medianF2.map { resonanceReference.score(f2: $0, f3: medianF3) }
                )
            }
            result.weightScore = PitchMath.median(of: weights)
            result.loudnessDb = PitchMath.median(of: levels)
            return result
        }
    }

    /// Puts each word under the bar it overlaps most (several words on one
    /// bar are joined). Words that touch no bar are dropped.
    static func attach(_ words: [TranscribedWord], to bars: [TrackBar]) -> [TrackBar] {
        guard !words.isEmpty, !bars.isEmpty else { return bars }
        var texts = [[String]](repeating: [], count: bars.count)
        for word in words {
            var best: (index: Int, overlap: Double)?
            for (index, bar) in bars.enumerated() {
                let overlap = min(word.end, bar.end) - max(word.start, bar.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (index, overlap)
                }
            }
            if let best {
                texts[best.index].append(word.text)
            }
        }
        return bars.enumerated().map { index, bar in
            var result = bar
            let joined = texts[index].joined(separator: " ")
            result.word = joined.isEmpty ? nil : joined
            return result
        }
    }

    /// Songs only show words the recognizer was fairly sure of (SPEC 22.1).
    static func shouldShowWords(_ words: [TranscribedWord], kind: PitchTrackKind) -> Bool {
        guard !words.isEmpty else { return false }
        guard kind == .singing else { return true }
        return (TranscribedWord.averageConfidence(words) ?? 0) >= 0.5
    }
}
