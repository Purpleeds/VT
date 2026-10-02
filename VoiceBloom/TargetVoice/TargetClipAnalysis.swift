import Foundation

// MARK: - Frames and phrases

/// What the quality checks need from one analysis frame.
nonisolated struct ClipFrameSummary: Sendable, Equatable {
    /// Seconds from the start of the analyzed section.
    let time: Double
    let levelDb: Double
    /// Pitch (Hz) when the frame is clearly voiced.
    let pitch: Double?

    init(time: Double, levelDb: Double, pitch: Double?) {
        self.time = time
        self.levelDb = levelDb
        self.pitch = pitch
    }

    init(_ frame: VoiceFrame) {
        time = frame.time
        levelDb = frame.levelDb
        pitch = frame.status == .voiced ? frame.filteredFrequency : nil
    }
}

/// Speech between pauses.
nonisolated struct VoicedSpan: Sendable, Equatable {
    let start: Double
    let end: Double
    let pitches: [Double]

    var duration: Double { end - start }

    /// Median pitch in semitones above 100 Hz.
    var medianSemitones: Double? {
        PitchMath.median(of: pitches).map { 12 * log2($0 / 100) }
    }
}

nonisolated enum VoicedSpans {
    /// Groups voiced frames into phrases, splitting at pauses of at least
    /// `pause` seconds (the same rule as intonation analysis).
    static func phrases(_ frames: [ClipFrameSummary], frameInterval: Double, pause: Double = 0.35) -> [VoicedSpan] {
        var spans: [VoicedSpan] = []
        var start: Double?
        var last = 0.0
        var pitches: [Double] = []

        for frame in frames {
            guard let pitch = frame.pitch else { continue }
            if let spanStart = start, frame.time - last >= pause {
                spans.append(VoicedSpan(start: spanStart, end: last + frameInterval, pitches: pitches))
                start = nil
                pitches = []
            }
            if start == nil {
                start = frame.time
            }
            pitches.append(pitch)
            last = frame.time
        }
        if let spanStart = start {
            spans.append(VoicedSpan(start: spanStart, end: last + frameInterval, pitches: pitches))
        }
        return spans
    }
}

// MARK: - Quality warnings

nonisolated enum ClipQualityWarning: String, CaseIterable, Identifiable, Sendable, Equatable {
    case multipleSpeakers
    case music
    case noisy
    case littleSpeech
    case clipping
    case shortSelection
    case longSelection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .multipleSpeakers: "More than one voice?"
        case .music: "Music or singing?"
        case .noisy: "Background noise"
        case .littleSpeech: "Not much speech"
        case .clipping: "Distorted audio"
        case .shortSelection: "Short selection"
        case .longSelection: "Long selection"
        }
    }

    var message: String {
        switch self {
        case .multipleSpeakers:
            "We heard voices at clearly different pitches. Trim to a part where only your target is talking, or the profile will mix them."
        case .music:
            "Some of the sound holds steady notes, like music or singing. Pick a part with only talking and no background music."
        case .noisy:
            "The voice isn’t much louder than the background, so the profile may be less accurate. A cleaner clip helps."
        case .littleSpeech:
            "Only a few seconds of clear voice were found. Choose a section with more continuous talking."
        case .clipping:
            "Parts of the clip are so loud they’re distorted, which can skew resonance and weight."
        case .shortSelection:
            "10–60 seconds of clear, solo speech gives the most reliable profile."
        case .longSelection:
            "Longer is fine, but a focused 10–60 seconds of one person talking usually works best."
        }
    }

    /// Serious warnings make the profile unreliable; the others are advice.
    var isSerious: Bool {
        switch self {
        case .multipleSpeakers, .music, .noisy, .littleSpeech: true
        case .clipping, .shortSelection, .longSelection: false
        }
    }

    var systemImage: String {
        switch self {
        case .multipleSpeakers: "person.2.wave.2"
        case .music: "music.note"
        case .noisy: "waveform.badge.exclamationmark"
        case .littleSpeech: "text.bubble"
        case .clipping: "speaker.wave.3"
        case .shortSelection, .longSelection: "timer"
        }
    }
}

