import Foundation

/// The balloon game (SPEC section 12): your pitch sets the balloon's height,
/// and you guide it through gaps. Holding a bright resonance while passing a
/// gap scores a bonus. Heights run from 0 (bottom) to 1 (top).
nonisolated struct PitchGameEngine: Sendable {
    nonisolated struct Gate: Sendable, Equatable, Identifiable {
        let id: Int
        var x: Double
        let gapCenter: Double
        let gapHeight: Double
        var isResolved = false
        var wasPassed = false
    }

    static let balloonX = 0.25
    static let balloonRadius = 0.04
    static let startingLives = 3
    /// Semitones shown below and above the target zone.
    static let margin = 5.0
    static let brightScore = 67.0

    let target: PitchTargetZone
    /// Slower for Reduce Motion or beginners.
    let speedFactor: Double
    private(set) var balloonY = 0.5
    private(set) var gates: [Gate]
    private(set) var score = 0
    private(set) var brightBonuses = 0
    private(set) var lives = PitchGameEngine.startingLives
    private(set) var isOver = false
    private(set) var elapsed = 0.0
    /// True while the balloon is steered by a voice.
    private(set) var isHeard = false
    private var nextID: Int
    private var random: SampleRandom

    init(target: PitchTargetZone, speedFactor: Double = 1, seed: UInt64 = 1, gates: [Gate]? = nil) {
        self.target = target
        self.speedFactor = speedFactor
        random = SampleRandom(seed: seed)
        self.gates = gates ?? []
        nextID = (gates?.map(\.id).max() ?? 0) + 1
        if gates == nil {
            spawnGate(at: 1.1)
        }
    }

    var speed: Double {
        min(0.16 + 0.004 * Double(score), 0.3) * speedFactor
    }

    /// The target zone's band on screen.
    var targetBand: ClosedRange<Double> {
        height(for: target.lowerBound)...height(for: target.upperBound)
    }

    private var lowest: Double { target.lowerBound * pow(2, -Self.margin / 12) }
    private var highest: Double { target.upperBound * pow(2, Self.margin / 12) }

    /// Height for a pitch: linear in semitones from 0.05 to 0.95.
    func height(for pitch: Double) -> Double {
        guard pitch > 0 else { return 0 }
        let span = 12 * log2(highest / lowest)
        guard span > 0 else { return 0.5 }
        let position = 12 * log2(pitch / lowest) / span
        return min(max(0.05 + 0.9 * position, 0), 1)
    }

    /// The pitch that puts the balloon at `height`.
    func pitch(forHeight height: Double) -> Double {
        let span = 12 * log2(highest / lowest)
        let position = (height - 0.05) / 0.9
        return lowest * pow(2, position * span / 12)
    }

    /// Advances the game by `dt` seconds with the current voice (nil in
    /// silence) and resonance score.
    mutating func step(dt: Double, pitch: Double?, resonance: Double?) {
        guard !isOver, dt > 0 else { return }
        elapsed += dt

        if let pitch, pitch > 0 {
            isHeard = true
            let goal = height(for: pitch)
            balloonY += (goal - balloonY) * min(1, dt * 6)
        } else {
            isHeard = false
            // Gentle sinking in silence.
            balloonY = max(0, balloonY - 0.15 * dt)
        }

        let isBright = (resonance ?? 0) >= Self.brightScore
        let move = speed * dt
        for index in gates.indices {
            gates[index].x -= move
            guard !gates[index].isResolved, gates[index].x <= Self.balloonX else { continue }
            gates[index].isResolved = true
            let clearance = gates[index].gapHeight / 2 - Self.balloonRadius
            if abs(balloonY - gates[index].gapCenter) <= clearance {
                gates[index].wasPassed = true
                score += 1
                if isBright {
                    score += 1
                    brightBonuses += 1
                }
            } else {
                lives -= 1
                if lives <= 0 {
                    isOver = true
                }
            }
        }
        gates.removeAll { $0.x < -0.15 }
        if let last = gates.last {
            if last.x < 1.1 - 0.55 {
                spawnGate(at: 1.1)
            }
        } else {
            spawnGate(at: 1.1)
        }
    }

    private mutating func spawnGate(at x: Double) {
        // Gaps sit around the target zone so staying in target passes them.
        let band = targetBand
        let low = max(0.2, band.lowerBound - 0.05)
        let high = min(0.8, band.upperBound + 0.05)
        let center = low + (high - low) * Double.random(in: 0..<1, using: &random)
        let gapHeight = max(0.22, 0.32 - 0.004 * Double(score))
        gates.append(Gate(id: nextID, x: x, gapCenter: center, gapHeight: gapHeight))
        nextID += 1
    }
}

/// Balloon game scores, kept in UserDefaults.
nonisolated struct PitchGameRecord: Codable, Sendable, Equatable {
    let score: Int
    let date: Date
}

nonisolated enum PitchGameScores {
    static let key = "pitchGame.scores"

    static func all() -> [PitchGameRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PitchGameRecord].self, from: data)) ?? []
    }

    static var best: Int { all().map(\.score).max() ?? 0 }

    /// Saves a score; returns true for a new best.
    @discardableResult
    static func save(_ score: Int, date: Date = Date()) -> Bool {
        let previousBest = best
        var records = all()
        records.append(PitchGameRecord(score: score, date: date))
        if let data = try? JSONEncoder().encode(Array(records.suffix(50))) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return score > previousBest
    }
}
