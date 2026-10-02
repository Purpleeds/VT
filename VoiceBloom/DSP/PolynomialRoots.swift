import Foundation

/// Minimal complex number for root finding.
nonisolated struct ComplexNumber: Sendable, Equatable {
    var real: Double
    var imaginary: Double

    init(_ real: Double, _ imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }

    static let zero = ComplexNumber(0, 0)
    static let one = ComplexNumber(1, 0)

    /// Distance from the origin, |z|.
    var magnitude: Double { hypot(real, imaginary) }
    /// Angle from the positive real axis, in radians (−π...π).
    var argument: Double { atan2(imaginary, real) }

    static func + (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    static func - (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(lhs.real - rhs.real, lhs.imaginary - rhs.imaginary)
    }

    static func * (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(
            lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func / (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        let denominator = rhs.real * rhs.real + rhs.imaginary * rhs.imaginary
        guard denominator > 0 else { return ComplexNumber(.nan, .nan) }
        return ComplexNumber(
            (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }
}

/// Finds all complex roots of a polynomial with the Aberth–Ehrlich method.
///
/// Every root estimate is refined at once: each takes a Newton step that is
/// also "pushed away" from the other estimates, so they spread out and
/// converge to different roots instead of all finding the same one.
/// Convergence is cubic; LPC polynomials of order 12 settle in ~10 iterations.
nonisolated enum PolynomialRoots {
    /// - Parameter coefficients: Highest power first: [c₀, c₁, …, cₙ] for c₀zⁿ + c₁zⁿ⁻¹ + … + cₙ.
    /// - Returns: The n roots (empty for constant or invalid polynomials).
    static func roots(
        of coefficients: [Double],
        maximumIterations: Int = 100,
        tolerance: Double = 1e-12
    ) -> [ComplexNumber] {
        // Drop leading zeros so the first coefficient is the true degree.
        guard let firstNonZero = coefficients.firstIndex(where: { $0 != 0 }) else { return [] }
        let trimmed = Array(coefficients[firstNonZero...])
        let degree = trimmed.count - 1
        guard degree >= 1, trimmed.allSatisfy(\.isFinite) else { return [] }

        // Make the polynomial monic (leading coefficient 1).
        let leading = trimmed[0]
        let monic = trimmed.map { $0 / leading }

        // Start on a circle whose radius is the geometric mean of the root
        // magnitudes (|product of roots|^(1/n)), at angles offset from the real
        // axis so no two starting points are conjugates of each other.
        let product = abs(monic[degree])
        let radius = max(pow(product, 1 / Double(degree)), 0.5)
        var estimates = (0..<degree).map { index -> ComplexNumber in
            let angle = 2 * Double.pi * Double(index) / Double(degree) + 0.4
            return ComplexNumber(radius * cos(angle), radius * sin(angle))
        }

        for _ in 0..<max(1, maximumIterations) {
            var largestStep = 0.0
            for index in 0..<degree {
                let point = estimates[index]
                let (value, derivative) = evaluate(monic, at: point)
                if value.magnitude == 0 { continue }

                // Newton ratio p(z) / p'(z).
                let newton = derivative.magnitude > 0 ? value / derivative : value
                // Repulsion from the other estimates: Σ 1 / (z_k − z_j).
                var repulsion = ComplexNumber.zero
                for other in 0..<degree where other != index {
                    let difference = point - estimates[other]
                    if difference.magnitude > 0 {
                        repulsion = repulsion + ComplexNumber.one / difference
                    }
                }
                let denominator = ComplexNumber.one - newton * repulsion
                let step = denominator.magnitude > 0 ? newton / denominator : newton
                guard step.real.isFinite, step.imaginary.isFinite else { continue }

                estimates[index] = point - step
                largestStep = max(largestStep, step.magnitude)
            }
            if largestStep < tolerance {
                break
            }
        }
        return estimates
    }

    /// Evaluates p(z) and p′(z) together with Horner's rule.
    static func evaluate(_ coefficients: [Double], at point: ComplexNumber) -> (value: ComplexNumber, derivative: ComplexNumber) {
        var value = ComplexNumber.zero
        var derivative = ComplexNumber.zero
        for coefficient in coefficients {
            derivative = derivative * point + value
            value = value * point + ComplexNumber(coefficient)
        }
        return (value, derivative)
    }
}