nonisolated struct ClipQualityReport: Sendable, Equatable {
    let warnings: [ClipQualityWarning]
    /// Seconds of clearly voiced sound.
    let voicedSeconds: Double
    /// Typical voice level minus the quietest moments (dB).
    let signalToNoiseDb: Double?
    /// Share (0…1) of voiced time spent on steady, held notes.
    let heldNoteShare: Double
    /// Distance between two groups of phrase pitches, when there are two.
    let speakerSeparationSemitones: Double?

    var hasSeriousWarnings: Bool { warnings.contains { $0.isSerious } }
}

/// Heuristic checks for imported target clips (SPEC section 9: warn about
/// music, background noise and multiple speakers).
nonisolated enum ClipQualityChecker {
    static let recommendedDuration: ClosedRange<Double> = 10...60
    /// Below this voice-to-background ratio the clip counts as noisy.
    static let minimumSignalToNoiseDb = 12.0
    static let minimumVoicedSeconds = 4.0
    /// Held notes: pitch within this many semitones of the note…
    static let heldNoteTolerance = 0.4
    /// …for at least this long.
    static let heldNoteDuration = 0.6
    static let maximumHeldNoteShare = 0.25
    /// Two phrase-pitch groups this far apart suggest two speakers.
    static let speakerSeparation = 5.0
    static let clippingThreshold: Float = 0.98
    static let maximumClippedFraction = 0.001

    static func check(
        frames: [ClipFrameSummary],
        phrases: [VoicedSpan],
        frameInterval: Double,
        duration: Double,
        clippedFraction: Double
    ) -> ClipQualityReport {
        var warnings: [ClipQualityWarning] = []
        let voicedFrames = frames.filter { $0.pitch != nil }
        let voicedSeconds = Double(voicedFrames.count) * frameInterval

        let split = speakerSplit(phrases)
        if let split, split.separation >= speakerSeparation, split.smallerShare >= 0.2, split.separation >= 3 * split.spread {
            warnings.append(.multipleSpeakers)
        }

        let held = heldNoteShare(frames, frameInterval: frameInterval)
        let pauseShare = frames.isEmpty ? 1 : Double(frames.filter { $0.pitch == nil }.count) / Double(frames.count)
        let continuousSound = duration >= 8 && pauseShare < 0.03
        if voicedSeconds >= 3, held > maximumHeldNoteShare || continuousSound {
            warnings.append(.music)
        }

        let snr = signalToNoise(frames)
        if let snr, snr < minimumSignalToNoiseDb {
            warnings.append(.noisy)
        }

        if voicedSeconds < minimumVoicedSeconds || (duration > 0 && voicedSeconds / duration < 0.25) {
            warnings.append(.littleSpeech)
        }
        if clippedFraction > maximumClippedFraction {
            warnings.append(.clipping)
        }
        if duration < recommendedDuration.lowerBound {
            warnings.append(.shortSelection)
        } else if duration > recommendedDuration.upperBound {
            warnings.append(.longSelection)
        }

        return ClipQualityReport(
            warnings: warnings,
            voicedSeconds: voicedSeconds,
            signalToNoiseDb: snr,
            heldNoteShare: held,
            speakerSeparationSemitones: split?.separation
        )
    }

    /// Median level of voiced frames minus the 10th-percentile level of all
    /// frames (the pauses, or the background under the voice).
    static func signalToNoise(_ frames: [ClipFrameSummary]) -> Double? {
        let voiced = frames.filter { $0.pitch != nil }.map { max($0.levelDb, -100) }
        guard voiced.count >= 10, let speech = PitchMath.median(of: voiced) else { return nil }
        let all = frames.map { max($0.levelDb, -100) }.sorted()
        let index = min(all.count - 1, max(0, Int((Double(all.count - 1) * 0.1).rounded())))
        return speech - all[index]
    }

    /// Share of voiced time spent on notes held steady for a while (singing
    /// and instruments hold notes; speech keeps moving).
    static func heldNoteShare(_ frames: [ClipFrameSummary], frameInterval: Double) -> Double {
        var voicedCount = 0
        var heldCount = 0
        var run: [Double] = []
        var lastTime = -Double.infinity

        func closeRun() {
            if Double(run.count) * frameInterval >= heldNoteDuration {
                heldCount += run.count
            }
            run = []
        }

        for frame in frames {
            guard let pitch = frame.pitch, pitch > 0 else { continue }
            voicedCount += 1
            let semitones = 12 * log2(pitch / 100)
            let continues = frame.time - lastTime <= frameInterval * 1.5
            if !run.isEmpty, continues {
                let mean = run.reduce(0, +) / Double(run.count)
                if abs(semitones - mean) <= heldNoteTolerance {
                    run.append(semitones)
                } else {
                    closeRun()
                    run = [semitones]
                }
            } else {
                closeRun()
                run = [semitones]
            }
            lastTime = frame.time
        }
        closeRun()
        return voicedCount > 0 ? Double(heldCount) / Double(voicedCount) : 0
    }

    /// The best split of phrase pitches into a low and a high group.
    /// - Returns: The distance between the groups (semitones), the voiced-time
    ///   share of the smaller group, and the spread inside the groups.
    static func speakerSplit(_ phrases: [VoicedSpan]) -> (separation: Double, smallerShare: Double, spread: Double)? {
        let values = phrases
            .filter { $0.pitches.count >= 20 }
            .compactMap { phrase in phrase.medianSemitones.map { (value: $0, weight: Double(phrase.pitches.count)) } }
            .sorted { $0.value < $1.value }
        guard values.count >= 4 else { return nil }

        var best: (cost: Double, split: Int)?
        for split in 1..<values.count {
            let cost = sumOfSquares(values[..<split]) + sumOfSquares(values[split...])
            if best == nil || cost < (best?.cost ?? .infinity) {
                best = (cost, split)
            }
        }
        guard let best else { return nil }
        let low = values[..<best.split]
        let high = values[best.split...]
        let separation = weightedMean(high) - weightedMean(low)
        let lowWeight = low.reduce(0) { $0 + $1.weight }
        let highWeight = high.reduce(0) { $0 + $1.weight }
        let total = lowWeight + highWeight
        guard total > 0 else { return nil }
        let spread = (best.cost / total).squareRoot()
        return (separation, min(lowWeight, highWeight) / total, spread)
    }

    private static func weightedMean(_ values: ArraySlice<(value: Double, weight: Double)>) -> Double {
        let weight = values.reduce(0) { $0 + $1.weight }
        guard weight > 0 else { return 0 }
        return values.reduce(0) { $0 + $1.value * $1.weight } / weight
    }

    private static func sumOfSquares(_ values: ArraySlice<(value: Double, weight: Double)>) -> Double {
        let mean = weightedMean(values)
        return values.reduce(0) { $0 + $1.weight * ($1.value - mean) * ($1.value - mean) }
    }

    /// Share of samples at or near full scale.
    static func clippedFraction(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let clipped = samples.reduce(into: 0) { count, sample in
            if abs(sample) >= clippingThreshold {
                count += 1
            }
        }
        return Double(clipped) / Double(samples.count)
    }
}

