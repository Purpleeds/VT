import SwiftUI

@main
struct VoiceBloomApp: App {
    @State private var monitor = LiveVoiceMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(monitor)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Stop the microphone cleanly when leaving the app. The user resumes
            // with one tap when they come back.
            guard newPhase == .background else { return }
            Task { await monitor.pause(.background) }
        }
    }
}
