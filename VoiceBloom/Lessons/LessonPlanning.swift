import Foundation

/// The four parts of every guided session (SPEC section 5).
nonisolated enum SessionPhase: String, CaseIterable, Identifiable, Sendable {
    case warmUp
    case main
    case carryover
    case coolDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warmUp: "Warm-up"
        case .main: "Main practice"
        case .carryover: "Real-speech carryover"
        case .coolDown: "Cool-down"
        }
    }
}

/// One exercise in a planned session, with its time.
nonisolated struct PlannedStep: Identifiable, Sendable, Equatable {
    let id: Int
    let phase: SessionPhase
    let exercise: Exercise
    let seconds: Int
}

/// Builds a guided session from a week's exercises.
nonisolated enum SessionPlanner {
    /// Minutes per phase. Standard follows the spec template (warm-up 2–3,
    /// main 8–15, carryover 2–3, cool-down 1–2); Quick and Deep scale it.
    static func phaseSeconds(for length: SessionLength) -> [(SessionPhase, Int)] {
        switch length {
        case .quick: [(.warmUp, 60), (.main, 150), (.carryover, 60), (.coolDown, 30)]
        case .standard: [(.warmUp, 150), (.main, 510), (.carryover, 150), (.coolDown, 90)]
        case .deep: [(.warmUp, 180), (.main, 900), (.carryover, 240), (.coolDown, 180)]
        }
    }

    /// Shortest time worth giving an exercise.
    static let minimumStepSeconds = 20

    static func plan(week: LessonWeek, length: SessionLength, catalog: LessonCatalog) -> [PlannedStep] {
        plan(
            pools: [
                .warmUp: catalog.warmups,
                .main: week.exercises,
                .carryover: week.carryover,
                .coolDown: catalog.cooldowns,
            ],
            length: length
        )
    }

    /// A maintenance session: a short warm-up, the routine, a short cool-down.
    static func plan(routine: MaintenanceRoutine, catalog: LessonCatalog, minutes: Int) -> [PlannedStep] {
        let total = max(minutes, 3) * 60
        let warmUp = 60
        let coolDown = 45
        let main = max(total - warmUp - coolDown, 60)
        return fill(
            [(.warmUp, warmUp, catalog.warmups), (.main, main, routine.exercises), (.coolDown, coolDown, catalog.cooldowns)]
        )
    }

    static func plan(pools: [SessionPhase: [Exercise]], length: SessionLength) -> [PlannedStep] {
        fill(phaseSeconds(for: length).map { phase, seconds in (phase, seconds, pools[phase] ?? []) })
    }

    /// Fills each phase's time with its exercises in order (repeating them if
    /// there's time left); the last one is trimmed so the phase adds up exactly.
    private static func fill(_ phases: [(SessionPhase, Int, [Exercise])]) -> [PlannedStep] {
        var steps: [PlannedStep] = []
        for (phase, seconds, pool) in phases where seconds > 0 && !pool.isEmpty {
            var remaining = seconds
            var index = 0
            while remaining > 0 {
                let exercise = pool[index % pool.count]
                var length = min(max(exercise.durationSeconds, minimumStepSeconds), remaining)
                // Don't leave a sliver too short to do anything with.
                if remaining - length < minimumStepSeconds {
                    length = remaining
                }
                steps.append(PlannedStep(id: steps.count, phase: phase, exercise: exercise, seconds: length))
                remaining -= length
                index += 1
            }
        }
        return steps
    }

    /// A single exercise on its own (exercise library).
    static func single(_ exercise: Exercise) -> [PlannedStep] {
        [PlannedStep(id: 0, phase: .main, exercise: exercise, seconds: max(exercise.durationSeconds, minimumStepSeconds))]
    }

    // MARK: Pitch-match tones

    /// Reference tones for a pitch-match exercise.
    /// - Parameters:
    ///   - baseline: The user's usual speaking pitch (Day 1), if known.
    static func tones(mode: ToneMode, count: Int, baseline: Double?, target: PitchTargetZone) -> [Double] {
        guard count > 0 else { return [] }
        let usual = baseline ?? 130
        var values: [Double]
        switch mode {
        case .comfortable:
            // Evenly spaced (in semitones) from the usual pitch to the middle
            // of the target, then visited in an interleaved order.
            let low = min(usual, target.center)
            let high = max(usual, target.center)
            let ordered = spaced(from: low, to: high, count: count)
            values = interleaved(ordered)
        case .stepUp:
            let steps = [10.0, 15, 20]
            values = (0..<count).map { usual + steps[$0 % steps.count] }
        case .target:
            values = interleaved(spaced(from: target.lowerBound, to: target.upperBound, count: count))
        }
        return values.map { min(max($0, 80), 400) }
    }

    private static func spaced(from low: Double, to high: Double, count: Int) -> [Double] {
        guard count > 1, low > 0, high > low else { return Array(repeating: max(low, 1), count: count) }
        let span = 12 * log2(high / low)
        return (0..<count).map { low * pow(2, span * Double($0) / Double(count - 1) / 12) }
    }

    /// 0, 2, 4, …, then 1, 3, 5, … so neighboring tones aren't always adjacent.
    private static func interleaved(_ values: [Double]) -> [Double] {
        let evens = values.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let odds = values.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        return evens + odds
    }
}

/// Lesson progress as plain values (for the rules below).
nonisolated struct LessonProgressValues: Sendable, Equatable {
    var week: Int
    var sessionsCompleted = 0
    var goalMet = false
    var unlockedDate: Date?
    var completedDate: Date?
}

