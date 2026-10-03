import Foundation

// MARK: - Options

/// What a Pitch Track was made from (SPEC section 22).
nonisolated enum PitchTrackKind: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Talking: bars follow the natural, curved pitch line of each syllable.
    case speech
    /// Singing: bars are flat notes snapped to the nearest semitone.
    case singing
    /// Generated exercises (sirens, scales, intonation patterns).
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: "Speech"
        case .singing: "Singing"
        case .builtIn: "Exercise"
        }
    }

    var systemImage: String {
        switch self {
        case .speech: "text.bubble"
        case .singing: "music.note"
        case .builtIn: "figure.walk.motion"
        }
    }
}

/// How close the pitch must be to count as on the bar (SPEC section 22.1).
nonisolated enum TrackDifficulty: String, CaseIterable, Identifiable, Sendable, Codable {
    case easy
    case medium
    case hard

    var id: String { rawValue }

    /// Allowed distance from the bar (cents).
    var toleranceCents: Double {
        switch self {
        case .easy: 100
        case .medium: 50
        case .hard: 25
        }
    }

    var title: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }

    /// e.g. "Easy (±100 cents)".
    var detail: String {
        "\(title) (±\(toleranceCents.roundedInt) cents)"
    }
}

/// What plays while the bars scroll (SPEC sections 22.1 and 23.4).
nonisolated enum TrackAudioMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case original
    /// The split's vocals on their own (split tracks only).
    case vocalsOnly
    /// The split's instrumental, karaoke style (split tracks only).
    case backingOnly
    /// Synthesized notes that follow the bars.
    case guideTones
    /// Bars only.
    case silent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original Audio"
        case .vocalsOnly: "Vocals Only"
        case .backingOnly: "Backing Only (Karaoke)"
        case .guideTones: "Guide Tones Only"
        case .silent: "Silent (Bars Only)"
        }
    }

    var systemImage: String {
        switch self {
        case .original: "waveform"
        case .vocalsOnly: "person.wave.2"
        case .backingOnly: "music.mic"
        case .guideTones: "pianokeys"
        case .silent: "speaker.slash"
        }
    }

    /// Modes that play sound, which the microphone would also hear.
    var makesSound: Bool { self != .silent }

    /// Modes that need the split's vocals and backing files.
    var needsSplit: Bool { self == .vocalsOnly || self == .backingOnly }

    /// The modes a track can offer.
    static func available(hasOriginalAudio: Bool, hasSplit: Bool) -> [TrackAudioMode] {
        allCases.filter { mode in
            switch mode {
            case .original:
                return hasOriginalAudio || hasSplit
            case .vocalsOnly, .backingOnly:
                return hasSplit
            case .guideTones, .silent:
                return true
            }
        }
    }
}

// MARK: - Bars

/// One point of a curved bar: semitones (MIDI) at a time.
nonisolated struct TrackContourPoint: Sendable, Equatable, Codable {
    /// Seconds from the start of the track.
    var time: Double
    var midi: Double
}

/// A bar's resonance target: the formants measured in that part of the clip
/// (or the user's own targets for built-in tracks), and their 0–100 score.
nonisolated struct BarResonance: Sendable, Equatable, Codable {
    var f1: Double?
    var f2: Double?
    var f3: Double?
    /// Brightness on the user's own scale (0 = their baseline, 100 = target).
    var score: Double?
}

/// A target bar (SPEC section 22.1: start, duration, pitch, resonance,
/// weight, loudness, word).
nonisolated struct TrackBar: Sendable, Equatable, Codable, Identifiable {
    var index: Int
    /// Seconds from the start of the track.
    var start: Double
    var duration: Double
    /// Pitch in semitones (MIDI note numbers, may be fractional). For curved
    /// bars this is the median of the contour.
    var midi: Double
    /// Empty for flat bars; otherwise the pitch line to follow.
    var contour: [TrackContourPoint]
    var resonance: BarResonance?
    /// Vocal weight on the user's scale (0 = heavy baseline, 100 = light target).
    var weightScore: Double?
    /// Median loudness (dBFS) of the clip during the bar.
    var loudnessDb: Double?
    var word: String?

    init(
        index: Int,
        start: Double,
        duration: Double,
        midi: Double,
        contour: [TrackContourPoint] = [],
        resonance: BarResonance? = nil,
        weightScore: Double? = nil,
        loudnessDb: Double? = nil,
        word: String? = nil
    ) {
        self.index = index
        self.start = start
        self.duration = duration
        self.midi = midi
        self.contour = contour
        self.resonance = resonance
        self.weightScore = weightScore
        self.loudnessDb = loudnessDb
        self.word = word
    }

    var id: Int { index }
    var end: Double { start + duration }
    var isCurved: Bool { contour.count >= 2 }
    var frequency: Double { PitchMath.frequency(forMidiNote: midi) }
    var noteName: String { PitchMath.noteName(for: frequency) ?? "" }

    /// The pitch to match at `time` (seconds from the track start).
    func targetMidi(at time: Double) -> Double {
        guard isCurved, let first = contour.first, let last = contour.last else { return midi }
        if time <= first.time { return first.midi }
        if time >= last.time { return last.midi }
        // Binary search for the surrounding points.
        var low = 0
        var high = contour.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if contour[middle].time <= time {
                low = middle
            } else {
                high = middle
            }
        }
        let a = contour[low]
        let b = contour[high]
        let span = b.time - a.time
        guard span > 0 else { return a.midi }
        return a.midi + (b.midi - a.midi) * (time - a.time) / span
    }

    /// Lowest and highest pitch of the bar.
    var pitchSpan: ClosedRange<Double> {
        guard isCurved else { return midi...midi }
        let values = contour.map(\.midi)
        return (values.min() ?? midi)...(values.max() ?? midi)
    }

    func transposed(by semitones: Double) -> TrackBar {
        guard semitones != 0 else { return self }
        var bar = self
        bar.midi += semitones
        bar.contour = contour.map { TrackContourPoint(time: $0.time, midi: $0.midi + semitones) }
        return bar
    }
}

