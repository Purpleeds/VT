import Accelerate
import Foundation

/// What Mic Check's A/B test shows for one version of a take (SPEC section
/// 24.5): the same numbers the live meters use, measured offline.
nonisolated struct MicTakeReadings: Sendable, Equatable {
    var medianPitch: Double?
    /// Spread of the pitch around its median (cents, standard deviation).
    var pitchSpreadCents: Double?
    /// Seconds of clearly voiced sound.
    var voicedSeconds: Double
    var f2: Double?
    /// Formant-corrected H1–H2 (dB).
    var h1MinusH2: Double?
    /// Level of the quiet parts between words (dBFS).
    var backgroundDb: Double?
    /// Level of the loud parts, the voice (dBFS).
    var voiceDb: Double?

    init(
        medianPitch: Double? = nil,
        pitchSpreadCents: Double? = nil,
        voicedSeconds: Double = 0,
        f2: Double? = nil,
        h1MinusH2: Double? = nil,
        backgroundDb: Double? = nil,
        voiceDb: Double? = nil
    ) {
        self.medianPitch = medianPitch
        self.pitchSpreadCents = pitchSpreadCents
        self.voicedSeconds = voicedSeconds
        self.f2 = f2
        self.h1MinusH2 = h1MinusH2
        self.backgroundDb = backgroundDb
        self.voiceDb = voiceDb
    }

    var hasVoice: Bool { voicedSeconds > 0 && medianPitch != nil }
}

/// Raw against enhanced, for the same 5-second take.
nonisolated struct MicABComparison: Sendable, Equatable {
    var strength: ClearMicStrength
    var raw: MicTakeReadings
    var enhanced: MicTakeReadings

    /// Enhanced pitch relative to raw (cents).
    var pitchDifferenceCents: Double? {
        guard let rawPitch = raw.medianPitch, let enhancedPitch = enhanced.medianPitch,
              rawPitch > 0, enhancedPitch > 0
        else { return nil }
        return 1_200 * log2(enhancedPitch / rawPitch)
    }

    /// How much quieter the gaps between words became (dB, positive = quieter).
    var backgroundReductionDb: Double? {
        guard let rawBackground = raw.backgroundDb, let enhancedBackground = enhanced.backgroundDb else { return nil }
        return rawBackground - enhancedBackground
    }

    /// A one-line verdict for the test.
    var summary: String {
        guard raw.hasVoice else {
            return "No clear voice was heard. Try again and speak or hum for the whole 5 seconds."
        }
        let reduction = backgroundReductionDb.map { max(0, $0).roundedInt } ?? 0
        guard let difference = pitchDifferenceCents else {
            return "The background dropped by \(reduction) dB, but the enhanced version lost the voice. Try Light, or a quieter spot."
        }
        if abs(difference) <= 10 {
            return "Pitch matches (within \(abs(difference).roundedInt) cents) and the background dropped by \(reduction) dB."
        }
        return "Pitch differs by \(abs(difference).roundedInt) cents, more than expected. Try again in a steadier voice, or use Light."
    }
}

nonisolated enum ClearMicComparison {
    /// Level blocks for the background/voice estimate (seconds).
    static let blockDuration = 0.02
    /// The quietest share of blocks is the background…
    static let backgroundPercentile = 0.15
    /// …and the loudest share is the voice.
    static let voicePercentile = 0.9

    /// Runs the live analysis over a clip.
    /// - Parameter isHighPassed: The clip went through Clear Mic's high-pass
    ///   filter, so weight readings are compensated for it (as live).
    static func readings(of clip: AudioClip, isHighPassed: Bool) -> MicTakeReadings {
        guard clip.sampleRate >= 8_000, !clip.samples.isEmpty else { return MicTakeReadings() }
        let configuration = AnalysisConfiguration(sampleRate: clip.sampleRate)
        let pipeline = VoiceAnalysisPipeline(
            configuration: configuration,
            inputHighPass: isHighPassed ? HighPassDesign(sampleRate: clip.sampleRate) : nil
        )
        var analyzer = TakeAnalyzer(target: .feminine, frameInterval: configuration.hopDuration)
        let chunk = 4_096
        var position = 0
        while position < clip.samples.count {
            let next = min(clip.samples.count, position + chunk)
            for frame in pipeline.process(Array(clip.samples[position..<next])) {
                analyzer.add(frame)
            }
            position = next
        }
        let take = analyzer.result()
        let spread = PitchTakeMeasure(take: take, sampleRate: clip.sampleRate).pitchSpreadCents
        let levels = levels(clip.samples, sampleRate: clip.sampleRate)
        return MicTakeReadings(
            medianPitch: take.medianPitch,
            pitchSpreadCents: spread,
            voicedSeconds: take.voicedDuration,
            f2: take.f2,
            h1MinusH2: take.h1MinusH2,
            backgroundDb: levels.background,
            voiceDb: levels.voice
        )
    }

    /// Background and voice levels (dBFS) from 20 ms blocks.
    static func levels(_ samples: [Float], sampleRate: Double) -> (background: Double?, voice: Double?) {
        let block = max(1, Int(sampleRate * blockDuration))
        guard samples.count >= block else { return (nil, nil) }
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / block)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start + block <= buffer.count {
                var meanSquare: Float = 0
                vDSP_measqv(base + start, 1, &meanSquare, vDSP_Length(block))
                levels.append(SignalLevel.decibels(fromAmplitude: Double(meanSquare).squareRoot()))
                start += block
            }
        }
        let sorted = levels.sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return sorted[index]
        }
        return (percentile(backgroundPercentile), percentile(voicePercentile))
    }

    /// Enhances a raw take the way Clear Mic would and measures both versions.
    /// - Parameter knownProfile: The room's live noise profile, if it fits.
    static func compare(raw: AudioClip, strength: ClearMicStrength, knownProfile: ClearMicNoiseProfile?) -> MicABResult {
        let used: ClearMicStrength = strength == .strong ? .strong : .light
        let enhanced = ClearMicOffline.enhance(raw, strength: used, knownProfile: knownProfile)
        let comparison = MicABComparison(
            strength: used,
            raw: readings(of: raw, isHighPassed: false),
            enhanced: readings(of: enhanced, isHighPassed: true)
        )
        return MicABResult(comparison: comparison, enhanced: enhanced)
    }
}

/// The A/B test's numbers plus the enhanced audio to play.
nonisolated struct MicABResult: Sendable {
    let comparison: MicABComparison
    let enhanced: AudioClip
}
