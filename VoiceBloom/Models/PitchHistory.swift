import Foundation

/// One point on the scrolling pitch graph.
nonisolated struct PitchGraphPoint: Sendable, Equatable {
    let time: Double
    /// Smoothed pitch to draw as the line, or nil to leave a gap.
    let frequency: Double?
    /// Raw YIN estimate, drawn as dots on the debug screen.
    let rawFrequency: Double?
    let isVoiced: Bool

    init(time: Double, frequency: Double?, rawFrequency: Double?, isVoiced: Bool) {
        self.time = time
        self.frequency = frequency
        self.rawFrequency = rawFrequency
        self.isVoiced = isVoiced
    }

    init(frame: VoiceFrame) {
        time = frame.time
        switch frame.status {
        case .voiced, .octaveJumpHeld:
            frequency = frame.displayFrequency
        case .unpitched, .belowNoiseGate:
            frequency = nil
        }
        rawFrequency = frame.rawFrequency
        isVoiced = frame.status == .voiced
    }
}

/// Fixed-size ring of recent graph points (oldest are overwritten).
nonisolated struct PitchHistory: Sendable {
    let capacity: Int
    private var storage: [PitchGraphPoint] = []
    /// Index of the oldest point once the ring is full.
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    var latest: PitchGraphPoint? {
        guard !storage.isEmpty else { return nil }
        if storage.count < capacity {
            return storage.last
        }
        return storage[(head + capacity - 1) % capacity]
    }

    var latestTime: Double? { latest?.time }

    mutating func append(_ point: PitchGraphPoint) {
        if storage.count < capacity {
            storage.append(point)
        } else {
            storage[head] = point
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Points with `startTime <= time <= endTime`, oldest first.
    func points(from startTime: Double, through endTime: Double) -> [PitchGraphPoint] {
        var result: [PitchGraphPoint] = []
        result.reserveCapacity(storage.count)
        let total = storage.count
        for offset in 0..<total {
            let point = storage[(head + offset) % total]
            if point.time >= startTime, point.time <= endTime {
                result.append(point)
            }
        }
        return result
    }

    /// All points, oldest first.
    var allPoints: [PitchGraphPoint] {
        points(from: -.infinity, through: .infinity)
    }
}
