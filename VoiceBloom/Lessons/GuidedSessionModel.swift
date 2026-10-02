import Foundation
import Observation
import SwiftData

/// What's being practiced: a lesson week, a maintenance routine, or a single
/// exercise from the library.
nonisolated enum GuidedSessionSource: Sendable, Equatable {
    case lesson(week: Int)
    case maintenance(routineID: String)
    case exercise(id: String)

    var lessonID: String? {
        switch self {
        case .lesson(let week): "week-\(week)"
        case .maintenance(let routineID): "maintenance-\(routineID)"
        case .exercise: nil
        }
    }
}

/// A planned guided session, ready to present.
nonisolated struct GuidedSessionPlan: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let source: GuidedSessionSource
    let steps: [PlannedStep]
    /// The week's goal, checked after each measured exercise.
    let goal: LessonGoal?

    var totalSeconds: Int { steps.reduce(0) { $0 + $1.seconds } }
}

/// Runs a guided session (SPEC section 5): steps with timers, measured
/// exercises, pitch matching, goal checks, and saving at the end.
@MainActor
@Observable
final class GuidedSessionModel {
    nonisolated enum StepStage: Equatable, Sendable {
        /// Instructions shown; timer not started (measured steps).
        case ready
        /// Timed step counting down.
        case running
        /// A measured take is recording.
        case recording
        /// Pitch matching: playing a tone.
        case playingTone
        /// The step is done; shows feedback.
        case done
    }

    let plan: GuidedSessionPlan
    let recorder: VoiceTakeRecorder
    let tones = TonePlayer()

    private(set) var index = 0
    private(set) var stage: StepStage = .ready
    /// Seconds left in a timed step.
    private(set) var remaining = 0.0
    private(set) var isPaused = false
    /// Seconds of the session actually practiced.
    private(set) var practicedSeconds = 0.0
    /// Feedback after a measured step.
    private(set) var feedback: String?
    /// True once the week's goal was reached during this session.
    private(set) var goalMet = false
    private(set) var isFinished = false

    // Phrases: which item is showing.
    private(set) var itemIndex = 0

    // Pitch matching
    private(set) var matchTones: [Double] = []
    private(set) var matchIndex = 0
    private(set) var matchResults: [Double?] = []

    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let target: PitchTargetZone
    @ObservationIgnored private let references: PersonalReferences
    @ObservationIgnored private let baselinePitch: Double?
    @ObservationIgnored private let recentSoreReports: Int
    @ObservationIgnored private let onGoalMet: () -> Void

    init(
        plan: GuidedSessionPlan,
        monitor: LiveVoiceMonitor,
        target: PitchTargetZone,
        references: PersonalReferences,
        baselinePitch: Double?,
        recentSoreReports: Int,
        onGoalMet: @escaping () -> Void
    ) {
        self.plan = plan
        recorder = VoiceTakeRecorder(monitor: monitor)
        self.target = target
        self.references = references
        self.baselinePitch = baselinePitch
        self.recentSoreReports = recentSoreReports
        self.onGoalMet = onGoalMet
        prepareStep()
    }

    var step: PlannedStep? {
        plan.steps.indices.contains(index) ? plan.steps[index] : nil
    }

    var exercise: Exercise? { step?.exercise }

    var progress: Double {
        let total = Double(max(plan.totalSeconds, 1))
        let before = plan.steps.prefix(index).reduce(0) { $0 + Double($1.seconds) }
        let current = step.map { Double($0.seconds) - remaining } ?? 0
        return min(max((before + max(current, 0)) / total, 0), 1)
    }

    var isLastStep: Bool { index >= plan.steps.count - 1 }

    /// The phrase showing now (phrases exercises).
    var currentItem: String? {
        guard let items = exercise?.items, !items.isEmpty else { return nil }
        return items[min(itemIndex, items.count - 1)]
    }

    // MARK: Controls

    /// Starts the current step (timer, take or pitch matching).
    func startStep() {
        guard let step, !isFinished else { return }
        feedback = nil
        switch step.exercise.kind {
        case .timed, .glide, .scenario:
            stage = .running
            startTimer()
        case .hold, .reading, .phrases:
            Task { await recordTake(for: step) }
        case .pitchMatch:
            Task { await playNextTone() }
        }
    }

    func togglePause() {
        isPaused.toggle()
    }

    func next() {
        stopActivity()
        guard !isLastStep else {
            finish()
            return
        }
        index += 1
        prepareStep()
    }

    func previous() {
        stopActivity()
        guard index > 0 else { return }
        index -= 1
        prepareStep()
    }

    /// Ends the session early (or at the end).
    func finish() {
        stopActivity()
        tones.stop()
        isFinished = true
    }

    /// True when enough of the session was done to count toward the week.
    var countsAsCompleted: Bool {
        practicedSeconds >= Double(plan.totalSeconds) * 0.5 || index >= plan.steps.count - 1
    }

