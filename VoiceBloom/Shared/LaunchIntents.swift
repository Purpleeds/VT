import AppIntents
import Foundation

/// Something the app should do when it opens (from Siri, Shortcuts or a
/// widget). Compiled into both the app and the widget extension.
nonisolated enum LaunchAction: String, Sendable {
    case practice
    case quickCheck
}

nonisolated enum LaunchActionStore {
    static let key = "launch.pendingAction"
    static let notification = Notification.Name("VoiceBloomLaunchAction")

    /// Records the action for the app to pick up.
    static func request(_ action: LaunchAction) {
        WidgetSnapshot.sharedDefaults?.set(action.rawValue, forKey: key)
        UserDefaults.standard.set(action.rawValue, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// The waiting action, cleared once read.
    static func take() -> LaunchAction? {
        let raw = UserDefaults.standard.string(forKey: key) ?? WidgetSnapshot.sharedDefaults?.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        WidgetSnapshot.sharedDefaults?.removeObject(forKey: key)
        return raw.flatMap(LaunchAction.init(rawValue:))
    }
}

/// "Start voice practice" (SPEC section 12).
nonisolated struct StartPracticeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Practice"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        LaunchActionStore.request(.practice)
        return .result()
    }
}

/// "Do a Quick Check" (SPEC section 12).
nonisolated struct QuickCheckIntent: AppIntent {
    static let title: LocalizedStringResource = "Do a Quick Check"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        LaunchActionStore.request(.quickCheck)
        return .result()
    }
}
