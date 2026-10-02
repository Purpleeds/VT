import Foundation
import SwiftUI

/// Plays the baseline ("Then") and the newest recording ("Now") back to back,
/// with their stats side by side.
struct ThenVsNowCard: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(RecordingPlayer.self) private var player
    let then: Recording
    let now: Recording

    var body: some View {
        ChartCard(title: "Then vs Now", subtitle: "Your \(then.kind == .baseline ? "baseline" : "first") recording next to your latest.") {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    column(title: "Then", recording: then)
                    Divider()
                    column(title: "Now", recording: now)
                }

                Button {
                    if player.playingID == then.id || player.playingID == now.id {
                        player.stop()
                    } else {
                        Task { await sessionController.playInSequence([then, now]) }
                    }
                } label: {
                    Label(isPlayingEither ? "Stop" : "Play Then, then Now", systemImage: isPlayingEither ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityHint("Plays both recordings one after the other")
            }
        }
    }

    private var isPlayingEither: Bool {
        player.playingID == then.id || player.playingID == now.id
    }

    @ViewBuilder
    private func column(title: String, recording: Recording) -> some View {
        let isPlaying = player.playingID == recording.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await sessionController.togglePlayback(of: recording) }
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPlaying ? "Stop \(title)" : "Play \(title)")
            }
            Text(recording.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isPlaying {
                ProgressView(value: player.progress)
                    .accessibilityLabel("Playback progress")
            }
            stat("Pitch", recording.averagePitch.map(SessionFormat.hertz))
            stat("In target", recording.percentInTarget.map(SessionFormat.percent))
            stat("Resonance", recording.resonanceScore.map { SessionFormat.score($0) })
            stat("Weight", recording.weightScore.map { SessionFormat.score($0) })
            stat("Intonation", recording.intonationScore.map { SessionFormat.score($0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        LabeledContent(label, value: value ?? "—")
            .font(.subheadline)
    }
}

/// Shown instead of Then vs Now until there are two recordings.
struct ThenVsNowPlaceholder: View {
    var body: some View {
        ChartCard(title: "Then vs Now") {
            Text("Save your baseline recording during setup, or tap “Save Clip” while practicing. Once you have two recordings you can play your first and latest back to back here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