    // MARK: Steps

    private func prepareStep() {
        guard let step else { return }
        remaining = Double(step.seconds)
        itemIndex = 0
        feedback = nil
        stage = .ready
        if step.exercise.kind == .pitchMatch {
            matchTones = SessionPlanner.tones(
                mode: step.exercise.toneMode ?? .comfortable,
                count: step.exercise.toneCount ?? 5,
                baseline: baselinePitch,
                target: target
            )
            matchIndex = 0
            matchResults = []
        }
        // Timed steps start on their own; measured ones wait for "Start".
        if !step.exercise.kind.isMeasured {
            stage = .running
            startTimer()
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let now = Date()
                let delta = now.timeIntervalSince(last)
                last = now
                guard !self.isPaused, self.stage == .running else { continue }
                self.remaining = max(0, self.remaining - delta)
                self.practicedSeconds += delta
                if self.remaining <= 0 {
                    self.stage = .done
                    // Move on by itself after a short beat.
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled, self.stage == .done {
                        self.next()
                    }
                    return
                }
            }
        }
    }

    private func stopActivity() {
        timerTask?.cancel()
        timerTask = nil
        if recorder.isRecording {
            recorder.cancel()
        }
        tones.stopDrone()
    }

    // MARK: Measured takes

    private func recordTake(for step: PlannedStep) async {
        let stepIndex = index
        stage = .recording
        let exercise = step.exercise
        let duration = exercise.kind == .hold ? Double(min(exercise.durationSeconds, step.seconds)) : Double(step.seconds)
        let itemTask = exercise.kind == .phrases ? cycleItems(duration: duration) : nil
        await recorder.start(
            duration: duration,
            target: target,
            resonanceMode: exercise.resonanceMode,
            references: references,
            countsTowardSession: true
        )
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        itemTask?.cancel()
        // The user skipped to another step while recording.
        guard index == stepIndex, !isFinished else { return }
        practicedSeconds += recorder.elapsed
        if case .failed(let message) = recorder.phase {
            feedback = message
            recorder.reset()
            stage = .ready
            return
        }
        guard recorder.phase == .finished else {
            stage = .ready
            return
        }
        let outcome = ExerciseOutcome(kind: exercise.kind, take: recorder.result)
        complete(with: outcome)
        recorder.reset()
    }

    /// Shows each phrase for an equal share of the take.
    private func cycleItems(duration: Double) -> Task<Void, Never>? {
        guard let items = exercise?.items, items.count > 1 else { return nil }
        let perItem = max(duration / Double(items.count), 2)
        return Task { [weak self] in
            for index in items.indices {
                guard !Task.isCancelled else { return }
                self?.itemIndex = index
                try? await Task.sleep(for: .seconds(perItem))
            }
        }
    }

    // MARK: Pitch matching

    /// Plays the next tone, then records 3 seconds of the user matching it.
    private func playNextTone() async {
        guard matchIndex < matchTones.count else { return }
        let stepIndex = index
        let toneFrequency = matchTones[matchIndex]
        stage = .playingTone
        // Keep the tone itself out of the session statistics.
        recorder.monitor.excludeFromStatistics(for: 2.2)
        guard tones.playNote(toneFrequency, duration: 1.6, timbre: .warm) else {
            // No tone (Discreet Mode without headphones): wait for the user.
            stage = .ready
            return
        }
        try? await Task.sleep(for: .milliseconds(1_900))
        guard stage == .playingTone, index == stepIndex else { return }

        stage = .recording
        await recorder.start(duration: 3, target: target, references: references, countsTowardSession: true)
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard index == stepIndex, !isFinished else { return }
        practicedSeconds += 5
        let sung = recorder.result?.medianPitch
        recorder.reset()
        matchResults.append(sung)
        matchIndex += 1

        if matchIndex >= matchTones.count {
            let matches = zip(matchResults, matchTones).filter { PlacementScoring.isMatch(sung: $0, target: $1) }.count
            complete(with: ExerciseOutcome(kind: .pitchMatch, pitchMatches: matches, pitchAttempts: matchTones.count))
        } else {
            stage = .ready
        }
    }

    func isMatch(at index: Int) -> Bool {
        guard matchResults.indices.contains(index), matchTones.indices.contains(index) else { return false }
        return PlacementScoring.isMatch(sung: matchResults[index], target: matchTones[index])
    }

    // MARK: Results

    private func complete(with outcome: ExerciseOutcome) {
        var message = LessonGoalEvaluator.summary(of: outcome, target: target)
        if let goal = plan.goal, !goalMet,
           LessonGoalEvaluator.isMet(goal, by: outcome, baselinePitch: baselinePitch, recentSoreReports: recentSoreReports) {
            goalMet = true
            onGoalMet()
            message += "\nGoal reached: \(goal.description)"
        }
        feedback = message
        stage = .done
    }
}
