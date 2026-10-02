import Foundation
import SwiftData
import SwiftUI

/// One saved target voice: its profile, using it for targets, Compare to
/// Target and shadowing (SPEC section 9).
struct TargetProfileDetailView: View {
    let target: TargetVoiceProfile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    @State private var isShowingSuggestion = false
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var user: UserProfile? { profiles.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    TargetStatsGrid(snapshot: target.snapshot, low: target.minimumPitch, high: target.maximumPitch, tilt: target.spectralTilt)
                    PitchHistogramChart(series: [
                        HistogramSeries(name: target.name, histogram: target.pitchHistogram, color: Theme.resonanceSeries),
                    ])
                    .frame(height: 160)
                }
                .cardStyle()

                actions

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                }

                TargetGuideNote()
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = target.name
                        isRenaming = true
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingSuggestion) {
            if let user {
                TargetSuggestionSheet(target: target, user: user) {
                    apply(to: user)
                }
            }
        }
        .alert("Rename target voice", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                try? TargetVoiceStore(context: modelContext).rename(target, to: newName)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(target.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                delete()
            }
        } message: {
            Text("The profile and its clip are removed from this iPhone. Your current targets stay as they are.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if target.isActive {
                Label("Your active target voice", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.targetZone)
            }
            Text("Saved \(target.createdAt.formatted(date: .long, time: .omitted))\(clipLengthText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let url = target.clipFileURL {
                let isPlaying = sessionController.player.playingID == target.id
                Button {
                    Task { await sessionController.togglePlayback(url: url, id: target.id) }
                } label: {
                    Label(isPlaying ? "Stop" : "Listen to the clip", systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var clipLengthText: String {
        guard let start = target.clipStart, let end = target.clipEnd, end > start else { return "" }
        return " · \((end - start).roundedInt) s clip"
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                isShowingSuggestion = true
            } label: {
                Label(target.isActive ? "Set my targets from this voice again" : "Use as my target voice", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(user == nil || target.suggestion.isEmpty)

            NavigationLink {
                TargetCompareView(target: target)
            } label: {
                Label("Compare to Target", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            NavigationLink {
                ShadowingView(target: target)
            } label: {
                Label("Shadowing Practice", systemImage: "repeat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(target.clipFileURL == nil)

            if target.isActive, let user {
                Button("Stop Using as My Target Voice") {
                    do {
                        try TargetVoiceStore(context: modelContext).deactivate(for: user)
                    } catch {
                        errorMessage = "That didn’t work. Please try again."
                    }
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
        }
        .controlSize(.large)
    }

    private func apply(to user: UserProfile) {
        do {
            try TargetVoiceStore(context: modelContext).activate(target, for: user, applyTargets: true)
            monitor.targetZone = user.targetZone
            monitor.applyReferences(user.personalReferences)
        } catch {
            errorMessage = "Your targets couldn’t be updated. Please try again."
        }
    }

    private func delete() {
        if sessionController.player.playingID == target.id {
            sessionController.player.stop()
        }
        // Leave the screen first so nothing reads the deleted profile.
        let store = TargetVoiceStore(context: modelContext)
        let doomed = target
        let owner = user
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            try? store.delete(doomed, user: owner)
        }
    }
}

/// Shows how the targets would change before applying them.
struct TargetSuggestionSheet: View {
    let target: TargetVoiceProfile
    let user: UserProfile
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var suggestion: TargetSuggestion { target.suggestion }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let zone = suggestion.pitchZone {
                        change("Pitch range", from: user.targetZone.formatted, to: zone.formatted)
                    }
                    if let f2 = suggestion.f2 {
                        change("F2 (resonance)", from: hertz(user.targetF2, default: ResonanceMode.speech.defaultReference.targetF2), to: "\(Int(f2)) Hz")
                    }
                    if let f3 = suggestion.f3 {
                        change("F3 (resonance)", from: hertz(user.targetF3, default: ResonanceMode.speech.defaultReference.targetF3), to: "\(Int(f3)) Hz")
                    }
                    if let h1MinusH2 = suggestion.h1MinusH2 {
                        change("H1–H2 (weight)", from: decibels(user.targetH1MinusH2 ?? WeightReference.standard.targetH1MinusH2), to: decibels(h1MinusH2))
                    }
                    if let deviation = suggestion.intonationSD {
                        change("Intonation", from: semitones(user.targetIntonationSD ?? IntonationReference.standard.targetStandardDeviation), to: semitones(deviation))
                    }
                } header: {
                    Text("Your targets")
                } footer: {
                    Text("The pitch range is centered on this voice’s typical pitch (±2 semitones). Values are kept within healthy, reachable ranges, and you can change any of them later in More ▸ Settings.")
                }
                Section {
                    Text("Your voice won’t sound exactly like anyone else’s, and it shouldn’t have to. Use this as a direction, and stop if anything feels strained.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Use “\(target.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }

    private func change(_ title: String, from old: String, to new: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text(old)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("to")
                Text(new)
                    .fontWeight(.semibold)
            }
            .monospacedDigit()
        }
    }

    private func hertz(_ value: Double?, default fallback: Double) -> String {
        "\((value ?? fallback).roundedInt) Hz"
    }

    private func decibels(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private func semitones(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) st"
    }
}
