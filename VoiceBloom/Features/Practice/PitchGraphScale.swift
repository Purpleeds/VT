import Foundation

/// Vertical scale of the pitch graph.
///
/// Pitch is drawn on a logarithmic (musical) axis so that one semitone takes
/// the same height anywhere on the graph, the same way the ear hears it.
nonisolated struct PitchGraphScale: Sendable, Equatable {
    let lowerFrequency: Double
    let upperFrequency: Double

    init(lowerFrequency: Double, upperFrequency: Double) {
        let lower = max(20, min(lowerFrequency, upperFrequency))
        self.lowerFrequency = lower
        self.upperFrequency = max(upperFrequency, lower * 1.5)
    }

    /// A range that comfortably fits typical speaking voices (~85–255 Hz)
    /// as well as the target zone, so nobody's voice falls off the graph.
    init(target: PitchTargetZone) {
        self.init(
            lowerFrequency: min(70, target.lowerBound / 2),
            upperFrequency: max(400, target.upperBound * 1.6)
        )
    }

    /// 0 at the bottom of the graph, 1 at the top (clamped).
    func position(for frequency: Double) -> Double {
        guard frequency > 0, frequency.isFinite else { return 0 }
        let position = log(frequency / lowerFrequency) / log(upperFrequency / lowerFrequency)
        return min(max(position, 0), 1)
    }

    /// Frequencies to draw grid lines at, skipping ones that would sit on an edge.
    var gridFrequencies: [Double] {
        [60, 80, 100, 150, 200, 250, 300, 400, 500, 600, 800].filter { frequency in
            frequency > lowerFrequency && frequency < upperFrequency
                && (0.04...0.96).contains(position(for: frequency))
        }
    }
}
