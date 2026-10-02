import Foundation
import SwiftUI

/// Slip alert, strain warning and eyes-free options.
/// (Becomes part of the full Settings screen in a later stage.)
struct FeedbackSettingsView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var monitor = monitor
        NavigationStack {
            Form {
                Section {
                    Toggle("Pitch drops below target", isOn: $monitor.feedbackSettings.pitchSlipAlerts)
                    Toggle("Resonance gets darker", isOn: $monitor.feedbackSettings.resonanceSlipAlerts)
                    Picker("Sensitivity", selection: $monitor.feedbackSettings.sensitivity) {
                        ForEach(SlipSensitivity.allCases) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                } header: {
                    Text("Slip alerts")
                } footer: {
                    Text("\(monitor.feedbackSettings.sensitivity.detail) Pauses between words don’t count, and you get at most one alert every few seconds.")
                }

                Section {
                    Toggle(isOn: $monitor.feedbackSettings.hapticAlerts) {
                        Label("Haptic tap", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .disabled(!monitor.supportsHaptics)
                    Toggle(isOn: $monitor.feedbackSettings.soundAlerts) {
                        Label("Soft chime", systemImage: "bell")
                    }
                    Toggle(isOn: $monitor.feedbackSettings.visualAlerts) {
                        Label("On-screen color and message", systemImage: "eye")
                    }
                } header: {
                    Text("How to alert")
                } footer: {
                    Text(alertFooter)
                }

                Section {
                    Toggle("“Your voice sounds tired” warnings", isOn: $monitor.feedbackSettings.strainWarnings)
                } header: {
                    Text("Voice comfort")
                } footer: {
                    Text("Shown when jitter, shimmer and noise stay clearly (30%+) above your usual values. Rough indicators from your phone’s mic, not a medical diagnosis.")
                }

                Section {
                    Toggle("Add soft chimes", isOn: $monitor.feedbackSettings.eyesFreeTones)
                } header: {
                    Text("Eyes-free practice")
                } footer: {
                    Text("Eyes-free practice always uses haptics when your iPhone supports them. Two soft taps mean pitch is drifting down, a low buzz means resonance is darkening, and a light tap means you’re back on target.")
                }

                Section {
                    Button("Try a Slip Alert", systemImage: "bell.badge") {
                        monitor.preview(.slip([.pitch]))
                    }
                    Button("Try “Back on Target”", systemImage: "checkmark.circle") {
                        monitor.preview(.recovered)
                    }
                } footer: {
                    Text("Chimes only play while listening.")
                }
            }
            .navigationTitle("Alerts & Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var alertFooter: String {
        var text = "Choose any combination."
        if !monitor.supportsHaptics {
            text += " This device doesn’t support haptics."
        }
        text += " The mic can hear chimes and vibrations, so those moments are left out of your stats. Headphones avoid this for chimes."
        return text
    }
}
