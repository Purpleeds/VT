import SwiftUI

struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Vocal Health Center", systemImage: "heart.text.square")
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                    Label("Settings", systemImage: "gearshape")
                } header: {
                    Text("Coming soon")
                }
                .foregroundStyle(.secondary)

                Section {
                    NavigationLink {
                        DebugView()
                    } label: {
                        Label("Debug & Tuning", systemImage: "ladybug")
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Raw pitch, noise floor, and engine timing for checking accuracy on a real device.")
                }

                Section {
                    Label("Your voice is analyzed on this iPhone. Audio never leaves your device.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("More")
        }
    }
}
