import Foundation
import SwiftData

/// Small deterministic random number generator (SplitMix64), so sample data
/// looks the same every time.
nonisolated struct SampleRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Normally distributed value (Box–Muller).
    mutating func gaussian(mean: Double, deviation: Double) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return mean + deviation * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// One fake session's values (plain data, so the plan can be tested).
nonisolated struct SampleSessionPlan: Sendable, Equatable {
    let date: Date
    let durationMinutes: Double
    let averagePitch: Double
    let minimumPitch: Double
    let maximumPitch: Double
    let percentInTarget: Double
    let resonance: Double
    let brightResonance: Double
    let weight: Double
    let intonation: Double
    let jitter: Double
    let shimmer: Double
    let harmonicsToNoise: Double
    let slipAlerts: Int
    let comfort: ComfortRating?
    let naturalness: Int?
}

/// Builds a believable practice history for trying out the Progress charts
/// ("More › Debug & Tuning › Generate sample history"): about 90 days of
/// sessions that slowly improve, check-ins, scenario results, and a "then"
/// and "now" recording with synthetic audio.
nonisolated enum SampleDataPlanner {
    /// Sessions for the `days` days up to `now`, oldest first.
    static func sessions(days: Int, now: Date, calendar: Calendar, seed: UInt64 = 42) -> [SampleSessionPlan] {
        var random = SampleRandom(seed: seed)
        var plans: [SampleSessionPlan] = []
        let today = calendar.startOfDay(for: now)

        for dayOffset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            // Practice on about 70% of days, with the odd rest day.
            guard Double.random(in: 0..<1, using: &random) < 0.7 else { continue }
            let sessionsToday = Double.random(in: 0..<1, using: &random) < 0.25 ? 2 : 1
            // 0 at the start of the history, 1 today.
            let progress = days > 1 ? Double(days - 1 - dayOffset) / Double(days - 1) : 1

            for index in 0..<sessionsToday {
                let hour = index == 0 ? Double.random(in: 7..<12, using: &random) : Double.random(in: 17..<21, using: &random)
                guard let date = calendar.date(byAdding: .second, value: Int(hour * 3_600), to: day), date <= now else { continue }

                let pitch = random.gaussian(mean: 135 + 60 * progress, deviation: 7)
                let inTarget = clamp(random.gaussian(mean: 5 + 70 * progress, deviation: 8))
                let resonance = clamp(random.gaussian(mean: 25 + 47 * progress, deviation: 7))
                let weight = clamp(random.gaussian(mean: 30 + 38 * progress, deviation: 7))
                let intonation = clamp(random.gaussian(mean: 30 + 32 * progress, deviation: 9))
                let roll = Double.random(in: 0..<1, using: &random)
                let comfort: ComfortRating? = roll < 0.12 ? nil : (roll < 0.8 ? .fine : (roll < 0.95 ? .tired : .sore))

                plans.append(SampleSessionPlan(
                    date: date,
                    durationMinutes: max(3, random.gaussian(mean: 11, deviation: 5)),
                    averagePitch: pitch,
                    minimumPitch: pitch - Double.random(in: 25..<45, using: &random),
                    maximumPitch: pitch + Double.random(in: 35..<70, using: &random),
                    percentInTarget: inTarget,
                    resonance: resonance,
                    brightResonance: clamp(resonance * 0.8 + random.gaussian(mean: 0, deviation: 5)),
                    weight: weight,
                    intonation: intonation,
                    jitter: max(0.2, random.gaussian(mean: 0.8, deviation: 0.2)),
                    shimmer: max(1, random.gaussian(mean: 4, deviation: 0.8)),
                    harmonicsToNoise: random.gaussian(mean: 17, deviation: 2),
                    slipAlerts: Int.random(in: 0...6, using: &random),
                    comfort: comfort,
                    naturalness: comfort == nil ? nil : min(5, max(1, Int((2 + 2.5 * progress + random.gaussian(mean: 0, deviation: 0.7)).rounded())))
                ))
            }
        }
        return plans
    }

    /// Scenario results with per-turn scores that improve over time.
    static func scenarioScores(count: Int, seed: UInt64 = 7) -> [[ScenarioTurnScore]] {
        var random = SampleRandom(seed: seed)
        return (0..<count).map { index in
            let progress = count > 1 ? Double(index) / Double(count - 1) : 1
            return (0..<Int.random(in: 4...6, using: &random)).map { _ in
                ScenarioTurnScore(
                    pitch: clamp(random.gaussian(mean: 40 + 35 * progress, deviation: 10)),
                    resonance: clamp(random.gaussian(mean: 35 + 35 * progress, deviation: 10)),
                    weight: clamp(random.gaussian(mean: 35 + 30 * progress, deviation: 10)),
                    intonation: clamp(random.gaussian(mean: 40 + 25 * progress, deviation: 10)),
                    consistency: clamp(random.gaussian(mean: 30 + 40 * progress, deviation: 10)),
                    text: nil
                )
            }
        }
    }

    /// A few seconds of a synthetic voice-like sound (harmonics shaped by
    /// vowel formants, with a gentle melody), for playing "Then vs Now".
    static func syntheticVoice(fundamental: Double, formants: [Double], seconds: Double = 5, sampleRate: Double = 48_000) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let harmonicCount = max(1, Int(4_000 / fundamental))
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            // A slow rise-fall melody and a little vibrato.
            let melody = 1 + 0.06 * sin(2 * .pi * time / seconds * 2) + 0.01 * sin(2 * .pi * 5.5 * time)
            phase += 2 * .pi * fundamental * melody / sampleRate
            var value = 0.0
            for harmonic in 1...harmonicCount {
                let frequency = Double(harmonic) * fundamental
                var gain = 1 / Double(harmonic)
                for formant in formants {
                    let distance = (frequency - formant) / 150
                    gain *= 1 + 3 * exp(-distance * distance)
                }
                value += gain * sin(Double(harmonic) * phase)
            }
            // Short pauses every 1.6 s, like phrases.
            let phraseTime = time.truncatingRemainder(dividingBy: 1.6)
            let envelope = phraseTime < 1.3 ? min(1, phraseTime / 0.05, (1.3 - phraseTime) / 0.05) : 0
            samples[index] = Float(0.05 * value * envelope)
        }
        return samples
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

