import Combine
import Foundation
import SwiftData
import SwiftUI

nonisolated enum RootTab: Hashable {
    case practice
    case lessons
    case targetVoice
    case progress
    case more
}

struct RootTabView: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(GuidedSessionCoordinator.self) private var coordinator
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = RootTab.practice
    @State private var isShowingQuickCheck = false

    var body: some View {
        @Bindable var controller = sessionController
        @Bindable var guided = coordinator
        TabView(selection: $selectedTab) {
            Tab("Practice", systemImage: "waveform", value: RootTab.practice) {
                PracticeView()
            }
            Tab("Lessons", systemImage: "book", value: RootTab.lessons) {
                LessonsView()
            }
            Tab("Target Voice", systemImage: "person.wave.2", value: RootTab.targetVoice) {
                TargetVoiceView()
            }
            Tab("Progress", systemImage: "chart.xyaxis.line", value: RootTab.progress) {
                ProgressDashboardView()
            }
            Tab("More", systemImage: "ellipsis.circle", value: RootTab.more) {
                MoreView()
            }
        }
        .sheet(isPresented: $isShowingQuickCheck) {
            NavigationStack {
                QuickCheckView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                isShowingQuickCheck = false
                            }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                handleLaunchAction()
            }
            if phase != .inactive {
                _ = MotivationCenter.refresh(context: modelContext)
            }
        }
        .onChange(of: sessionController.checkInRequest?.id) { _, _ in
            // A session just ended.
            _ = MotivationCenter.refresh(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchActionStore.notification)) { _ in
            handleLaunchAction()
        }
        .task {
            handleLaunchAction()
            _ = MotivationCenter.refresh(context: modelContext)
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

    /// Siri, Shortcuts and widget requests (SPEC section 12).
    private func handleLaunchAction() {
        guard let action = LaunchActionStore.take() else { return }
        switch action {
        case .practice:
            selectedTab = .practice
            if !monitor.status.isRunning {
                Task { await monitor.start() }
            }
        case .quickCheck:
            isShowingQuickCheck = true
        }
    }
}
