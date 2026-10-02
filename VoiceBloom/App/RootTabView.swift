import SwiftUI

struct RootTabView: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(GuidedSessionCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var controller = sessionController
        @Bindable var guided = coordinator
        TabView {
            Tab("Practice", systemImage: "waveform") {
                PracticeView()
            }
            Tab("Lessons", systemImage: "book") {
                LessonsView()
            }
            Tab("Target Voice", systemImage: "person.wave.2") {
                ComingSoonView(
                    title: "Target Voice",
                    systemImage: "person.wave.2",
                    message: "Soon you’ll be able to import a voice clip you like and compare your voice to it."
                )
            }
            Tab("Progress", systemImage: "chart.xyaxis.line") {
                ProgressDashboardView()
            }
            Tab("More", systemImage: "ellipsis.circle") {
                MoreView()
            }
        }
        // Guided sessions (lessons, routines, single exercises) play full screen.
        .fullScreenCover(isPresented: $guided.isPresenting, onDismiss: {
            Task { await coordinator.didDismiss() }
        }) {
            if let model = coordinator.active {
                GuidedSessionView(model: model)
            }
        }
        // The post-session check-in, wherever the session ended.
        .sheet(item: $controller.checkInRequest) { request in
            CheckInSheet(request: request)
        }
        .alert("You’ve practiced 45 minutes today", isPresented: $guided.isShowingSoftCapAlert) {
            Button("Rest instead", role: .cancel) {
                coordinator.softCapPlan = nil
            }
            Button("Practice anyway") {
                coordinator.confirmSoftCap()
            }
        } message: {
            Text("Your voice does better with breaks. Consider resting now and coming back later or tomorrow.")
        }
    }
}