/// Inserts and removes the sample history. Everything it creates is
/// remembered by id so "Remove sample history" deletes only that.
@MainActor
enum SampleDataGenerator {
    private static let sessionKey = "sampleData.sessionIDs"
    private static let scenarioKey = "sampleData.scenarioIDs"

    static var hasSampleData: Bool {
        !(UserDefaults.standard.stringArray(forKey: sessionKey) ?? []).isEmpty
    }

    static func generate(in context: ModelContext, days: Int = 90, now: Date = Date()) async throws -> Int {
        try remove(from: context)
        let calendar = Calendar.current
        let plans = SampleDataPlanner.sessions(days: days, now: now, calendar: calendar)
        var sessionIDs: [String] = []
        var stored: [PracticeSession] = []

        for plan in plans {
            let session = PracticeSession(startDate: plan.date, kind: .freePractice)
            context.insert(session)
            session.endDate = plan.date.addingTimeInterval(plan.durationMinutes * 60)
            session.duration = plan.durationMinutes * 60
            session.voicedDuration = plan.durationMinutes * 60 * 0.45
            session.averagePitch = plan.averagePitch
            session.minimumPitch = plan.minimumPitch
            session.maximumPitch = plan.maximumPitch
            session.percentInTarget = plan.percentInTarget
            session.resonanceScore = plan.resonance
            session.brightResonancePercent = plan.brightResonance
            session.weightScore = plan.weight
            session.intonationScore = plan.intonation
            session.jitterPercent = plan.jitter
            session.shimmerPercent = plan.shimmer
            session.harmonicsToNoiseDb = plan.harmonicsToNoise
            session.slipAlertCount = plan.slipAlerts
            session.comfort = plan.comfort
            session.naturalnessRating = plan.naturalness
            session.checkInDate = plan.comfort == nil ? nil : session.endDate
            sessionIDs.append(session.id.uuidString)
            stored.append(session)
        }

        // Scenario results spread over the history.
        let scenarioIDs = ["coffee-order", "phone-call", "introduction", "shop-help", "complaint", "presentation"]
        let scores = SampleDataPlanner.scenarioScores(count: 14)
        var scenarioResultIDs: [String] = []
        for (index, turns) in scores.enumerated() {
            let offset = Double(days) * (1 - Double(index + 1) / Double(scores.count + 1))
            let result = ScenarioResult(
                scenarioID: scenarioIDs[index % scenarioIDs.count],
                difficulty: index < 5 ? .easy : (index < 10 ? .medium : .hard)
            )
            context.insert(result)
            result.date = now.addingTimeInterval(-offset * 86_400)
            result.turnScores = turns
            let averages = turns.compactMap(\.pitch)
            result.overallScore = averages.isEmpty ? nil : averages.reduce(0, +) / Double(averages.count)
            result.transcript = "(sample data)"
            scenarioResultIDs.append(result.id.uuidString)
        }

        // "Then" and "Now" recordings with synthetic audio.
        if let first = stored.first, let last = stored.last, first !== last {
            try await addRecording(to: first, kind: .baseline, fundamental: 128, formants: [700, 1_200, 2_450], in: context)
            try await addRecording(to: last, kind: .clip, fundamental: 195, formants: [800, 1_450, 2_850], in: context)
        }

        try context.save()
        UserDefaults.standard.set(sessionIDs, forKey: sessionKey)
        UserDefaults.standard.set(scenarioResultIDs, forKey: scenarioKey)
        return stored.count
    }

