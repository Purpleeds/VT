import Foundation
import SwiftUI

/// Tools (SPEC sections 7 and 8): Quick Check, the Daily Sentence Journal,
/// scenarios, the exercise library, the tone generator and mini piano,
/// Voice Preview and Discreet Mode.
struct ToolsView: View {
    @AppStorage(DiscreetMode.key) private var discreetMode = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    QuickCheckView()
                } label: {
                    ToolRow(
                        title: "Quick Check",
                        detail: "A 10-second reading for today’s pitch, resonance and weight.",
                        systemImage: "stopwatch"
                    )
                }
                NavigationLink {
                    JournalView()
                } label: {
                    ToolRow(
                        title: "Daily Sentence Journal",
                        detail: "Record the same sentence every day, then scrub through to hear how you’ve grown.",
                        systemImage: "book.pages"
                    )
                }
            } header: {
                Text("Check in")
            }

            Section {
                NavigationLink {
                    ScenarioListView()
                } label: {
                    ToolRow(
                        title: "Scenarios",
                        detail: "Order coffee, make a call, give a talk: real-life practice at three levels, scored turn by turn.",
                        systemImage: "theatermasks"
                    )
                }
                NavigationLink {
                    PitchGameView()
                } label: {
                    ToolRow(
                        title: "Balloon Game",
                        detail: "Steer a balloon through gaps with your pitch. Bright resonance scores bonus stars.",
                        systemImage: "balloon"
                    )
                }
                NavigationLink {
                    PracticeTextView()
                } label: {
                    ToolRow(
                        title: "Practice Texts",
                        detail: "Fresh passages for the sounds you want to work on, then read one aloud.",
                        systemImage: "text.book.closed"
                    )
                }
                NavigationLink {
                    ExerciseLibraryView()
                } label: {
                    ToolRow(
                        title: "Exercise Library",
                        detail: "Every exercise, searchable and playable on its own.",
                        systemImage: "books.vertical"
                    )
                }
                NavigationLink {
                    ToneGeneratorView()
                } label: {
                    ToolRow(
                        title: "Tone Generator & Piano",
                        detail: "Hear any target note as a steady tone or on a mini keyboard.",
                        systemImage: "pianokeys"
                    )
                }
            } header: {
                Text("Practice")
            }

            Section {
                NavigationLink {
                    VoicePreviewView()
                } label: {
                    ToolRow(
                        title: "Voice Preview",
                        detail: "Hear a rough approximation of your recording with a higher or lower pitch and brighter or darker resonance.",
                        systemImage: "wand.and.stars"
                    )
                }
            } header: {
                Text("Explore")
            } footer: {
                Text("An approximation made with simple signal processing, not a prediction of your trained voice.")
            }

            Section {
                NavigationLink {
                    DiscreetModeView()
                } label: {
                    ToolRow(
                        title: "Discreet Mode",
                        detail: discreetMode
                            ? "On: tones and chimes through headphones only."
                            : "Quiet exercises for when others are nearby.",
                        systemImage: discreetMode ? "speaker.slash.fill" : "speaker.slash"
                    )
                }
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Tools")
    }
}

/// An icon, a title and one line about the tool.
struct ToolRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A capsule filter button.
struct FilterChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Theme.targetZone.opacity(0.22) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Theme.targetZone : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Polls whether headphones are connected while a view is on screen
/// (route changes are rare, so a slow poll is plenty).
struct HeadphoneStatusModifier: ViewModifier {
    @Binding var isConnected: Bool

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                isConnected = TonePlayer.headphonesConnected
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

extension View {
    func tracksHeadphones(_ isConnected: Binding<Bool>) -> some View {
        modifier(HeadphoneStatusModifier(isConnected: isConnected))
    }
}
