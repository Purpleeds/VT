import Foundation

// Typed access to the profile's stored raw values.
extension UserProfile {
    var theme: AppTheme {
        get { AppTheme(rawValue: themeRawValue) ?? .system }
        set { themeRawValue = newValue.rawValue }
    }

    var displayUnits: DisplayUnits {
        get { DisplayUnits(rawValue: displayUnitsRawValue) ?? .both }
        set { displayUnitsRawValue = newValue.rawValue }
    }

    var defaultSessionLength: SessionLength {
        get { SessionLength(rawValue: defaultSessionLengthRawValue) ?? .standard }
        set { defaultSessionLengthRawValue = newValue.rawValue }
    }

    /// Baseline and target values for the meters.
    var personalReferences: PersonalReferences {
        PersonalReferences(profile: self)
    }

    var hasBaseline: Bool { baselinePitch != nil }

    /// Sets the goal and its default pitch target (custom keeps the current range).
    func setGoal(_ goal: GoalType) {
        goalType = goal
        if goal != .custom {
            targetZone = goal.defaultTarget
        }
    }

    /// Stores Day 1 values from the baseline takes (reading and free speech).
    func applyBaseline(reading: TakeResult?, speech: TakeResult?, recordingID: UUID?) {
        let takes = [reading, speech].compactMap { $0 }.filter(\.hasVoice)
        guard !takes.isEmpty else { return }

        // Weighted by how much voice each take had.
        func weightedAverage(_ value: (TakeResult) -> Double?) -> Double? {
            let pairs = takes.compactMap { take in value(take).map { ($0, take.voicedDuration) } }
            let weight = pairs.reduce(0) { $0 + $1.1 }
            guard weight > 0 else { return nil }
            return pairs.reduce(0) { $0 + $1.0 * $1.1 } / weight
        }

        baselinePitch = weightedAverage(\.medianPitch)
        baselinePitchLow = takes.compactMap(\.lowPitch).min()
        baselinePitchHigh = takes.compactMap(\.highPitch).max()
        baselineF2 = weightedAverage(\.f2)
        baselineF3 = weightedAverage(\.f3)
        baselineH1MinusH2 = weightedAverage(\.h1MinusH2)
        baselineIntonationSD = weightedAverage(\.intonationSD)
        if let recordingID {
            baselineRecordingID = recordingID
        }
    }
}
