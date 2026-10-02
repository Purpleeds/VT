import Foundation
import Observation
import SwiftData

/// The scenario scripts, loaded once.
@MainActor
enum ScenarioLibrary {
    static let result: Result<ScenarioCatalog, Error> = Result { try ScenarioCatalog.load() }

    static var catalog: ScenarioCatalog? {
        try? result.get()
    }

    static var loadError: String? {
        if case .failure(let error) = result {
            return error.localizedDescription
        }
        return nil
    }
}

/// Runs one scenario practice: the other person's line, your turn
/// (recorded and scored), and a summary at the end (SPEC section 7).
@MainActor
@Observable
final class ScenarioSessionModel: Identifiable {
    nonisolated enum Stage: Equatable, Sendable {
        /// The other person's line is showing (and may be read aloud).
        case partner
        /// Waiting for you to start your turn.
        case ready
        case recording
        /// The turn's scores are showing.
        case scored
        case summary
    }

    let id = UUID()
    let scenario: Scenario
    let difficulty: ScenarioDifficulty
    let level: ScenarioLevel
    let recorder: VoiceTakeRecorder
    let partnerVoice = PartnerVoice()
    let target: PitchTargetZone
    let references: PersonalReferences

    private(set) var index = 0
    private(set) var stage: Stage = .partner
    /// Scores by turn index (a retry replaces the turn's score).
    private(set) var scores: [Int: ScenarioTurnScore] = [:]
    /// False when the last attempt heard no voice.
    private(set) var lastTurnHadVoice = true
    private(set) var errorMessage: String?
    private(set) var isSaved = false
    var speaksPartner: Bool

    init(
        scenario: Scenario,
        difficulty: ScenarioDifficulty,
        level: ScenarioLevel,
        monitor: LiveVoiceMonitor,
        target: PitchTargetZone,
        references: PersonalReferences,
        speaksPartner: Bool
    ) {
        self.scenario = scenario
        self.difficulty = difficulty
        self.level = level
        self.target = target
        self.references = references
        self.speaksPartner = speaksPartner
        recorder = VoiceTakeRecorder(monitor: monitor)
    }

    var turn: ScenarioTurn? {
        level.turns.indices.contains(index) ? level.turns[index] : nil
    }

    var isLastTurn: Bool { index >= level.turns.count - 1 }

    var progress: Double {
        guard !level.turns.isEmpty else { return 0 }
        return stage == .summary ? 1 : Double(index) / Double(level.turns.count)
    }

    var currentScore: ScenarioTurnScore? { scores[index] }

    /// Scored turns in order.
    var completedTurns: [ScenarioTurnScore] {
        scores.keys.sorted().compactMap { scores[$0] }
    }

    var summary: ScenarioSummary { ScenarioScoring.summary(completedTurns) }

    // MARK: Flow

    /// Shows the current turn and reads the other person's line aloud.
    func presentTurn() async {
        guard let turn else { return }
        stage = .partner
        errorMessage = nil
        if speaksPartner, let line = turn.partner {
            let text = ScenarioScript.spokenText(line)
            if !text.isEmpty {
                await partnerVoice.speak(text, monitor: recorder.monitor)
            }
        }
        if stage == .partner {
            stage = .ready
        }
    }

    /// Stops reading aloud and goes straight to your turn.
    func skipPartner() {
        partnerVoice.stop()
        if stage == .partner {
            stage = .ready
        }
    }

    func replayPartner() async {
        guard stage == .ready || stage == .scored, let line = turn?.partner else { return }
        await partnerVoice.speak(ScenarioScript.spokenText(line), monitor: recorder.monitor)
    }

    /// Records and scores your turn.
    func startTurn() async {
        guard let turn, stage != .recording, stage != .summary else { return }
        partnerVoice.stop()
        errorMessage = nil
        stage = .recording
        let turnIndex = index
        await recorder.start(
            duration: Double(turn.seconds),
            target: target,
            references: references,
            countsTowardSession: true
        )
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard index == turnIndex, stage == .recording else { return }

        if let result = recorder.result {
            lastTurnHadVoice = result.hasVoice
            if result.hasVoice {
                scores[turnIndex] = ScenarioScoring.turnScore(result, target: target, text: turn.suggestion ?? turn.prompt)
            }
        } else if case .failed(let message) = recorder.phase {
            errorMessage = message
            lastTurnHadVoice = true
        }
        recorder.reset()
        stage = .scored
    }

    /// The next turn, or the summary after the last one.
    func next() async {
        partnerVoice.stop()
        if isLastTurn {
            stage = .summary
            return
        }
        index += 1
        lastTurnHadVoice = true
        await presentTurn()
    }

    /// Ends early and shows the summary of the turns so far.
    func endEarly() {
        stopAudio()
        stage = .summary
    }

    func stopAudio() {
        partnerVoice.stop()
        recorder.cancel()
    }

    // MARK: Saving

    /// Saves the scored turns as a `ScenarioResult` (once).
    @discardableResult
    func save(context: ModelContext, now: Date = Date()) throws -> ScenarioResult? {
        guard !isSaved else { return nil }
        let turns = completedTurns
        guard !turns.isEmpty else { return nil }
        let result = try ScenarioResultStore(context: context).save(
            scenarioID: scenario.id,
            difficulty: difficulty,
            turns: turns,
            transcript: ScenarioScript.transcript(level: level, completedTurns: scores.keys.sorted()),
            now: now
        )
        isSaved = true
        return result
    }
}
