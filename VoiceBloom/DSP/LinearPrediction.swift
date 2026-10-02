import Foundation

/// Result of fitting an all-pole (LPC) model.
nonisolated struct LinearPredictionModel: Sendable, Equatable {
    /// Polynomial A(z) = 1 + a₁z⁻¹ + … + aₚz⁻ᵖ, stored as [1, a₁, …, aₚ].
    /// Its roots are the poles of the vocal-tract filter 1 / A(z).
    let coefficients: [Double]
    /// Energy left unexplained by the model (the prediction error).
    let predictionError: Double
    /// Reflection (PARCOR) coefficients k₁…kₚ; all have |k| < 1 for a stable model.
    let reflectionCoefficients: [Double]

    var order: Int { coefficients.count - 1 }
}

/// Linear predictive coding helpers.
///
/// LPC models each sample as a weighted sum of the previous p samples. The
/// weights describe a filter with p poles; for a voice, pairs of poles sit
/// at the resonances of the vocal tract, which are the formants.
nonisolated enum LinearPrediction {
    /// Autocorrelation r(k) = Σ x[n]·x[n+k] for k = 0...maxLag.
    static func autocorrelation(_ samples: UnsafeBufferPointer<Double>, maxLag: Int) -> [Double] {
        let count = samples.count
        return (0...max(0, maxLag)).map { lag -> Double in
            guard lag < count else { return 0 }
            var sum = 0.0
            for index in 0..<(count - lag) {
                sum += samples[index] * samples[index + lag]
            }
            return sum
        }
    }

    static func autocorrelation(_ samples: [Double], maxLag: Int) -> [Double] {
        samples.withUnsafeBufferPointer { autocorrelation($0, maxLag: maxLag) }
    }

    /// Solves the LPC normal equations with the Levinson–Durbin recursion.
    ///
    /// The autocorrelation matrix is Toeplitz (constant along its diagonals), so
    /// instead of a general O(p³) solve, the model is built up one order at a
    /// time in O(p²): each step computes a reflection coefficient k from how
    /// badly the current model predicts the next lag, then updates all
    /// coefficients with it. The error shrinks by (1 − k²) each step.
    ///
    /// - Returns: nil for silent input or an unstable (|k| ≥ 1) solution.
    static func levinsonDurbin(autocorrelation r: [Double], order: Int) -> LinearPredictionModel? {
        guard order >= 1, r.count > order, r[0] > 0 else { return nil }

        var coefficients = [Double](repeating: 0, count: order + 1)
        coefficients[0] = 1
        var reflections: [Double] = []
        reflections.reserveCapacity(order)
        var error = r[0]

        for step in 1...order {
            // How much of r(step) the current model fails to predict.
            var accumulator = r[step]
            for index in 1..<step {
                accumulator += coefficients[index] * r[step - index]
            }
            let reflection = -accumulator / error
            guard reflection.isFinite, abs(reflection) < 1 else { return nil }

            // Update a₁…a_{step-1} using the previous order's coefficients.
            let previous = coefficients
            for index in 1..<step {
                coefficients[index] = previous[index] + reflection * previous[step - index]
            }
            coefficients[step] = reflection
            reflections.append(reflection)

            error *= 1 - reflection * reflection
            guard error > 0 else { return nil }
        }

        return LinearPredictionModel(
            coefficients: coefficients,
            predictionError: error,
            reflectionCoefficients: reflections
        )
    }
}