    private static func addRecording(
        to session: PracticeSession,
        kind: RecordingKind,
        fundamental: Double,
        formants: [Double],
        in context: ModelContext
    ) async throws {
        let id = UUID()
        let fileName = RecordingFileStore.makeFileName(id: id)
        let samples = await Task.detached(priority: .userInitiated) {
            SampleDataPlanner.syntheticVoice(fundamental: fundamental, formants: formants)
        }.value
        let clip = AudioClip(samples: samples, sampleRate: 48_000, startTime: 0)
        try await Task.detached(priority: .userInitiated) {
            try RecordingFileStore.write(clip, fileName: fileName)
        }.value

        let recording = Recording(id: id, fileName: fileName, duration: clip.duration, kind: kind, createdAt: session.startDate)
        context.insert(recording)
        recording.session = session
        recording.sessionID = session.id
        recording.averagePitch = session.averagePitch
        recording.percentInTarget = session.percentInTarget
        recording.resonanceScore = session.resonanceScore
        recording.weightScore = session.weightScore
        recording.intonationScore = session.intonationScore
        recording.transcript = "(sample) The rainbow of tea cups sat on the windowsill, catching the morning light."
    }

    /// Deletes only what `generate` created (and its audio files).
    static func remove(from context: ModelContext) throws {
        let sessionIDs = Set((UserDefaults.standard.stringArray(forKey: sessionKey) ?? []).compactMap(UUID.init(uuidString:)))
        let scenarioIDs = Set((UserDefaults.standard.stringArray(forKey: scenarioKey) ?? []).compactMap(UUID.init(uuidString:)))
        guard !sessionIDs.isEmpty || !scenarioIDs.isEmpty else { return }

        let store = SessionStore(context: context)
        for session in try context.fetch(FetchDescriptor<PracticeSession>()) where sessionIDs.contains(session.id) {
            try store.delete(session)
        }
        for result in try context.fetch(FetchDescriptor<ScenarioResult>()) where scenarioIDs.contains(result.id) {
            context.delete(result)
        }
        try context.save()
        UserDefaults.standard.removeObject(forKey: sessionKey)
        UserDefaults.standard.removeObject(forKey: scenarioKey)
    }
}
