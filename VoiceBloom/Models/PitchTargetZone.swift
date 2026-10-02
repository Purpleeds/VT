import Foundation

/// The pitch range the user is aiming for.
nonisolated struct PitchTargetZone: Sendable, Equatable {
    let lowerBound: Double
    let upperBound: Double

    init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = min(lowerBound, upperBound)
        self.upperBound = max(lowerBound, upperBound)
    }

    /// Default feminine speaking target.
    static let feminine = PitchTargetZone(lowerBound: 180, upperBound: 220)
    /// Default androgynous speaking target.
    static let androgynous = PitchTargetZone(lowerBound: 150, upperBound: 180)

    func contains(_ frequency: Double) -> Bool {
        frequency >= lowerBound && frequency <= upperBound
    }

    /// Geometric centre, which is the musical midpoint of the range.
    var center: Double { (lowerBound * upperBound).squareRoot() }

    /// e.g. "180–220 Hz"
    var formatted: String {
        "\(lowerBound.roundedInt)–\(upperBound.roundedInt) Hz"
    }

    /// e.g. "180 to 220 hertz", for VoiceOver.
    var spokenDescription: String {
        "\(lowerBound.roundedInt) to \(upperBound.roundedInt) hertz"
    }
}
