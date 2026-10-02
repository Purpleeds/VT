import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

private func scenarioTake(contour: [PitchContourPoint] = []) -> TakeResult {
    TakeResult(
        duration: 8,
        voicedDuration: 5,
        averagePitch: 200,
        medianPitch: 200,
        lowPitch: 170,
        highPitch: 240,
        percentInTarget: 70,
        f1: 600,
        f2: 1_900,
        f3: 2_800,
        resonanceScore: 60,
        brightResonancePercent: 50,
        h1MinusH2: 8,
        spectralTilt: -7,
        weightScore: 50,
        lightWeightPercent: 40,
        intonationSD: 2.5,
        intonationScore: 40,
        phraseCount: 2,
        contour: contour,
        pitchHistogram: []
    )
}

/// 100 points a second: `first` seconds at 200 Hz, then `then` seconds at `low` Hz.
private func contour(first: Int, then: Int, low: Double) -> [PitchContourPoint] {
    (0..<((first + then) * 100)).map { index in
        PitchContourPoint(time: Double(index) * 0.01, frequency: index < first * 100 ? 200 : low)
    }
}

@Suite("Scenario scripts (Scenarios.json)")
struct ScenarioCatalogTests {
    @Test("All 11 scenarios load with Easy, Medium and Hard")
    func catalog() throws {
        let catalog = try ScenarioCatalog.load()
        #expect(catalog.scenarios.count == 11)
        let ids = Set(catalog.scenarios.map(\.id))
        #expect(ids.count == 11)
        for id in ["coffee-order", "phone-call", "introduction", "shop-help", "complaint", "friend-chat", "story-reading", "presentation", "emotional-reactions", "calling-across", "tired-voice"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        for scenario in catalog.scenarios {
            for difficulty in ScenarioDifficulty.allCases {
                let level = try #require(scenario.level(difficulty), "\(scenario.id) has no \(difficulty.rawValue)")
                #expect((4...6).contains(level.turns.count), "\(scenario.id) \(difficulty.rawValue)")
                #expect(level.tips.count >= 2)
                #expect(!level.setting.isEmpty)
                #expect(!level.partner.isEmpty)
                for turn in level.turns {
                    #expect(!turn.prompt.isEmpty)
                    #expect((3...40).contains(turn.seconds))
                }
            }
        }
    }

    @Test("Easy levels give a line for every turn")
    func easySuggestions() throws {
        for scenario in try ScenarioCatalog.load().scenarios {
            let easy = try #require(scenario.level(.easy))
            #expect(easy.turns.allSatisfy { $0.suggestion != nil }, "\(scenario.id)")
        }
    }

    @Test("Lengths follow the spec: a 2-minute chat and a 1–2 minute presentation")
    func lengths() throws {
        let catalog = try ScenarioCatalog.load()
        let chat = try #require(catalog.scenario("friend-chat"))
        for difficulty in ScenarioDifficulty.allCases {
            let level = try #require(chat.level(difficulty))
            let speaking = level.turns.reduce(0) { $0 + $1.seconds }
            #expect(speaking >= 90, "friend chat \(difficulty.rawValue) is \(speaking) s")
        }
        let talk = try #require(catalog.scenario("presentation"))
        let easyLevel = try #require(talk.level(.easy))
        let hardLevel = try #require(talk.level(.hard))
        let easyTalk = easyLevel.turns.reduce(0) { $0 + $1.seconds }
        let hardTalk = hardLevel.turns.reduce(0) { $0 + $1.seconds }
        #expect(easyTalk >= 60)
        #expect(hardTalk >= 120)
        let reactions = try #require(catalog.scenario("emotional-reactions"))
        for difficulty in ScenarioDifficulty.allCases {
            let level = try #require(reactions.level(difficulty))
            #expect(level.turns.allSatisfy { $0.cue != nil })
        }
    }

    @Test("Estimated minutes include time to read and listen")
    func estimatedMinutes() throws {
        let catalog = try ScenarioCatalog.load()
        let chat = try #require(catalog.scenario("friend-chat"))
        let easy = try #require(chat.level(.easy))
        // 95 s speaking + 5 turns × 8 s ≈ 2 minutes.
        #expect(easy.estimatedMinutes == 2)
    }

    @Test("Broken JSON gives a readable error")
    func brokenJSON() {
        #expect(throws: ScenarioCatalog.LoadError.self) {
            _ = try ScenarioCatalog.decode(Data("{\"version\": 1}".utf8))
        }
    }
}

