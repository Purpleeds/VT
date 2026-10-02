import Foundation

/// One point of a take's pitch line (for shadowing and comparisons).
nonisolated struct PitchContourPoint: Sendable, Equatable, Codable {
    /// Seconds from the start of the take.
    let time: Double
    let frequency: Double
}

/// Everything measured over one short take: a baseline reading, a placement
/// test part, a Quick Check, a scenario turn, or an imported target clip.
nonisolated struct TakeResult: Sendable, Equatable {
    /// Seconds of audio analyzed.
    let duration: Double
    /// Seconds of clearly voiced sound.
    let voicedDuration: Double
    let averagePitch: Double?
    let medianPitch: Double?
    /// 5th and 95th percentiles of pitch, so stray frames don't set the range.
    let lowPitch: Double?
    let highPitch: Double?
    let percentInTarget: Double?
    /// Medians over stable frames.
    let f1: Double?
    let f2: Double?
    let f3: Double?
    let resonanceScore: Double?
    /// Share (0–100) of stable frames whose rolling resonance is in the bright zone.
    let brightResonancePercent: Double?
    /// Median formant-corrected H1–H2 (dB).
    let h1MinusH2: Double?
    let spectralTilt: Double?
    let weightScore: Double?
    /// Share (0–100) of measured frames whose weight is in the light zone.
    let lightWeightPercent: Double?
    /// Average pitch variability of the take's phrases (semitones).
    let intonationSD: Double?
    let intonationScore: Double?
    let phraseCount: Int
    let contour: [PitchContourPoint]
    /// Share of voiced time in each 1-semitone bin from `histogramLowerBound`.
    let pitchHistogram: [Double]

    static let histogramLowerBound = 60.0
    static let histogramBinCount = 48

    var hasVoice: Bool { voicedDuration > 0 }

    /// Pitch histogram bin for a frequency (nil outside 60–960 Hz).
    static func histogramBin(for frequency: Double) -> Int? {
        guard frequency > 0, frequency.isFinite else { return nil }
        let bin = Int((12 * log2(frequency / histogramLowerBound)).rounded(.down))
        return (0..<histogramBinCount).contains(bin) ? bin : nil
    }

    /// Lowest frequency of a histogram bin.
    static func histogramFrequency(forBin bin: Int) -> Double {
        histogramLowerBound * pow(2, Double(bin) / 12)
    }
}

/// Collects a take's analysis frames and summarizes them, scoring them the
/// same way the live meters do.
nonisolated struct TakeAnalyzer: Sendable {
    let target: PitchTargetZone
    let frameInterval: Double
    private let weightReference: WeightReference
    private let intonationReference: IntonationReference
    private var resonanceMeter: ResonanceMeter
    private var phrases: IntonationAnalyzer

    private var startTime: Double?
    private var lastTime: Double?
    private var pitches: [Double] = []
    private var contour: [PitchContourPoint] = []
    private var f1Values: [Double] = []
    private var f2Values: [Double] = []
    private var f3Values: [Double] = []
    private var resonanceScores: [Double] = []
    private var brightFrames = 0
    private var resonanceFrames = 0
    private var harmonicValues: [Double] = []
    private var tiltValues: [Double] = []
    private var weightScores: [Double] = []
    private var lightFrames = 0
    private var phraseDeviations: [Double] = []

    init(
        target: PitchTargetZone,
        resonanceMode: ResonanceMode = .speech,
        references: PersonalReferences = .none,
        frameInterval: Double
    ) {
        self.target = target
        self.frameInterval = frameInterval
        weightReference = references.weight
        intonationReference = references.intonation
        resonanceMeter = ResonanceMeter(mode: resonanceMode, reference: references.resonance(for: resonanceMode))
        phrases = IntonationAnalyzer(frameInterval: frameInterval)
    }

    mutating func add(_ frame: VoiceFrame) {
        let start = startTime ?? frame.time
        startTime = start
        lastTime = frame.time

        let voicedPitch = frame.status == .voiced ? frame.filteredFrequency : nil
        if let pitch = voicedPitch {
            pitches.append(pitch)
            contour.append(PitchContourPoint(time: frame.time - start, frequency: pitch))
        }
        if let phrase = phrases.process(time: frame.time, frequency: voicedPitch) {
            phraseDeviations.append(phrase.standardDeviationSemitones)
        }

        if let formants = frame.formants {
            resonanceMeter.add(formants, at: frame.time)
            f1Values.append(formants.f1.frequency)
            f2Values.append(formants.f2.frequency)
            if let f3 = formants.f3 {
                f3Values.append(f3.frequency)
            }
            resonanceScores.append(resonanceMeter.score(for: formants))
            if let rolling = resonanceMeter.reading(now: frame.time) {
                resonanceFrames += 1
                if MeterZone(score: rolling.score) == .high {
                    brightFrames += 1
                }
            }
        }
        if let weight = frame.weight {
            harmonicValues.append(weight.effectiveH1MinusH2)
            if let tilt = weight.spectralTilt {
                tiltValues.append(tilt)
            }
            let score = weightReference.score(h1MinusH2: weight.effectiveH1MinusH2, spectralTilt: weight.spectralTilt)
            weightScores.append(score)
            if MeterZone(score: score) == .high {
                lightFrames += 1
            }
        }
    }

    /// The summary so far (the phrase in progress counts as finished).
    func result() -> TakeResult {
        var phrases = self.phrases
        var deviations = phraseDeviations
        if let last = phrases.finishPhrase() {
            deviations.append(last.standardDeviationSemitones)
        }
        let intonationSD = Self.mean(deviations)

        let sorted = pitches.sorted()
        var histogram = [Double](repeating: 0, count: TakeResult.histogramBinCount)
        for pitch in pitches {
            if let bin = TakeResult.histogramBin(for: pitch) {
                histogram[bin] += 1
            }
        }
        if !pitches.isEmpty {
            histogram = histogram.map { $0 / Double(pitches.count) }
        }

        let duration = (startTime.flatMap { start in lastTime.map { $0 - start } } ?? 0) + (startTime == nil ? 0 : frameInterval)

        return TakeResult(
            duration: duration,
            voicedDuration: Double(pitches.count) * frameInterval,
            averagePitch: Self.mean(pitches),
            medianPitch: PitchMath.median(of: pitches),
            lowPitch: Self.percentile(sorted, 0.05),
            highPitch: Self.percentile(sorted, 0.95),
            percentInTarget: pitches.isEmpty ? nil : Double(pitches.filter(target.contains).count) / Double(pitches.count) * 100,
            f1: PitchMath.median(of: f1Values),
            f2: PitchMath.median(of: f2Values),
            f3: PitchMath.median(of: f3Values),
            resonanceScore: Self.mean(resonanceScores),
            brightResonancePercent: resonanceFrames > 0 ? Double(brightFrames) / Double(resonanceFrames) * 100 : nil,
            h1MinusH2: PitchMath.median(of: harmonicValues),
            spectralTilt: PitchMath.median(of: tiltValues),
            weightScore: Self.mean(weightScores),
            lightWeightPercent: weightScores.isEmpty ? nil : Double(lightFrames) / Double(weightScores.count) * 100,
            intonationSD: intonationSD,
            intonationScore: intonationSD.map { intonationReference.score(standardDeviationSemitones: $0) },
            phraseCount: deviations.count,
            contour: contour,
            pitchHistogram: histogram
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
