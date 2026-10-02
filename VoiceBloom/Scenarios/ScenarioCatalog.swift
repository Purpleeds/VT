import Foundation

/// One exchange: what the other person says, and what you do.
nonisolated struct ScenarioTurn: Codable, Sendable, Equatable {
    /// The other person's line. Text in parentheses is a stage direction.
    var partner: String?
    /// What to do this turn.
    let prompt: String
    /// A line to say (Easy levels, stories and scripts).
    var suggestion: String?
    /// An emotion or delivery cue, e.g. "Excited" or "Call out".
    var cue: String?
    /// The longest the turn records for (you can finish early).
    let seconds: Int
}

/// A scenario at one difficulty.
nonisolated struct ScenarioLevel: Codable, Sendable, Equatable {
    let setting: String
    /// The other person's role.
    let partner: String
    let goal: String
    let tips: [String]
    let turns: [ScenarioTurn]

    /// Rough length in minutes, including listening and reading time.
    var estimatedMinutes: Int {
        let speaking = turns.reduce(0) { $0 + $1.seconds }
        let other = turns.count * 8
        return max(1, Int((Double(speaking + other) / 60).rounded()))
    }
}

nonisolated struct Scenario: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let summary: String
    /// What this scenario trains, in one sentence.
    let focus: String
    let levels: [String: ScenarioLevel]

    func level(_ difficulty: ScenarioDifficulty) -> ScenarioLevel? {
        levels[difficulty.rawValue]
    }

    static func == (lhs: Scenario, rhs: Scenario) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The pre-written scenario scripts (SPEC section 7), from Scenarios.json.
nonisolated struct ScenarioCatalog: Codable, Sendable {
    let version: Int
    let scenarios: [Scenario]

    static let fileName = "Scenarios"

    nonisolated enum LoadError: LocalizedError {
        case missingFile
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingFile: "The scenarios are missing from the app."
            case .unreadable(let detail): "The scenarios couldn’t be read (\(detail))."
            }
        }
    }

    static func load(from bundle: Bundle = .main) throws -> ScenarioCatalog {
        guard let url = bundle.url(forResource: fileName, withExtension: "json") else {
            throw LoadError.missingFile
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
    }

    static func decode(_ data: Data) throws -> ScenarioCatalog {
        do {
            return try JSONDecoder().decode(ScenarioCatalog.self, from: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
    }

    func scenario(_ id: String) -> Scenario? {
        scenarios.first { $0.id == id }
    }
}

extension ScenarioDifficulty {
    nonisolated var title: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .easy: "Short turns with lines to read."
        case .medium: "Your own words, with prompts."
        case .hard: "Longer, unscripted, with surprises."
        }
    }
}

/// Text helpers for scripts.
nonisolated enum ScenarioScript {
    /// The part of a partner line to read aloud: stage directions in
    /// parentheses and a leading "Name:" are left out.
    static func spokenText(_ line: String) -> String {
        var text = ""
        var depth = 0
        for character in line {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                text.append(character)
            }
        }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Leo: Nice to meet you!" → "Nice to meet you!"
        if let colon = trimmed.firstIndex(of: ":") {
            let speaker = trimmed[..<colon]
            let words = speaker.split(separator: " ")
            if !speaker.isEmpty, words.count <= 2, words.allSatisfy({ $0.first?.isUppercase == true }) {
                trimmed = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"").union(.whitespaces))
    }

    /// The script of a practice, for `ScenarioResult.transcript`.
    static func transcript(level: ScenarioLevel, completedTurns: [Int]) -> String {
        completedTurns.sorted().compactMap { index -> String? in
            guard level.turns.indices.contains(index) else { return nil }
            let turn = level.turns[index]
            var lines: [String] = []
            if let partner = turn.partner {
                lines.append("\(level.partner): \(partner)")
            }
            lines.append("You: \(turn.suggestion ?? turn.prompt)")
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}