// MARK: - Shadowing segments

/// A short piece of the target clip to listen to and repeat.
nonisolated struct ShadowingSegment: Identifiable, Sendable, Equatable {
    let index: Int
    /// Seconds from the start of the saved clip.
    let start: Double
    let end: Double

    var id: Int { index }
    var duration: Double { end - start }
}

nonisolated enum ShadowingSegmenter {
    /// Groups phrases into pieces of up to `maximum` seconds, skipping pieces
    /// shorter than `minimum`, with a little padding on each side.
    static func segments(
        phrases: [VoicedSpan],
        clipDuration: Double,
        minimum: Double = 1.2,
        maximum: Double = 6,
        padding: Double = 0.2,
        limit: Int = 12
    ) -> [ShadowingSegment] {
        var groups: [(start: Double, end: Double)] = []
        var current: (start: Double, end: Double)?
        for phrase in phrases {
            if let group = current, phrase.end - group.start <= maximum {
                current = (group.start, phrase.end)
            } else {
                if let group = current {
                    groups.append(group)
                }
                current = (phrase.start, min(phrase.end, phrase.start + maximum))
            }
        }
        if let group = current {
            groups.append(group)
        }

        var result: [ShadowingSegment] = []
        for group in groups where group.end - group.start >= minimum {
            guard result.count < limit else { break }
            result.append(ShadowingSegment(
                index: result.count,
                start: max(0, group.start - padding),
                end: min(clipDuration, group.end + padding)
            ))
        }
        return result
    }
}

