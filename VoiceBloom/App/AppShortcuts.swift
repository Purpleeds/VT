import AppIntents
import Foundation

/// Siri and Shortcuts phrases (SPEC section 12).
nonisolated struct VoiceBloomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPracticeIntent(),
            phrases: [
                "Start voice practice in \(.applicationName)",
                "Start practice with \(.applicationName)",
            ],
            shortTitle: "Start Practice",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: QuickCheckIntent(),
            phrases: [
                "Do a Quick Check in \(.applicationName)",
                "Quick Check with \(.applicationName)",
            ],
            shortTitle: "Quick Check",
            systemImageName: "stopwatch"
        )
    }
}
