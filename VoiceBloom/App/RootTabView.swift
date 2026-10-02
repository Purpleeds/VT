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
                ComingSoonView(
                    title: "Progress",
                    systemImage: "chart.xyaxis.line",
                    message: "Charts of your pitch, resonance, and practice time will appear here once sessions are saved."
                )
            }
            Tab("More", systemImage: "ellipsis.circle") {
                MoreView()
            }
        }
    }
}
