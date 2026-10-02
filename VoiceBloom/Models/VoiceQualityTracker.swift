import Foundation

/// Typical (median) jitter, shimmer and HNR over a stretch of practice.
nonisolated struct VoiceQualitySummary: Codable, Sendable, Equatable {
    var jitterPercent: Double?
    var shimmerPercent: Double?
    var harmonicsToNoiseDb: Double?
    var sampleCount: Int

    init(jitterPercent: Double?, shimmerPercent: Double?, harmonicsToNoiseDb: Double?, sampleCount: Int) {
        self.jitterPercent = jitterPercent
        self.shimmerPercent = shimmerPercent
        self.harmonicsToNoiseDb = harmonicsToNoiseDb
        self.sampleCount = sampleCount
    }

    /// Medians of each measure (robust to the odd bad frame).
    init(measurements: [VoiceQualityMeasurement]) {
        jitterPercent = PitchMath.median(of: measurements.compactMap(\.jitterPercent))
        shimmerPercent = PitchMath.median(of: measurements.compactMap(\.shimmerPercent))
        harmonicsToNoiseDb = PitchMath.median(of: measurements.compactMap(\.harmonicsToNoiseDb))
        sampleCount = measurements.count
    }
}

/// The user's usual ("normal") voice quality, learned from the first minutes
/// of past sessions, when the voice is fresh.
nonisolated struct VoiceQualityNorms: Codable, Sendable, Equatable {
    var jitterPercent: Double
    var shimmerPercent: Double
    var harmonicsToNoiseDb: Double
    /// Number of sessions blended in.
    var sessionCount: Int

    init(jitterPercent: Double, shimmerPercent: Double, harmonicsToNoiseDb: Double, sessionCount: Int) {
        self.jitterPercent = jitterPercent
        self.shimmerPercent = shimmerPercent
        self.harmonicsToNoiseDb = harmonicsToNoiseDb
        self.sessionCount = sessionCount
    }

    /// Norms from a first session's warm-up, if it measured everything.
    init?(summary: VoiceQualitySummary) {
        guard let jitter = summary.jitterPercent,
              let shimmer = summary.shimmerPercent,
              let hnr = summary.harmonicsToNoiseDb
        else { return nil }
        self.init(jitterPercent: jitter, shimmerPercent: shimmer, harmonicsToNoiseDb: hnr, sessionCount: 1)
    }

    /// Blends another session's warm-up in slowly (exponential moving average),
    /// so one unusual day can't redefine "normal".
    func blended(with summary: VoiceQualitySummary, weight: Double = 0.3) -> VoiceQualityNorms {
        func blend(_ old: Double, _ new: Double?) -> Double {
            guard let new else { return old }
            return old + weight * (new - old)
        }
        return VoiceQualityNorms(
            jitterPercent: blend(jitterPercent, summary.jitterPercent),
            shimmerPercent: blend(shimmerPercent, summary.shimmerPercent),
            harmonicsToNoiseDb: blend(harmonicsToNoiseDb, summary.harmonicsToNoiseDb),
            sessionCount: sessionCount + 1
        )
    }

    var summary: VoiceQualitySummary {
        VoiceQualitySummary(
            jitterPercent: jitterPercent,
            shimmerPercent: shimmerPercent,
            harmonicsToNoiseDb: harmonicsToNoiseDb,
            sampleCount: 0
        )
    }
}

/// How the last stretch of practice compares with the user's normal.
nonisolated struct StrainAssessment: Sendable, Equatable {
    /// Medians over the recent window.
    let recent: VoiceQualitySummary
    /// What "normal" is for this user.
    let reference: VoiceQualitySummary
    /// True when the reference comes from past sessions (not this session's start).
    let usesStoredNorms: Bool
    /// 1.0 = as usual; 1.3 = about 30% rougher than usual.
    let roughnessRatio: Double
    /// Rough enough to count as "clearly increased".
    let isElevated: Bool
}

