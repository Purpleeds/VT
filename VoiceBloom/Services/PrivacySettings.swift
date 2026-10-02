import Foundation
import UIKit

/// Privacy preferences kept on this iPhone (SPEC section 13).
nonisolated enum PrivacyPreferences {
    /// Cover the app with a blank screen in the app switcher (on by default).
    static let appSwitcherCoverKey = "privacy.appSwitcherCover"
    static let notificationStyleKey = "privacy.notificationStyle"

    static var coversAppSwitcher: Bool {
        (UserDefaults.standard.object(forKey: appSwitcherCoverKey) as? Bool) ?? true
    }

    static var notificationStyle: NotificationWordingStyle {
        UserDefaults.standard.string(forKey: notificationStyleKey).flatMap(NotificationWordingStyle.init(rawValue:)) ?? .neutral
    }
}

/// How reminders are worded on the Lock Screen.
nonisolated enum NotificationWordingStyle: String, CaseIterable, Identifiable, Sendable {
    /// Says nothing about voice training (the default).
    case neutral
    /// Mentions voice practice.
    case descriptive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: "Neutral"
        case .descriptive: "Mention voice practice"
        }
    }
}

/// The words used in reminders. Neutral wording never says what is being
/// practiced, and no wording ever guilt-trips (SPEC sections 12 and 13).
nonisolated struct NotificationWording: Equatable, Sendable {
    let title: String
    let body: String

    static func dailyReminder(_ style: NotificationWordingStyle) -> NotificationWording {
        switch style {
        case .neutral:
            NotificationWording(title: "Time for practice", body: "A few gentle minutes is all it takes today.")
        case .descriptive:
            NotificationWording(title: "Time for voice practice", body: "A few gentle minutes of voice training is all it takes today.")
        }
    }

    static func eveningNudge(_ style: NotificationWordingStyle) -> NotificationWording {
        switch style {
        case .neutral:
            NotificationWording(title: "Time for practice", body: "Even five easy minutes count. Or take a rest day; that’s part of practice too.")
        case .descriptive:
            NotificationWording(title: "Voice practice", body: "Even five easy minutes of voice work count. Or rest your voice today; that’s part of practice too.")
        }
    }

    /// Words that would reveal what the app is for; neutral wording avoids them.
    static let revealingWords = ["voice", "vocal", "pitch", "resonance", "gender", "feminine", "masculine", "trans"]

    var isNeutral: Bool {
        let text = (title + " " + body).lowercased()
        return !Self.revealingWords.contains { text.contains($0) }
    }
}

/// The home-screen icon: the standard one, or a plain neutral one.
nonisolated enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case standard
    case neutral

    var id: String { rawValue }

    /// The alternate icon set's name in the asset catalog (nil = primary).
    var alternateIconName: String? {
        switch self {
        case .standard: nil
        case .neutral: "NeutralIcon"
        }
    }

    /// The asset shown as a preview in Settings.
    var previewImageName: String {
        switch self {
        case .standard: "AppIconPreview"
        case .neutral: "NeutralIconPreview"
        }
    }

    var title: String {
        switch self {
        case .standard: "VoiceBloom"
        case .neutral: "Neutral (grey list)"
        }
    }

    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .standard
    }
}

/// Switches the home-screen icon.
@MainActor
enum AppIconService {
    static var current: AppIconChoice {
        AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
    }

    static var isSupported: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    /// iOS shows its own "You have changed the icon" alert afterwards.
    static func set(_ choice: AppIconChoice) async -> Bool {
        guard isSupported else { return false }
        guard UIApplication.shared.alternateIconName != choice.alternateIconName else { return true }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            return true
        } catch {
            return false
        }
    }
}