// MARK: - Trimming and the waveform

/// The section of an imported clip to analyze.
nonisolated struct TrimSelection: Sendable, Equatable {
    static let minimumLength = 3.0
    static let maximumLength = 120.0
    /// The first stretch selected when a clip opens.
    static let initialLength = 30.0

    let clipDuration: Double
    private(set) var start: Double
    private(set) var end: Double

    init(clipDuration: Double, start: Double = 0, end: Double? = nil) {
        let total = max(0, clipDuration)
        var lower = min(max(start, 0), total)
        var upper = min(max(end ?? total, 0), total)
        if upper < lower {
            swap(&lower, &upper)
        }
        let minimum = min(TrimSelection.minimumLength, total)
        if upper - lower < minimum {
            upper = min(total, lower + minimum)
            lower = max(0, upper - minimum)
        }
        if upper - lower > TrimSelection.maximumLength {
            upper = lower + TrimSelection.maximumLength
        }
        self.clipDuration = total
        self.start = lower
        self.end = upper
    }

    static func initial(clipDuration: Double) -> TrimSelection {
        TrimSelection(clipDuration: clipDuration, start: 0, end: min(clipDuration, initialLength))
    }

    var length: Double { end - start }

    /// Shortest allowed selection (the whole clip when it's shorter).
    var effectiveMinimum: Double { min(Self.minimumLength, clipDuration) }

    mutating func setStart(_ value: Double) {
        let lowest = max(0, end - Self.maximumLength)
        let highest = max(0, end - effectiveMinimum)
        start = min(max(value, lowest), highest)
    }

    mutating func setEnd(_ value: Double) {
        let lowest = min(clipDuration, start + effectiveMinimum)
        let highest = min(clipDuration, start + Self.maximumLength)
        end = min(max(value, lowest), highest)
    }
}