@Suite("Scenario script text")
struct ScenarioScriptTests {
    @Test("Stage directions and speaker names aren't read aloud")
    func spokenText() {
        #expect(ScenarioScript.spokenText("(The phone rings.)").isEmpty)
        #expect(ScenarioScript.spokenText("(They walk closer.) What did you say?") == "What did you say?")
        #expect(ScenarioScript.spokenText("Leo: Nice to meet you! Wait, how do you two know each other?") == "Nice to meet you! Wait, how do you two know each other?")
        #expect(ScenarioScript.spokenText("Bad news: it’s going to rain all weekend.") == "Bad news: it’s going to rain all weekend.")
        #expect(ScenarioScript.spokenText("Okay, controversial question: pineapple on pizza?") == "Okay, controversial question: pineapple on pizza?")
        #expect(ScenarioScript.spokenText("(Someone in the audience raises a hand.) “I like the idea, but who’s going to pay for it?”") == "I like the idea, but who’s going to pay for it?")
    }

    @Test("Every partner line in the catalog has something to read, or is a stage direction")
    func catalogLines() throws {
        for scenario in try ScenarioCatalog.load().scenarios {
            for level in scenario.levels.values {
                for turn in level.turns {
                    guard let line = turn.partner else { continue }
                    let spoken = ScenarioScript.spokenText(line)
                    let isDirectionOnly = line.hasPrefix("(") && line.hasSuffix(")")
                    #expect(spoken.isEmpty == isDirectionOnly, "\(scenario.id): \(line)")
                }
            }
        }
    }

    @Test("The transcript lists completed turns in order")
    func transcript() {
        let level = ScenarioLevel(
            setting: "A café",
            partner: "Barista",
            goal: "Order",
            tips: ["a", "b"],
            turns: [
                ScenarioTurn(partner: "Hi!", prompt: "Order.", suggestion: "A latte, please.", cue: nil, seconds: 5),
                ScenarioTurn(partner: nil, prompt: "Pay.", suggestion: nil, cue: nil, seconds: 5),
                ScenarioTurn(partner: "Bye!", prompt: "Say goodbye.", suggestion: nil, cue: nil, seconds: 5),
            ]
        )
        let text = ScenarioScript.transcript(level: level, completedTurns: [2, 0, 7])
        #expect(text == "Barista: Hi!\nYou: A latte, please.\nBarista: Bye!\nYou: Say goodbye.")
    }
}

@Suite("Scenario scoring")
struct ScenarioScoringTests {
    private let target = PitchTargetZone(lowerBound: 180, upperBound: 220)

    @Test("Consistency is the share of seconds that held the target voice")
    func consistency() throws {
        let slipped = try #require(ScenarioScoring.consistency(contour(first: 2, then: 1, low: 140), target: target))
        #expect(abs(slipped - 200.0 / 3) < 1e-9)
        // Within a semitone below the zone still counts.
        #expect(ScenarioScoring.consistency(contour(first: 2, then: 1, low: 175), target: target) == 100)
        #expect(ScenarioScoring.consistency(Array(contour(first: 1, then: 0, low: 0).prefix(3)), target: target) == nil)
        #expect(ScenarioScoring.consistency([], target: target) == nil)
    }

    @Test("A turn takes its scores from the take")
    func turnScore() throws {
        let score = ScenarioScoring.turnScore(scenarioTake(contour: contour(first: 2, then: 1, low: 140)), target: target, text: "Hi")
        #expect(score.pitch == 70)
        #expect(score.resonance == 60)
        #expect(score.weight == 50)
        #expect(score.intonation == 40)
        #expect(score.text == "Hi")
        let consistency = try #require(score.consistency)
        #expect(abs(consistency - 66.667) < 0.01)
        let overall = try #require(ScenarioScoring.overall(score))
        #expect(abs(overall - (70 + 60 + 50 + 40 + 200.0 / 3) / 5) < 1e-9)
        #expect(ScenarioScoring.overall(ScenarioTurnScore()) == nil)
    }

