import Foundation
import SwiftData

/// A finished scenario's averages and what to work on next.
nonisolated struct ScenarioSummary: Sendable, Equatable {
    /// 0–100 per measure (the same axes as the Progress radar).
    let averages: [RadarValues.Axis: Double]
    let overall: Double?
    let strongest: RadarValues.Axis?
    let weakest: RadarValues.Axis?
    let turnCount: Int
}

/// Scores scenario turns on pitch, resonance, weight, intonation and
/// consistency (SPEC section 7).
nonisolated enum ScenarioScoring {
    /// Window used to judge whether the voice held during a turn.
    static let consistencyWindow = 1.0

    /// A turn's scores from its take.
    /// - Pitch: time in the target zone. Resonance, weight, intonation: the
    ///   same 0–100 scores as the meters. Consistency: how much of the turn
    ///   stayed up in the target voice without slipping back down.
    static func turnScore(_ take: TakeResult, target: PitchTargetZone, text: String?) -> ScenarioTurnScore {
        ScenarioTurnScore(
            pitch: take.percentInTarget,
            resonance: take.resonanceScore,
            weight: take.weightScore,
            intonation: take.intonationScore,
            consistency: consistency(take.contour, target: target),
            text: text
        )
    }

    /// Share (0–100) of one-second stretches whose median pitch stays within
    /// a semitone below the target zone or higher; nil with too little voice.
    static func consistency(_ contour: [PitchContourPoint], target: PitchTargetZone, window: Double = consistencyWindow) -> Double? {
        guard window > 0, let first = contour.first?.time else { return nil }
        var buckets: [Int: [Double]] = [:]
        for point in contour where point.frequency > 0 {
            let bucket = Int(((point.time - first) / window).rounded(.down))
            buckets[bucket, default: []].append(point.frequency)
        }
        let floor = target.lowerBound * pow(2, -1.0 / 12)
        let medians = buckets.values.filter { $0.count >= 5 }.compactMap { PitchMath.median(of: $0) }
        guard !medians.isEmpty else { return nil }
        let held = medians.filter { $0 >= floor }.count
        return Double(held) / Double(medians.count) * 100
    }

    /// The average of a turn's measured scores.
    static func overall(_ score: ScenarioTurnScore) -> Double? {
        let values = RadarValues.Axis.allCases.compactMap { $0.value(in: score) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func summary(_ turns: [ScenarioTurnScore]) -> ScenarioSummary {
        var averages: [RadarValues.Axis: Double] = [:]
        for axis in RadarValues.Axis.allCases {
            let values = turns.compactMap { axis.value(in: $0) }
            if !values.isEmpty {
                averages[axis] = min(max(values.reduce(0, +) / Double(values.count), 0), 100)
            }
        }
        let overall = averages.isEmpty ? nil : averages.values.reduce(0, +) / Double(averages.count)
        // Ties go to the earlier axis, so results are stable.
        let ordered = RadarValues.Axis.allCases.compactMap { axis in averages[axis].map { (axis, $0) } }
        let highest = ordered.max { $0.1 < $1.1 }
        let lowest = ordered.min { $0.1 < $1.1 }
        // Only name a strongest and weakest measure when they really differ.
        let differ = ordered.count > 1 && (highest?.1 ?? 0) - (lowest?.1 ?? 0) >= 1
        return ScenarioSummary(
            averages: averages,
            overall: overall,
            strongest: differ ? highest?.0 : nil,
            weakest: differ ? lowest?.0 : nil,
            turnCount: turns.count
        )
    }
}

extension RadarValues.Axis {
    /// What to try next time when this is the weakest measure.
    nonisolated var scenarioTip: String {
        switch self {
        case .pitch:
            "Your pitch drifted below your target. Before each turn, hum your target note for a second, then start speaking from it."
        case .resonance:
            "Keep the bright “ee” feeling while you talk: a slight smile, tongue forward, sound at the front of the mouth."
        case .weight:
            "Lighten up: a softer start to each phrase and a little more air, as if talking to someone close by."
        case .intonation:
            "Let your melody move: lift on questions and on the words that matter most."
        case .consistency:
            "Your voice slipped partway through some turns. Shorter phrases with a quick breath in between help it hold."
        }
    }
}

/// Saved scenario practice (`ScenarioResult`), which feeds the Progress radar.
@MainActor
struct ScenarioResultStore {
    let context: ModelContext

    @discardableResult
    func save(
        scenarioID: String,
        difficulty: ScenarioDifficulty,
        turns: [ScenarioTurnScore],
        transcript: String,
        now: Date = Date()
    ) throws -> ScenarioResult {
        let result = ScenarioResult(scenarioID: scenarioID, difficulty: difficulty)
        context.insert(result)
        result.date = now
        result.turnScores = turns
        result.transcript = transcript
        result.overallScore = ScenarioScoring.summary(turns).overall
        result.usedAIPartner = false
        try context.save()
        return result
    }

    /// Results for one scenario, newest first.
    func results(for scenarioID: String) -> [ScenarioResult] {
        let id = scenarioID
        let descriptor = FetchDescriptor<ScenarioResult>(
            predicate: #Predicate<ScenarioResult> { $0.scenarioID == id },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func delete(_ result: ScenarioResult) throws {
        context.delete(result)
        try context.save()
    }
}

/// Best scores per scenario and difficulty, for the scenario list.
nonisolated struct ScenarioBest: Sendable, Equatable {
    /// Best overall score (0–100) per difficulty.
    let scores: [ScenarioDifficulty: Double]
    let practiceCount: Int

    init(scores: [ScenarioDifficulty: Double], practiceCount: Int) {
        self.scores = scores
        self.practiceCount = practiceCount
    }

    /// Best results from (scenario, difficulty, overall) triples.
    static func table(_ results: [(scenarioID: String, difficulty: ScenarioDifficulty, overall: Double?)]) -> [String: ScenarioBest] {
        var scores: [String: [ScenarioDifficulty: Double]] = [:]
        var counts: [String: Int] = [:]
        for result in results {
            counts[result.scenarioID, default: 0] += 1
            if let overall = result.overall {
                let current = scores[result.scenarioID]?[result.difficulty] ?? -1
                if overall > current {
                    scores[result.scenarioID, default: [:]][result.difficulty] = overall
                }
            }
        }
        var table: [String: ScenarioBest] = [:]
        for (id, count) in counts {
            table[id] = ScenarioBest(scores: scores[id] ?? [:], practiceCount: count)
        }
        return table
    }
}
