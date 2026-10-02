import Foundation

/// Which AI coach to use (SPEC section 10; the coach itself arrives in Stage 11).
nonisolated enum AICoachProvider: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device model when available, else Gemini (if a key is set),
    /// else the rule-based coach.
    case automatic
    /// Only the on-device model or the rule-based coach; nothing leaves the phone.
    case onDeviceOnly
    /// Preset tips only.
    case ruleBased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .onDeviceOnly: "On-device only"
        case .ruleBased: "Simple tips (no AI)"
        }
    }
}

/// Small preferences kept in UserDefaults (not worth a schema change).
nonisolated enum AppPreferences {
    static let aiProviderKey = "ai.provider"
    static let placementWeekKey = "placement.week"
    static let placementDateKey = "placement.date"
    static let placementResultKey = "placement.result"

    static var aiProvider: AICoachProvider {
        get { UserDefaults.standard.string(forKey: aiProviderKey).flatMap(AICoachProvider.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: aiProviderKey) }
    }

    /// Lesson week the placement test recommended (nil if never taken).
    static var placementWeek: Int? {
        let week = UserDefaults.standard.integer(forKey: placementWeekKey)
        return week > 0 ? week : nil
    }

    static var placementResult: PlacementResult? {
        guard let data = UserDefaults.standard.data(forKey: placementResultKey) else { return nil }
        return try? JSONDecoder().decode(PlacementResult.self, from: data)
    }

    static func savePlacement(week: Int, result: PlacementResult, date: Date = Date()) {
        UserDefaults.standard.set(week, forKey: placementWeekKey)
        UserDefaults.standard.set(date, forKey: placementDateKey)
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: placementResultKey)
        }
    }
}
