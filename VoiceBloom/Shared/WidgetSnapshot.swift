import Foundation

/// What the widgets show, written by the app into the shared App Group.
/// This file is compiled into both the app and the widget extension.
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    var streakDays: Int
    var practicedToday: Bool
    var freezeAvailable: Bool
    var todayMinutes: Double
    var goalMinutes: Int
    var challenge: String?
    var updated: Date

    static let appGroup = "group.com.williamzhao.voicebloom"
    static let key = "widget.snapshot"

    /// The shared defaults (nil if the App Group isn't set up).
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func load() -> WidgetSnapshot? {
        guard let data = sharedDefaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        WidgetSnapshot.sharedDefaults?.set(data, forKey: WidgetSnapshot.key)
    }

    /// Minutes practiced on `date` (0 once the day has changed).
    func minutes(on date: Date, calendar: Calendar = .current) -> Double {
        calendar.isDate(updated, inSameDayAs: date) ? todayMinutes : 0
    }

    /// The streak as of `date`: kept through the day after the last update
    /// (today's practice is still to come), gone after that.
    func streak(on date: Date, calendar: Calendar = .current) -> Int {
        let updatedDay = calendar.startOfDay(for: updated)
        let day = calendar.startOfDay(for: date)
        let gap = calendar.dateComponents([.day], from: updatedDay, to: day).day ?? 0
        switch gap {
        case ...0: return streakDays
        case 1: return practicedToday ? streakDays : 0
        default: return 0
        }
    }

    /// Fraction (0…1) of the daily goal done on `date`.
    func goalProgress(on date: Date, calendar: Calendar = .current) -> Double {
        guard goalMinutes > 0 else { return 0 }
        return min(minutes(on: date, calendar: calendar) / Double(goalMinutes), 1)
    }
}
