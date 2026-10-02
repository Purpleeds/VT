import Foundation

/// The voice measures that Compare to Target looks at.
nonisolated struct VoiceSnapshot: Sendable, Equatable {
    /// Share of voiced time per 1-semitone bin (`TakeResult` bins).
    var pitchHistogram: [Double]
    var medianPitch: Double?
    var f1: Double?
    var f2: Double?
    var f3: Double?
    var h1MinusH2: Double?
    var intonationSD: Double?

    init(
        pitchHistogram: [Double] = [],
        medianPitch: Double? = nil,
        f1: Double? = nil,
        f2: Double? = nil,
        f3: Double? = nil,
        h1MinusH2: Double? = nil,
        intonationSD: Double? = nil
    ) {
        self.pitchHistogram = pitchHistogram
        self.medianPitch = medianPitch
        self.f1 = f1
        self.f2 = f2
        self.f3 = f3
        self.h1MinusH2 = h1MinusH2
        self.intonationSD = intonationSD
    }

    init(take: TakeResult) {
        self.init(
            pitchHistogram: take.pitchHistogram,
            medianPitch: take.medianPitch,
            f1: take.f1,
            f2: take.f2,
            f3: take.f3,
            h1MinusH2: take.h1MinusH2,
            intonationSD: take.intonationSD
        )
    }
}

nonisolated enum MatchCategory: String, CaseIterable, Identifiable, Sendable {
    case pitch
    case resonance
    case weight
    case intonation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pitch: "Pitch"
        case .resonance: "Resonance"
        case .weight: "Vocal weight"
        case .intonation: "Intonation"
        }
    }
}

nonisolated struct CategoryMatch: Identifiable, Sendable, Equatable {
    let category: MatchCategory
    /// 0–100.
    let percent: Double
    /// e.g. "You 192 Hz · target 205 Hz".
    let detail: String

    var id: String { category.rawValue }
}

/// "Compare to Target" (SPEC section 9): how close the user's voice is to
/// the target profile in each category.
nonisolated enum TargetComparison {
    /// Overlap (0…1) of two pitch histograms after normalizing them and
    /// blurring each by one semitone, so near misses still count.
    static func histogramOverlap(_ first: [Double], _ second: [Double]) -> Double? {
        let count = min(first.count, second.count)
        guard count > 0 else { return nil }
        guard let a = smoothed(Array(first.prefix(count))), let b = smoothed(Array(second.prefix(count))) else { return nil }
        return zip(a, b).reduce(0) { $0 + min($1.0, $1.1) }
    }

    /// Normalized histogram blurred with a [¼, ½, ¼] kernel.
    static func smoothed(_ histogram: [Double]) -> [Double]? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let count = histogram.count
        var blurred = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let value = histogram[index] / total
            blurred[index] += value * 0.5
            if index > 0 { blurred[index - 1] += value * 0.25 }
            if index < count - 1 { blurred[index + 1] += value * 0.25 }
        }
        let blurredTotal = blurred.reduce(0, +)
        return blurredTotal > 0 ? blurred.map { $0 / blurredTotal } : nil
    }

    /// 100 when equal, falling to 0 at `tolerance` (as a ratio, e.g. 1.25).
    static func ratioMatch(_ value: Double, _ target: Double, tolerance: Double) -> Double {
        guard value > 0, target > 0, tolerance > 1 else { return 0 }
        return 100 * max(0, 1 - abs(log(value / target)) / log(tolerance))
    }

    /// 100 when equal, falling to 0 `tolerance` units apart.
    static func differenceMatch(_ value: Double, _ target: Double, tolerance: Double) -> Double {
        guard tolerance > 0 else { return 0 }
        return 100 * max(0, 1 - abs(value - target) / tolerance)
    }

    static func matches(user: VoiceSnapshot, target: VoiceSnapshot) -> [CategoryMatch] {
        var result: [CategoryMatch] = []

        let pitchDetail = "You \(hertz(user.medianPitch)) · target \(hertz(target.medianPitch))"
        if let overlap = histogramOverlap(user.pitchHistogram, target.pitchHistogram) {
            result.append(CategoryMatch(category: .pitch, percent: overlap * 100, detail: pitchDetail))
        } else if let mine = user.medianPitch, let theirs = target.medianPitch, mine > 0, theirs > 0 {
            let semitones = abs(12 * log2(mine / theirs))
            result.append(CategoryMatch(category: .pitch, percent: 100 * max(0, 1 - semitones / 6), detail: pitchDetail))
        }

        var resonanceParts: [(score: Double, weight: Double)] = []
        if let mine = user.f2, let theirs = target.f2 {
            resonanceParts.append((ratioMatch(mine, theirs, tolerance: 1.25), 0.6))
        }
        if let mine = user.f3, let theirs = target.f3 {
            resonanceParts.append((ratioMatch(mine, theirs, tolerance: 1.25), 0.4))
        }
        if !resonanceParts.isEmpty {
            let weight = resonanceParts.reduce(0) { $0 + $1.weight }
            let score = resonanceParts.reduce(0) { $0 + $1.score * $1.weight } / weight
            result.append(CategoryMatch(
                category: .resonance,
                percent: score,
                detail: "F2 \(hertz(user.f2)) · target \(hertz(target.f2))"
            ))
        }

        if let mine = user.h1MinusH2, let theirs = target.h1MinusH2 {
            result.append(CategoryMatch(
                category: .weight,
                percent: differenceMatch(mine, theirs, tolerance: 8),
                detail: "H1–H2 \(decibels(mine)) · target \(decibels(theirs))"
            ))
        }

        if let mine = user.intonationSD, let theirs = target.intonationSD {
            result.append(CategoryMatch(
                category: .intonation,
                percent: ratioMatch(mine, theirs, tolerance: 2.5),
                detail: "Variation \(semitones(mine)) · target \(semitones(theirs))"
            ))
        }
        return result
    }

    /// The average of the category matches.
    static func overall(_ matches: [CategoryMatch]) -> Double? {
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { $0 + $1.percent } / Double(matches.count)
    }

    private static func hertz(_ value: Double?) -> String {
        value.map { "\($0.roundedInt) Hz" } ?? "—"
    }

    private static func decibels(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private static func semitones(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) st"
    }
}

