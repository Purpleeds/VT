import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Practice", systemImage: "waveform") {
                PracticeView()
            }
            Tab("Lessons", systemImage: "book") {
                ComingSoonView(
                    title: "Lessons",
                    systemImage: "book",
                    message: "A 16-week plan covering breathing, resonance, pitch, vocal weight, and intonation is on the way."
                )
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
    }
}