// MARK: - Settings

/// A section to repeat (SPEC section 22.1: loop a section).
nonisolated struct TrackLoop: Sendable, Equatable, Codable {
    static let minimumLength = 2.0

    let start: Double
    let end: Double

    /// Keeps the section inside the track and at least two seconds long.
    init(start: Double, end: Double, trackDuration: Double) {
        let total = max(trackDuration, 0)
        var lower = min(max(min(start, end), 0), total)
        var upper = min(max(max(start, end), 0), total)
        let minimum = min(Self.minimumLength, total)
        if upper - lower < minimum {
            upper = min(total, lower + minimum)
            lower = max(0, upper - minimum)
        }
        self.start = lower
        self.end = upper
    }

    var length: Double { end - start }
}

/// Everything the user can change before playing (SPEC section 22.1).
nonisolated struct TrackSettings: Sendable, Equatable, Codable {
    static let transposeRange = -12...12
    static let speedRange = 0.5...1.0
    static let speedStep = 0.05

    private(set) var transpose = 0
    private(set) var speed = 1.0
    var loop: TrackLoop?
    var difficulty = TrackDifficulty.medium
    var scoresResonanceAndWeight = false
    var audioMode = TrackAudioMode.guideTones

    init(
        transpose: Int = 0,
        speed: Double = 1,
        loop: TrackLoop? = nil,
        difficulty: TrackDifficulty = .medium,
        scoresResonanceAndWeight: Bool = false,
        audioMode: TrackAudioMode = .guideTones
    ) {
        self.loop = loop
        self.difficulty = difficulty
        self.scoresResonanceAndWeight = scoresResonanceAndWeight
        self.audioMode = audioMode
        setTranspose(transpose)
        setSpeed(speed)
    }

    /// Defaults for a new track: resonance and weight are scored for speech;
    /// split songs play the backing (karaoke); clips play the original.
    static func defaults(kind: PitchTrackKind, hasOriginalAudio: Bool, hasSplit: Bool, isSpeechPattern: Bool = false) -> TrackSettings {
        let mode: TrackAudioMode
        if hasSplit {
            mode = .backingOnly
        } else if hasOriginalAudio {
            mode = .original
        } else {
            mode = .guideTones
        }
        let scores = kind == .speech || (kind == .builtIn && isSpeechPattern)
        return TrackSettings(scoresResonanceAndWeight: scores, audioMode: mode)
    }

    mutating func setTranspose(_ value: Int) {
        transpose = min(max(value, Self.transposeRange.lowerBound), Self.transposeRange.upperBound)
    }

    /// Rounded to 5 % steps, 50–100 %.
    mutating func setSpeed(_ value: Double) {
        let stepped = (value / Self.speedStep).rounded() * Self.speedStep
        speed = min(max(stepped, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// The part of the track that plays: the loop, or everything.
    func playRange(trackDuration: Double) -> ClosedRange<Double> {
        if let loop, loop.end > loop.start {
            return loop.start...min(loop.end, trackDuration)
        }
        return 0...max(trackDuration, 0)
    }
}

// MARK: - Track content

/// The bars of a track and what was detected about it.
nonisolated struct PitchTrackContent: Sendable, Equatable {
    var kind: PitchTrackKind
    /// Seconds.
    var duration: Double
    var bars: [TrackBar]
    /// How far the clip's tuning is from A = 440 Hz (cents, −50…50); singing only.
    var tuningOffsetCents: Double?

    init(kind: PitchTrackKind, duration: Double, bars: [TrackBar], tuningOffsetCents: Double? = nil) {
        self.kind = kind
        self.duration = duration
        self.bars = bars
        self.tuningOffsetCents = tuningOffsetCents
    }

    /// Lowest and highest pitch the bars ask for (semitones), or nil without bars.
    var range: ClosedRange<Double>? {
        TrackRange.span(of: bars)
    }

    /// Bars shifted by `transpose` semitones and limited to `range`
    /// (bars that start inside the range).
    func playableBars(transpose: Int, range: ClosedRange<Double>) -> [TrackBar] {
        bars
            .filter { $0.start >= range.lowerBound - 0.001 && $0.start < range.upperBound }
            .map { $0.transposed(by: Double(transpose)) }
    }
}

/// Steps shown while a track is being made.
nonisolated enum TrackBuildStage: Int, CaseIterable, Sendable, Comparable {
    case detectingPitch
    case measuringResonance
    case buildingTrack
    case findingWords

    var title: String {
        switch self {
        case .detectingPitch: "Detecting pitch…"
        case .measuringResonance: "Measuring resonance…"
        case .buildingTrack: "Building track…"
        case .findingWords: "Finding the words…"
        }
    }

    static func < (lhs: TrackBuildStage, rhs: TrackBuildStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