/// Targets suggested from a target voice (SPEC section 9: "use the profile
/// to set targets automatically"), within the ranges Settings allows.
nonisolated struct TargetSuggestion: Sendable, Equatable {
    let pitchZone: PitchTargetZone?
    let f2: Double?
    let f3: Double?
    let h1MinusH2: Double?
    let intonationSD: Double?

    /// Half-width of the pitch zone around the target's median, in semitones.
    static let pitchHalfWidth = 2.0

    init(medianPitch: Double?, f2: Double?, f3: Double?, h1MinusH2: Double?, intonationSD: Double?) {
        pitchZone = medianPitch.flatMap(TargetSuggestion.zone(around:))
        self.f2 = f2.map { TargetSuggestion.snap(min(max($0, 1_400), 2_400), to: 10) }
        self.f3 = f3.map { TargetSuggestion.snap(min(max($0, 2_400), 3_400), to: 10) }
        self.h1MinusH2 = h1MinusH2.map { TargetSuggestion.snap(min(max($0, 4), 16), to: 0.5) }
        self.intonationSD = intonationSD.map { TargetSuggestion.snap(min(max($0, 2), 6), to: 0.25) }
    }

    /// The median ± 2 semitones, in 5 Hz steps, kept within 90–350 Hz.
    static func zone(around median: Double) -> PitchTargetZone? {
        guard median > 0, median.isFinite else { return nil }
        let factor = pow(2, pitchHalfWidth / 12)
        var low = snap(median / factor, to: 5)
        var high = snap(median * factor, to: 5)
        low = min(max(low, 90), 340)
        high = min(max(high, low + 10), 350)
        return PitchTargetZone(lowerBound: low, upperBound: high)
    }

    static func snap(_ value: Double, to step: Double) -> Double {
        (value / step).rounded() * step
    }

    var isEmpty: Bool {
        pitchZone == nil && f2 == nil && f3 == nil && h1MinusH2 == nil && intonationSD == nil
    }
}

/// How a shadowing attempt's pitch contour compares with the target's.
nonisolated struct ContourComparison: Sendable, Equatable {
    /// 0–100: how closely the melody's shape follows the target (pitch level aside).
    let shapeMatch: Double?
    /// Your typical pitch minus the target's, in semitones.
    let levelDifference: Double?

    static let resampledCount = 40

    static func compare(target: [PitchContourPoint], user: [PitchContourPoint]) -> ContourComparison {
        let targetMedian = PitchMath.median(of: target.map(\.frequency))
        let userMedian = PitchMath.median(of: user.map(\.frequency))
        var level: Double?
        if let targetMedian, let userMedian, targetMedian > 0, userMedian > 0 {
            level = 12 * log2(userMedian / targetMedian)
        }

        var shape: Double?
        if let a = resample(target, count: resampledCount), let b = resample(user, count: resampledCount),
           let correlation = correlation(a, b) {
            shape = max(0, correlation) * 100
        }
        return ContourComparison(shapeMatch: shape, levelDifference: level)
    }

    /// The contour as `count` evenly spaced values (semitones relative to its
    /// median) from its first to its last point; nil for very short contours.
    static func resample(_ contour: [PitchContourPoint], count: Int) -> [Double]? {
        let points = contour.filter { $0.frequency > 0 }.sorted { $0.time < $1.time }
        guard points.count >= 5, count >= 2,
              let first = points.first, let last = points.last,
              last.time - first.time >= 0.3,
              let median = PitchMath.median(of: points.map(\.frequency))
        else { return nil }

        var values: [Double] = []
        var index = 0
        for step in 0..<count {
            let time = first.time + (last.time - first.time) * Double(step) / Double(count - 1)
            while index < points.count - 2, points[index + 1].time < time {
                index += 1
            }
            let left = points[index]
            let right = points[min(index + 1, points.count - 1)]
            let span = right.time - left.time
            let fraction = span > 0 ? min(max((time - left.time) / span, 0), 1) : 0
            let frequency = left.frequency + (right.frequency - left.frequency) * fraction
            values.append(12 * log2(frequency / median))
        }
        return values
    }

    /// Pearson correlation; nil when either series is (almost) flat.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        let count = min(a.count, b.count)
        guard count >= 2 else { return nil }
        let x = Array(a.prefix(count))
        let y = Array(b.prefix(count))
        let meanX = x.reduce(0, +) / Double(count)
        let meanY = y.reduce(0, +) / Double(count)
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for index in 0..<count {
            let dx = x[index] - meanX
            let dy = y[index] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        // Flat melodies (under ~0.1 semitone of movement) have no shape to compare.
        guard varianceX / Double(count) > 0.01, varianceY / Double(count) > 0.01 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}
