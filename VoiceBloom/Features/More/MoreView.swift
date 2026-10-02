import Foundation
import SwiftUI

struct MoreView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var isShowingCalibration = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isShowingCalibration = true
                    } label: {
                        LabeledContent {
                            Text(calibrationSummary)
                        } label: {
                            Label("Microphone Calibration", systemImage: "mic.and.signal.meter")
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Setup")
                }

                Section {
                    NavigationLink {
                        CoachChatView()
                    } label: {
                        Label("Ask the Coach", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    NavigationLink {
                        ToolsView()
                    } label: {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                Section {
                    Label("Vocal Health Center", systemImage: "heart.text.square")
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
            .sheet(isPresented: $isShowingCalibration) {
                MicCalibrationView(monitor: monitor)
            }
        }
    }

    private var calibrationSummary: String {
        guard let calibration = monitor.calibration else { return "Not done" }
        return calibration.date.formatted(date: .abbreviated, time: .omitted)
    }
}