nonisolated enum WaveformSummary {
    /// The loudest sample in each of `bucketCount` equal slices, scaled so
    /// the loudest slice is 1 (quiet clips stay visible).
    static func peaks(_ samples: [Float], bucketCount: Int) -> [Float] {
        guard bucketCount > 0, !samples.isEmpty else { return [] }
        var peaks = [Float](repeating: 0, count: bucketCount)
        let perBucket = Double(samples.count) / Double(bucketCount)
        for bucket in 0..<bucketCount {
            let lower = Int((Double(bucket) * perBucket).rounded(.down))
            let upper = min(samples.count, max(lower + 1, Int((Double(bucket + 1) * perBucket).rounded(.down))))
            guard lower < upper else { continue }
            var peak: Float = 0
            for index in lower..<upper {
                peak = max(peak, abs(samples[index]))
            }
            peaks[bucket] = peak
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}

// MARK: - Analysis

/// Everything measured in the selected section of a target clip.
nonisolated struct TargetClipReport: Sendable, Equatable {
    let take: TakeResult
    let quality: ClipQualityReport
    let segments: [ShadowingSegment]
    let duration: Double
}

nonisolated enum TargetClipAnalyzer {
    /// Clips are decoded at this rate (the analysis works at any rate).
    static let sampleRate = 44_100.0

    /// Runs the full voice analysis over `range` (seconds) of the clip.
    static func analyze(_ clip: AudioClip, range: ClosedRange<Double>, target: PitchTargetZone) -> TargetClipReport {
        let rate = clip.sampleRate
        let lower = min(clip.samples.count, max(0, Int((range.lowerBound * rate).rounded())))
        let upper = min(clip.samples.count, max(lower, Int((range.upperBound * rate).rounded())))
        let section = Array(clip.samples[lower..<upper])
        let duration = rate > 0 ? Double(section.count) / rate : 0

        let configuration = AnalysisConfiguration(sampleRate: rate)
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        var analyzer = TakeAnalyzer(target: target, frameInterval: configuration.hopDuration)
        var summaries: [ClipFrameSummary] = []

        let chunk = 4_096
        var position = 0
        while position < section.count {
            let next = min(section.count, position + chunk)
            let frames = pipeline.process(Array(section[position..<next]))
            for frame in frames {
                analyzer.add(frame)
                summaries.append(ClipFrameSummary(frame))
            }
            position = next
        }

        let phrases = VoicedSpans.phrases(summaries, frameInterval: configuration.hopDuration)
        let quality = ClipQualityChecker.check(
            frames: summaries,
            phrases: phrases,
            frameInterval: configuration.hopDuration,
            duration: duration,
            clippedFraction: ClipQualityChecker.clippedFraction(section)
        )
        return TargetClipReport(
            take: analyzer.result(),
            quality: quality,
            segments: ShadowingSegmenter.segments(phrases: phrases, clipDuration: duration),
            duration: duration
        )
    }

    /// The samples in `range` (seconds), for saving the trimmed clip.
    static func section(of clip: AudioClip, range: ClosedRange<Double>) -> AudioClip {
        let rate = clip.sampleRate
        let lower = min(clip.samples.count, max(0, Int((range.lowerBound * rate).rounded())))
        let upper = min(clip.samples.count, max(lower, Int((range.upperBound * rate).rounded())))
        return AudioClip(samples: Array(clip.samples[lower..<upper]), sampleRate: rate, startTime: 0)
    }
}

// MARK: - Shadowing material

/// A saved target clip, analyzed for shadowing: its phrases and pitch contour.
nonisolated struct ShadowingMaterial: Sendable {
    let clip: AudioClip
    /// Voiced pitch over the whole clip (seconds from the clip start).
    let contour: [PitchContourPoint]
    let segments: [ShadowingSegment]

    init(clip: AudioClip, contour: [PitchContourPoint], segments: [ShadowingSegment]) {
        self.clip = clip
        self.contour = contour
        self.segments = segments
    }

    /// Reads and analyzes a saved clip (slow: call off the main thread).
    static func load(url: URL, target: PitchTargetZone) throws -> ShadowingMaterial {
        let clip = try RecordingFileStore.readSamples(from: url)
        let report = TargetClipAnalyzer.analyze(clip, range: 0...clip.duration, target: target)
        // The take's contour starts at its first frame (half a frame in).
        let offset = AnalysisConfiguration(sampleRate: clip.sampleRate).frameDuration / 2
        let contour = report.take.contour.map { PitchContourPoint(time: $0.time + offset, frequency: $0.frequency) }
        return ShadowingMaterial(clip: clip, contour: contour, segments: report.segments)
    }

    /// The contour inside a segment, timed from the segment's start.
    func contour(for segment: ShadowingSegment) -> [PitchContourPoint] {
        contour
            .filter { $0.time >= segment.start && $0.time <= segment.end }
            .map { PitchContourPoint(time: $0.time - segment.start, frequency: $0.frequency) }
    }
}
