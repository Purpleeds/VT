import Foundation

// MARK: - Settings

/// How far Voice Preview moves a recording (SPEC section 8).
nonisolated struct VoicePreviewSettings: Sendable, Equatable {
    /// Pitch change in semitones (12 = one octave).
    static let pitchRange: ClosedRange<Double> = -6...12
    /// Resonance change: how much the formants (the vocal tract's
    /// resonances) move, in percent. +15 % is roughly the difference between
    /// typical adult male and female averages.
    static let resonanceRange: ClosedRange<Double> = -10...20

    var pitchSemitones: Double = 0
    var resonancePercent: Double = 0

    init(pitchSemitones: Double = 0, resonancePercent: Double = 0) {
        self.pitchSemitones = min(max(pitchSemitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        self.resonancePercent = min(max(resonancePercent, Self.resonanceRange.lowerBound), Self.resonanceRange.upperBound)
    }

    /// Multiplier for the fundamental frequency.
    var pitchFactor: Double {
        pow(2, min(max(pitchSemitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound) / 12)
    }

    /// Multiplier for every formant frequency.
    var formantFactor: Double {
        1 + min(max(resonancePercent, Self.resonanceRange.lowerBound), Self.resonanceRange.upperBound) / 100
    }

    var isUnchanged: Bool { abs(pitchSemitones) < 0.01 && abs(resonancePercent) < 0.01 }

    /// Settings that move a recording toward a target: the pitch from the
    /// recording's median to the target, and the resonance by the ratio of
    /// the target F2 to the recording's F2 (both measured in running speech).
    /// Pitch is rounded to half semitones and resonance to whole percent.
    static func toward(
        sourcePitch: Double?,
        targetPitch: Double?,
        sourceF2: Double?,
        targetF2: Double?
    ) -> VoicePreviewSettings {
        var pitch = 0.0
        if let sourcePitch, let targetPitch, sourcePitch > 0, targetPitch > 0 {
            pitch = (2 * 12 * log2(targetPitch / sourcePitch)).rounded() / 2
        }
        var resonance = 0.0
        if let sourceF2, let targetF2, sourceF2 > 0, targetF2 > 0 {
            resonance = ((targetF2 / sourceF2 - 1) * 100).rounded()
        }
        return VoicePreviewSettings(pitchSemitones: pitch, resonancePercent: resonance)
    }
}

// MARK: - Pitch track

/// One point of a pitch track (nil frequency = no clear pitch).
nonisolated struct PitchTrackPoint: Sendable, Equatable {
    /// Seconds from the start of the recording (centre of the analysis frame).
    let time: Double
    let frequency: Double?
}

/// Turns frame-by-frame pitch into a pitch period for every sample.
nonisolated enum VoicePeriodTrack {
    /// Unvoiced gaps shorter than this inside a voiced stretch are bridged
    /// (a held octave jump, a short dropout), so the voice isn't chopped.
    static let maximumGap = 0.04

    /// - Returns: The local pitch period (in samples) at every sample, or 0
    ///   where there is no clear pitch.
    static func periods(points: [PitchTrackPoint], sampleCount: Int, sampleRate: Double) -> [Float] {
        var periods = [Float](repeating: 0, count: max(0, sampleCount))
        guard sampleCount > 0, sampleRate > 0, !points.isEmpty else { return periods }

        let sorted = points.sorted { $0.time < $1.time }
        let times = sorted.map(\.time)
        // Only usable pitches count (finite, inside the speaking range).
        var frequencies: [Double?] = sorted.map { point in
            guard let frequency = point.frequency, frequency.isFinite, frequency >= 40, frequency <= 1_200 else { return nil }
            return frequency
        }
        let hop = times.count > 1 ? max((times[times.count - 1] - times[0]) / Double(times.count - 1), 1e-4) : 0.01

        // 1. Bridge short gaps by interpolating between the voiced neighbours.
        let gapLimit = max(0, Int((maximumGap / hop).rounded(.down)))
        var index = 0
        while index < frequencies.count {
            guard frequencies[index] == nil else {
                index += 1
                continue
            }
            var end = index
            while end < frequencies.count, frequencies[end] == nil {
                end += 1
            }
            // frequencies[index..<end] is a gap.
            if index > 0, end < frequencies.count, end - index <= gapLimit,
               let before = frequencies[index - 1], let after = frequencies[end] {
                for gap in index..<end {
                    let fraction = Double(gap - index + 1) / Double(end - index + 1)
                    frequencies[gap] = before + (after - before) * fraction
                }
            }
            index = end
        }

        // 2. Fill each voiced run, interpolating the frequency between frames.
        var start = 0
        while start < frequencies.count {
            guard frequencies[start] != nil else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < frequencies.count, frequencies[end + 1] != nil {
                end += 1
            }
            let firstSample = max(0, Int(((times[start] - hop / 2) * sampleRate).rounded()))
            let lastSample = min(sampleCount, Int(((times[end] + hop / 2) * sampleRate).rounded()))
            if firstSample < lastSample {
                var frame = start
                for sample in firstSample..<lastSample {
                    let time = Double(sample) / sampleRate
                    while frame < end, times[frame + 1] <= time {
                        frame += 1
                    }
                    let frequency: Double
                    if let current = frequencies[frame] {
                        if frame < end, let next = frequencies[frame + 1], time > times[frame] {
                            let span = times[frame + 1] - times[frame]
                            let fraction = span > 0 ? min(max((time - times[frame]) / span, 0), 1) : 0
                            frequency = current + (next - current) * fraction
                        } else {
                            frequency = current
                        }
                    } else {
                        frequency = 0
                    }
                    if frequency > 0 {
                        periods[sample] = Float(sampleRate / frequency)
                    }
                }
            }
            start = end + 1
        }
        return periods
    }
}

// MARK: - Shifting

/// Pitch and formant shifting by pitch-synchronous overlap-add (TD-PSOLA).
///
/// The idea: voiced speech is a train of glottal pulses, each one "ringing"
/// the vocal tract. Cut the recording into two-period slices centred one
/// period apart (analysis marks), then lay the slices down again:
/// - closer together → each pulse comes sooner → higher pitch, while each
///   slice keeps its own ringing, so the formants stay where they were;
/// - squeezing each slice in time (resampling it by the formant factor)
///   raises the ringing frequencies, so the formants move up by that factor.
/// Unvoiced sounds (s, f, breath) are passed through unchanged.
///
/// This is a rough preview: it doesn't change vocal weight, intonation or
/// articulation, and big shifts sound processed.
nonisolated enum PitchSynchronousShifter {
    /// Slice spacing in unvoiced stretches.
    static let unvoicedPeriodSeconds = 0.01

    /// One analysis mark: the centre of a pitch pulse and the period there.
    nonisolated struct Mark: Sendable, Equatable {
        let position: Double
        let period: Double
    }

    /// Places analysis marks one period apart through each voiced run,
    /// starting at the largest sample in the run's first period so the
    /// slices are centred on the pulses.
    static func analysisMarks(samples: [Float], periods: [Float]) -> [Mark] {
        let count = min(samples.count, periods.count)
        var marks: [Mark] = []
        var index = 0
        while index < count {
            guard periods[index] > 1 else {
                index += 1
                continue
            }
            let runStart = index
            while index < count, periods[index] > 1 {
                index += 1
            }
            let runEnd = index

            let firstPeriod = Int(Double(periods[runStart]).rounded(.up))
            let searchEnd = min(runEnd, runStart + max(1, firstPeriod))
            var peak = runStart
            for sample in runStart..<searchEnd where samples[sample] > samples[peak] {
                peak = sample
            }
            var position = Double(peak)
            while position < Double(runEnd) {
                let period = Double(periods[min(Int(position), count - 1)])
                guard period > 1 else { break }
                marks.append(Mark(position: position, period: period))
                position += period
            }
        }
        return marks
    }

    /// Shifts pitch by `pitchFactor` and formants by `formantFactor`.
    /// - Parameter periods: Pitch period per sample (0 = unvoiced), from
    ///   `VoicePeriodTrack.periods`.
    /// - Returns: A recording of the same length.
    static func shift(
        _ samples: [Float],
        periods: [Float],
        sampleRate: Double,
        pitchFactor: Double,
        formantFactor: Double
    ) -> [Float] {
        let count = samples.count
        guard count > 1, periods.count == count, sampleRate > 0,
              pitchFactor.isFinite, formantFactor.isFinite, pitchFactor > 0, formantFactor > 0
        else { return samples }

        let marks = analysisMarks(samples: samples, periods: periods)
        let unvoicedPeriod = max(2, sampleRate * unvoicedPeriodSeconds)
        var output = [Float](repeating: 0, count: count)
        var weights = [Float](repeating: 0, count: count)

        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                weights.withUnsafeMutableBufferPointer { weight in
                    var time = 0.0
                    var markIndex = 0
                    while time < Double(count) {
                        let period = Double(periods[min(Int(time), count - 1)])

                        // Find the analysis mark nearest to this output time.
                        var mark: Mark?
                        if period > 1, !marks.isEmpty {
                            while markIndex + 1 < marks.count,
                                  abs(marks[markIndex + 1].position - time) <= abs(marks[markIndex].position - time) {
                                markIndex += 1
                            }
                            let nearest = marks[markIndex]
                            if abs(nearest.position - time) <= nearest.period {
                                mark = nearest
                            }
                        }

                        let center: Double
                        let halfWidth: Double
                        let squeeze: Double
                        let step: Double
                        if let mark {
                            // Voiced: a two-period slice, squeezed by the
                            // formant factor, placed one *new* period on.
                            center = mark.position
                            halfWidth = mark.period / formantFactor
                            squeeze = formantFactor
                            step = period / pitchFactor
                        } else {
                            // Unvoiced: copy the sound through unchanged.
                            center = time
                            halfWidth = unvoicedPeriod
                            squeeze = 1
                            step = unvoicedPeriod
                        }

                        addSlice(
                            from: input, center: center, squeeze: squeeze,
                            to: out, weights: weight, at: time, halfWidth: halfWidth
                        )
                        time += max(step, 1)
                    }

                    // Overlapping slices are averaged (never amplified), so
                    // raising the pitch doesn't pile up loudness.
                    for index in 0..<count where weight[index] > 1 {
                        out[index] /= weight[index]
                    }
                }
            }
        }
        return matchLoudness(output, to: samples)
    }

    /// Adds one Hann-windowed slice of `input` (centred on `center`, read
    /// `squeeze` times faster) to `output`, centred on `time`.
    private static func addSlice(
        from input: UnsafeBufferPointer<Float>,
        center: Double,
        squeeze: Double,
        to output: UnsafeMutableBufferPointer<Float>,
        weights: UnsafeMutableBufferPointer<Float>,
        at time: Double,
        halfWidth: Double
    ) {
        guard halfWidth > 0 else { return }
        let first = max(0, Int((time - halfWidth).rounded(.up)))
        let last = min(output.count - 1, Int((time + halfWidth).rounded(.down)))
        guard first <= last else { return }
        for index in first...last {
            let offset = Double(index) - time
            let window = Float(0.5 + 0.5 * cos(Double.pi * offset / halfWidth))
            let source = center + offset * squeeze
            output[index] += window * interpolate(input, at: source)
            weights[index] += window
        }
    }

    /// Linear interpolation (0 outside the recording).
    private static func interpolate(_ input: UnsafeBufferPointer<Float>, at position: Double) -> Float {
        guard position >= 0 else { return 0 }
        let index = Int(position)
        guard index + 1 < input.count else {
            return index < input.count ? input[index] : 0
        }
        let fraction = Float(position - Double(index))
        return input[index] + (input[index + 1] - input[index]) * fraction
    }

    /// Scales the result to the original's loudness (RMS), never past a
    /// 0.95 peak.
    static func matchLoudness(_ output: [Float], to original: [Float]) -> [Float] {
        let originalRMS = rms(original)
        let outputRMS = rms(output)
        guard originalRMS > 1e-6, outputRMS > 1e-6 else { return output }
        var gain = min(max(originalRMS / outputRMS, 0.5), 4)
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        if peak * gain > 0.95 {
            gain = 0.95 / peak
        }
        return output.map { $0 * gain }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}

// MARK: - Source recording

/// A recording prepared for Voice Preview: its pitch periods and the
/// measurements the "toward my target" suggestion needs.
nonisolated struct VoicePreviewSource: Sendable {
    /// Longer recordings are cut to this length to keep previews quick.
    static let maximumDuration = 20.0
    /// Shorter recordings can't say much.
    static let minimumVoicedDuration = 1.0

    let clip: AudioClip
    let periods: [Float]
    let medianPitch: Double?
    let f2: Double?
    let voicedDuration: Double

    var hasEnoughVoice: Bool { voicedDuration >= Self.minimumVoicedDuration }

    /// Analyzes a recording (slow: call off the main thread).
    static func analyze(_ clip: AudioClip) -> VoicePreviewSource {
        let limit = Int(maximumDuration * clip.sampleRate)
        let samples = clip.samples.count > limit ? Array(clip.samples.prefix(limit)) : clip.samples
        let trimmed = AudioClip(samples: samples, sampleRate: clip.sampleRate, startTime: 0)
        guard clip.sampleRate >= 8_000, !samples.isEmpty else {
            return VoicePreviewSource(clip: trimmed, periods: [Float](repeating: 0, count: samples.count), medianPitch: nil, f2: nil, voicedDuration: 0)
        }

        let configuration = AnalysisConfiguration(sampleRate: clip.sampleRate)
        let pipeline = VoiceAnalysisPipeline(configuration: configuration)
        var analyzer = TakeAnalyzer(target: .feminine, frameInterval: configuration.hopDuration)
        var points: [PitchTrackPoint] = []
        let chunk = 4_096
        var position = 0
        while position < samples.count {
            let next = min(samples.count, position + chunk)
            for frame in pipeline.process(Array(samples[position..<next])) {
                analyzer.add(frame)
                points.append(PitchTrackPoint(time: frame.time, frequency: trackFrequency(of: frame)))
            }
            position = next
        }
        let take = analyzer.result()
        return VoicePreviewSource(
            clip: trimmed,
            periods: VoicePeriodTrack.periods(points: points, sampleCount: samples.count, sampleRate: clip.sampleRate),
            medianPitch: take.medianPitch,
            f2: take.f2,
            voicedDuration: take.voicedDuration
        )
    }

    /// The pitch used for shifting: the filtered pitch of voiced frames, and
    /// the held pitch while a sudden jump is being checked.
    static func trackFrequency(of frame: VoiceFrame) -> Double? {
        switch frame.status {
        case .voiced:
            return frame.filteredFrequency
        case .octaveJumpHeld:
            return frame.displayFrequency
        case .unpitched, .belowNoiseGate:
            return nil
        }
    }

    /// The shifted recording (slow: call off the main thread).
    func render(_ settings: VoicePreviewSettings) -> AudioClip {
        guard !settings.isUnchanged else { return clip }
        let shifted = PitchSynchronousShifter.shift(
            clip.samples,
            periods: periods,
            sampleRate: clip.sampleRate,
            pitchFactor: settings.pitchFactor,
            formantFactor: settings.formantFactor
        )
        return AudioClip(samples: shifted, sampleRate: clip.sampleRate, startTime: 0)
    }
}
