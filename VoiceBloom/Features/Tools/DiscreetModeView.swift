import Foundation
import SwiftUI

/// Discreet Mode (SPEC section 8): quiet exercises for when others are
/// nearby, with reference tones and chimes through headphones only.
struct DiscreetModeView: View {
    @AppStorage(DiscreetMode.key) private var isOn = false
    @State private var headphonesConnected = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $isOn) {
                    Label("Discreet Mode", systemImage: isOn ? "speaker.slash.fill" : "speaker.slash")
                }
                LabeledContent {
                    Text(headphonesConnected ? "Connected" : "Not connected")
                        .foregroundStyle(headphonesConnected ? Theme.targetZone : Color.secondary)
                } label: {
                    Label("Headphones", systemImage: "headphones")
                }
            } footer: {
                Text("Use it on the bus, at work, or anywhere you’d rather not be heard. It stays on until you turn it off.")
            }

            Section("While it’s on") {
                DiscreetRule(
                    systemImage: "headphones",
                    text: "Reference tones, the piano and lesson pitch-matching play through headphones only, never the speaker."
                )
                DiscreetRule(
                    systemImage: "bell.slash",
                    text: "Slip-alert chimes are silent unless headphones are connected. Turn on vibration in Alerts & Feedback to still feel them."
                )
                DiscreetRule(
                    systemImage: "mic",
                    text: "Your voice is still analyzed on this iPhone as usual. Soft voices work; very quiet ones may not show a pitch."
                )
            }

            if let catalog = LessonLibrary.catalog {
                Section {
                    ForEach(catalog.discreet) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(exercise.title)
                                    .font(.body.weight(.medium))
                                Text(exercise.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    NavigationLink {
                        ExerciseLibraryView(initialFilter: .quiet)
                    } label: {
                        Label("All quiet exercises", systemImage: "books.vertical")
                    }
                } header: {
                    Text("Quiet exercises")
                } footer: {
                    Text("Whisper resonance, silent larynx awareness and very soft humming keep training going without anyone noticing.")
                }
            }
        }
        .navigationTitle("Discreet Mode")
        .tracksHeadphones($headphonesConnected)
    }
}

private struct DiscreetRule: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}