    @Test("The summary averages turns and names the strongest and weakest measure")
    func summary() {
        let turns = [
            ScenarioTurnScore(pitch: 80, resonance: 60, weight: 50, intonation: 40, consistency: 100),
            ScenarioTurnScore(pitch: 60, resonance: 70, weight: 50, intonation: 20, consistency: 50),
        ]
        let summary = ScenarioScoring.summary(turns)
        #expect(summary.averages[.pitch] == 70)
        #expect(summary.averages[.resonance] == 65)
        #expect(summary.averages[.intonation] == 30)
        #expect(summary.averages[.consistency] == 75)
        #expect(summary.overall == 58)
        #expect(summary.strongest == .consistency)
        #expect(summary.weakest == .intonation)
        #expect(summary.turnCount == 2)
    }

    @Test("Ties and single measures don't name a strongest or weakest")
    func summaryEdges() {
        let even = ScenarioScoring.summary([ScenarioTurnScore(pitch: 50, resonance: 50, weight: 50, intonation: 50, consistency: 50)])
        #expect(even.strongest == nil)
        #expect(even.weakest == nil)
        let single = ScenarioScoring.summary([ScenarioTurnScore(pitch: 80)])
        #expect(single.strongest == nil)
        #expect(single.overall == 80)
        let empty = ScenarioScoring.summary([])
        #expect(empty.overall == nil)
        #expect(empty.turnCount == 0)
    }

    @Test("Every measure has a tip")
    func tips() {
        for axis in RadarValues.Axis.allCases {
            #expect(axis.scenarioTip.count > 30)
        }
    }

    @Test("Best scores per scenario and difficulty")
    func bestTable() {
        let table = ScenarioBest.table([
            (scenarioID: "coffee-order", difficulty: .easy, overall: 60),
            (scenarioID: "coffee-order", difficulty: .easy, overall: 72),
            (scenarioID: "coffee-order", difficulty: .hard, overall: nil),
            (scenarioID: "phone-call", difficulty: .medium, overall: 50),
        ])
        #expect(table["coffee-order"]?.scores[.easy] == 72)
        #expect(table["coffee-order"]?.scores[.hard] == nil)
        #expect(table["coffee-order"]?.practiceCount == 3)
        #expect(table["phone-call"]?.scores[.medium] == 50)
        #expect(table["introduction"] == nil)
    }
}

@MainActor
@Suite("Scenario results storage", .serialized)
struct ScenarioResultStoreTests {
    let container: ModelContainer

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    @Test("Saved results keep their turns and feed the radar")
    func saveAndRadar() throws {
        let store = ScenarioResultStore(context: container.mainContext)
        let turns = [
            ScenarioTurnScore(pitch: 80, resonance: 60, weight: 50, intonation: 40, consistency: 100, text: "Hi"),
            ScenarioTurnScore(pitch: 60, resonance: 70, weight: 50, intonation: 20, consistency: 50, text: nil),
        ]
        let date = Date(timeIntervalSince1970: 1_773_144_000)
        let saved = try store.save(scenarioID: "coffee-order", difficulty: .medium, turns: turns, transcript: "Barista: Hi!", now: date)
        #expect(saved.turnScores == turns)
        #expect(saved.overallScore == 58)
        #expect(saved.difficulty == .medium)
        #expect(saved.date == date)
        #expect(!saved.usedAIPartner)

        try store.save(scenarioID: "phone-call", difficulty: .easy, turns: [ScenarioTurnScore(pitch: 90)], transcript: "")
        let coffee = store.results(for: "coffee-order")
        #expect(coffee.count == 1)
        #expect(store.results(for: "introduction").isEmpty)

        let all = try container.mainContext.fetch(FetchDescriptor<ScenarioResult>())
        let radar = ProgressAnalytics.radar(all.map { $0.turnScores })
        #expect(radar?.resultCount == 2)
        #expect(radar?.value(.pitch) == (80 + 60 + 90) / 3.0)

        try store.delete(saved)
        #expect(store.results(for: "coffee-order").isEmpty)
    }

    @Test("Scenarios count toward the week 14 goal")
    func weekFourteen() throws {
        let catalog = try LessonCatalog.load()
        let week14 = try #require(catalog.week(14))
        #expect(week14.goal.kind == .scenarios)
    }
}