/// "A week unlocks when the user completes 5+ sessions in the previous week
/// AND meets its goal. Any week can be repeated." (SPEC section 6)
nonisolated enum LessonUnlockRules {
    static let requiredSessions = 5

    static func isComplete(_ progress: LessonProgressValues?) -> Bool {
        guard let progress else { return false }
        return progress.sessionsCompleted >= requiredSessions && progress.goalMet
    }

    static func isUnlocked(week: Int, progress: [Int: LessonProgressValues], unlockAll: Bool = false) -> Bool {
        if unlockAll || week <= 1 {
            return true
        }
        if progress[week]?.unlockedDate != nil {
            return true
        }
        return isComplete(progress[week - 1])
    }

    /// The week to show first: the earliest unlocked week that isn't
    /// complete, or the last unlocked week when all are complete.
    static func currentWeek(progress: [Int: LessonProgressValues], totalWeeks: Int, unlockAll: Bool = false) -> Int {
        guard totalWeeks > 0 else { return 1 }
        let unlocked = (1...totalWeeks).filter { isUnlocked(week: $0, progress: progress, unlockAll: unlockAll) }
        // With placement, earlier weeks are unlocked but may be skipped: start
        // at the highest week unlocked by placement or progress.
        let highestUnlocked = unlocked.max() ?? 1
        let firstIncomplete = unlocked.first { !isComplete(progress[$0]) && $0 >= startingWeek(progress: progress) }
        return firstIncomplete ?? highestUnlocked
    }

    /// The highest week explicitly unlocked (placement test), or 1.
    static func startingWeek(progress: [Int: LessonProgressValues]) -> Int {
        progress.values.filter { $0.unlockedDate != nil }.map(\.week).max() ?? 1
    }

    static func isMaintenanceUnlocked(progress: [Int: LessonProgressValues], totalWeeks: Int, unlockAll: Bool = false) -> Bool {
        unlockAll || isComplete(progress[totalWeeks])
    }
}

/// What a measured exercise produced.
nonisolated struct ExerciseOutcome: Sendable, Equatable {
    let kind: ExerciseKind
    var take: TakeResult?
    var pitchMatches: Int?
    var pitchAttempts: Int?
}

/// Checks a week's goal against an exercise outcome.
nonisolated enum LessonGoalEvaluator {
    /// - Parameters:
    ///   - baselinePitch: The user's Day 1 pitch (for "raise by N Hz").
    ///   - recentSoreReports: "Sore" check-ins in the last 7 days.
    static func isMet(_ goal: LessonGoal, by outcome: ExerciseOutcome, baselinePitch: Double?, recentSoreReports: Int) -> Bool {
        let threshold = goal.threshold ?? 0
        switch goal.kind {
        case .pitchMatch:
            guard outcome.kind == .pitchMatch, let matches = outcome.pitchMatches, let attempts = outcome.pitchAttempts else { return false }
            let needed = goal.count ?? attempts
            let total = goal.total ?? attempts
            return attempts >= total && matches >= needed
        case .brightHold:
            guard outcome.kind == .hold, let bright = outcome.take?.brightResonancePercent else { return false }
            return bright >= threshold
        case .brightReading:
            guard outcome.kind == .reading || outcome.kind == .phrases, let bright = outcome.take?.brightResonancePercent else { return false }
            return bright >= threshold
        case .pitchRaise:
            guard outcome.kind == .reading || outcome.kind == .phrases, let median = outcome.take?.medianPitch else { return false }
            return median >= (baselinePitch ?? 130) + threshold
        case .targetAndBright:
            guard outcome.kind == .reading || outcome.kind == .phrases,
                  let take = outcome.take,
                  let inTarget = take.percentInTarget,
                  let bright = take.brightResonancePercent
            else { return false }
            if goal.requiresNoStrain == true, recentSoreReports > 0 {
                return false
            }
            return inTarget >= threshold && bright >= (goal.secondaryThreshold ?? 0)
        case .lightWeight:
            guard outcome.kind == .reading || outcome.kind == .phrases, let light = outcome.take?.lightWeightPercent else { return false }
            return light >= threshold
        case .intonation:
            guard outcome.kind == .reading || outcome.kind == .phrases, let score = outcome.take?.intonationScore else { return false }
            return score >= threshold
        case .sessions, .scenarios, .baseline:
            // Met by counting sessions or scenarios, or by re-recording.
            return false
        }
    }

    /// Short feedback after a measured exercise.
    static func summary(of outcome: ExerciseOutcome, target: PitchTargetZone) -> String {
        if let matches = outcome.pitchMatches, let attempts = outcome.pitchAttempts {
            return "Matched \(matches) of \(attempts) tones."
        }
        guard let take = outcome.take, take.hasVoice else {
            return "No voice detected. Try again a little closer to the phone."
        }
        var parts: [String] = []
        if outcome.kind == .hold {
            if let bright = take.brightResonancePercent {
                parts.append("Bright \(bright.roundedInt)% of the time")
            }
        } else {
            if let inTarget = take.percentInTarget {
                parts.append("\(inTarget.roundedInt)% in target (\(target.formatted))")
            }
            if let bright = take.brightResonancePercent {
                parts.append("bright \(bright.roundedInt)%")
            }
            if let light = take.lightWeightPercent {
                parts.append("light \(light.roundedInt)%")
            }
            if let intonation = take.intonationScore {
                parts.append("melody \(intonation.roundedInt)")
            }
        }
        if let pitch = take.medianPitch {
            parts.append("average \(pitch.roundedInt) Hz")
        }
        return parts.joined(separator: " · ")
    }
}
