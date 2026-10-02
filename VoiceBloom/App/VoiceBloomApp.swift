import SwiftData
import SwiftUI

@main
struct VoiceBloomApp: App {
    @State private var monitor: LiveVoiceMonitor
    @State private var player: RecordingPlayer
    @State private var appLock = AppLock()
    /// Nil only if no data store at all could be opened.
    @State private var sessionController: PracticeSessionController?
    @State private var guidedSessions: GuidedSessionCoordinator?
    private let container: ModelContainer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let monitor = LiveVoiceMonitor()
        let player = RecordingPlayer()
        let database = VoiceBloomDatabase.open()
        let warning: String? = database?.isTemporary == true
            ? "Your saved history couldn’t be opened, so this session won’t be kept after you quit. Restart Chirp to try again."
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
        _guidedSessions = State(initialValue: controller.flatMap { controller in
            database.map { GuidedSessionCoordinator(controller: controller, container: $0.container) }
        })
        container = database?.container
    }

    var body: some Scene {
        WindowGroup {
            if let sessionController, let guidedSessions, let container {
                AppRootView()
                    .environment(monitor)
                    .environment(player)
                    .environment(sessionController)
                    .environment(guidedSessions)
                    .environment(appLock)
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
                appLock.lockIfEnabled()
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
            "Chirp couldn’t start",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Your practice data couldn’t be opened. Please quit and reopen the app. If this keeps happening, free up some storage on your iPhone and try again.")
        )
    }
}
