import SwiftData
import SwiftUI

@main
struct VoiceBloomApp: App {
    @State private var monitor: LiveVoiceMonitor
    @State private var player: RecordingPlayer
    /// Nil only if no data store at all could be opened.
    @State private var sessionController: PracticeSessionController?
    private let container: ModelContainer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let monitor = LiveVoiceMonitor()
        let player = RecordingPlayer()
        let database = VoiceBloomDatabase.open()
        let warning: String? = database?.isTemporary == true
            ? "Your saved history couldn’t be opened, so this session won’t be kept after you quit. Restart VoiceBloom to try again."
            : nil
        let controller = database.map { result in
            PracticeSessionController(
                monitor: monitor,
                player: player,
                container: result.container,
                storageWarning: warning
            )
        }
        _monitor = State(initialValue: monitor)
        _player = State(initialValue: player)
        _sessionController = State(initialValue: controller)
        container = database?.container
    }

    var body: some Scene {
        WindowGroup {
            if let sessionController, let container {
                RootTabView()
                    .environment(monitor)
                    .environment(player)
                    .environment(sessionController)
                    .modelContainer(container)
            } else {
                DataUnavailableView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Save and stop the microphone cleanly when leaving the app.
                // The user resumes with one tap when they come back.
                player.stop()
                Task {
                    if let sessionController {
                        await sessionController.enterBackground()
                    } else {
                        await monitor.pause(.background)
                    }
                }
            case .active:
                sessionController?.refreshRestDay()
            default:
                break
            }
        }
    }
}

/// Shown if the app's data store can't be opened at all.
private struct DataUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "VoiceBloom couldn’t start",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Your practice data couldn’t be opened. Please quit and reopen the app. If this keeps happening, free up some storage on your iPhone and try again.")
        )
    }
}