nonisolated struct VoiceQualityTrackerConfiguration: Sendable, Equatable {
    /// Measurements at the start of a session that define its warm-up values.
    var warmupSamples = 200
    /// Seconds of recent measurements compared with normal.
    var windowDuration = 20.0
    /// Fewer recent measurements than this are too few to judge.
    var minimumWindowSamples = 100
    /// "Clearly increased" (the spec's 30%+ above normal).
    var elevatedRatio = 1.3
    /// Must drop back below this before another warning can be given.
    var recoveredRatio = 1.15
    /// Roughness must stay elevated this long (seconds) before warning.
    var sustainDuration = 10.0
    /// Minimum seconds between warnings.
    var warningCooldown = 600.0
    /// Stored norms are trusted once they cover this many sessions.
    var minimumNormSessions = 2
}

/// Collects voice-quality measurements during a session and decides when the
/// voice sounds clearly rougher than usual.
///
/// "Normal" is the user's stored norms once they span a couple of sessions;
/// before that, it's the start of the current session. Roughness compares
/// recent medians with normal: jitter and shimmer as ratios, and HNR as the
/// matching change in noise amplitude (a 2.3 dB HNR drop ≈ 30% more noise).
nonisolated struct VoiceQualityTracker: Sendable {
    let configuration: VoiceQualityTrackerConfiguration
    /// Norms as they were when the session began.
    let storedNorms: VoiceQualityNorms?

    private(set) var warmupSummary: VoiceQualitySummary?
    private var warmup: [VoiceQualityMeasurement] = []
    private var windowTimes: [Double] = []
    private var windowMeasurements: [VoiceQualityMeasurement] = []
    private(set) var sessionJitter = ScoreAverage()
    private(set) var sessionShimmer = ScoreAverage()
    private(set) var sessionHarmonicsToNoise = ScoreAverage()
    private var elevatedSince: Double?
    private var lastWarningTime: Double?
    private var isArmed = true

    init(storedNorms: VoiceQualityNorms?, configuration: VoiceQualityTrackerConfiguration = VoiceQualityTrackerConfiguration()) {
        self.storedNorms = storedNorms
        self.configuration = configuration
    }

    /// Adds a measurement.
    /// - Returns: The warm-up summary on the measurement that completes it
    ///   (once per session), so it can be blended into the stored norms.
    mutating func add(_ measurement: VoiceQualityMeasurement, at time: Double) -> VoiceQualitySummary? {
        windowTimes.append(time)
        windowMeasurements.append(measurement)
        let cutoff = time - configuration.windowDuration
        if let firstKept = windowTimes.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            windowTimes.removeFirst(firstKept)
            windowMeasurements.removeFirst(firstKept)
        }

        if let jitter = measurement.jitterPercent { sessionJitter.add(jitter) }
        if let shimmer = measurement.shimmerPercent { sessionShimmer.add(shimmer) }
        if let hnr = measurement.harmonicsToNoiseDb { sessionHarmonicsToNoise.add(hnr) }

        guard warmupSummary == nil else { return nil }
        warmup.append(measurement)
        guard warmup.count >= configuration.warmupSamples else { return nil }
        let summary = VoiceQualitySummary(measurements: warmup)
        warmupSummary = summary
        warmup.removeAll()
        return summary
    }

    /// What this session is compared against, if known yet.
    var reference: (summary: VoiceQualitySummary, usesStoredNorms: Bool)? {
        if let storedNorms, storedNorms.sessionCount >= configuration.minimumNormSessions {
            return (storedNorms.summary, true)
        }
        if let warmupSummary {
            return (warmupSummary, false)
        }
        return nil
    }

    /// True until enough of this session has been heard to judge it.
    var isLearning: Bool { reference == nil }

    /// Medians of the recent window.
    var recentSummary: VoiceQualitySummary {
        VoiceQualitySummary(measurements: windowMeasurements)
    }

    /// Session averages for display.
    var sessionSummary: VoiceQualitySummary {
        VoiceQualitySummary(
            jitterPercent: sessionJitter.mean,
            shimmerPercent: sessionShimmer.mean,
            harmonicsToNoiseDb: sessionHarmonicsToNoise.mean,
            sampleCount: max(sessionJitter.count, sessionHarmonicsToNoise.count)
        )
    }

    /// Re-checks roughness.
    /// - Parameter now: Current audio time (seconds).
    /// - Returns: The assessment (nil while learning or with too little data)
    ///   and whether to show the "take a break" warning now.
    mutating func evaluate(now: Double) -> (assessment: StrainAssessment?, shouldWarn: Bool) {
        // Measurements older than the window don't count, even if no new ones arrived.
        let cutoff = now - configuration.windowDuration
        if let firstKept = windowTimes.firstIndex(where: { $0 >= cutoff }) {
            if firstKept > 0 {
                windowTimes.removeFirst(firstKept)
                windowMeasurements.removeFirst(firstKept)
            }
        } else {
            windowTimes.removeAll()
            windowMeasurements.removeAll()
        }

        let recent = recentSummary
        guard let reference,
              recent.sampleCount >= configuration.minimumWindowSamples,
              let ratio = VoiceQualityTracker.roughnessRatio(recent: recent, reference: reference.summary)
        else {
            elevatedSince = nil
            return (nil, false)
        }

        let isElevated = ratio >= configuration.elevatedRatio
        if ratio < configuration.recoveredRatio {
            isArmed = true
        }
        if isElevated {
            elevatedSince = elevatedSince ?? now
        } else {
            elevatedSince = nil
        }

        var shouldWarn = false
        if isElevated, isArmed, let since = elevatedSince, now - since >= configuration.sustainDuration {
            let cooledDown = lastWarningTime.map { now - $0 >= configuration.warningCooldown } ?? true
            if cooledDown {
                shouldWarn = true
                isArmed = false
                lastWarningTime = now
            }
        }

        let assessment = StrainAssessment(
            recent: recent,
            reference: reference.summary,
            usesStoredNorms: reference.usesStoredNorms,
            roughnessRatio: ratio,
            isElevated: isElevated
        )
        return (assessment, shouldWarn)
    }

    /// Average of the per-measure roughness ratios (1.0 = as usual).
    static func roughnessRatio(recent: VoiceQualitySummary, reference: VoiceQualitySummary) -> Double? {
        var parts: [Double] = []
        if let jitter = recent.jitterPercent, let normal = reference.jitterPercent, normal > 0 {
            parts.append(jitter / normal)
        }
        if let shimmer = recent.shimmerPercent, let normal = reference.shimmerPercent, normal > 0 {
            parts.append(shimmer / normal)
        }
        if let hnr = recent.harmonicsToNoiseDb, let normal = reference.harmonicsToNoiseDb {
            // Lower HNR = more noise. Convert the dB drop to a noise-amplitude ratio.
            parts.append(pow(10, (normal - hnr) / 20))
        }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +) / Double(parts.count)
    }
}

/// What the practice screen shows about voice quality.
nonisolated struct VoiceQualityStatus: Sendable, Equatable {
    /// Session averages.
    var session: VoiceQualitySummary
    /// Comparison with normal (nil while learning or with too little recent data).
    var assessment: StrainAssessment?
    /// True until this session (or past ones) define what "normal" is.
    var isLearning: Bool
    /// Most recent single measurement (debug screen).
    var latest: VoiceQualityMeasurement?
}

/// A "your voice sounds tired" warning that is showing.
nonisolated struct StrainWarning: Sendable, Equatable {
    let roughnessRatio: Double
    let date: Date
}

/// Keeps the learned voice-quality norms on this device. They stay in
/// UserDefaults rather than the SwiftData profile because they depend on this
/// iPhone's microphone.
@MainActor
enum VoiceQualityNormsStore {
    private static let key = "voiceQualityNorms.v1"

    static func load(from defaults: UserDefaults = .standard) -> VoiceQualityNorms? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VoiceQualityNorms.self, from: data)
    }

    static func save(_ norms: VoiceQualityNorms?, to defaults: UserDefaults = .standard) {
        guard let norms else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(norms) {
            defaults.set(data, forKey: key)
        }
    }
}
