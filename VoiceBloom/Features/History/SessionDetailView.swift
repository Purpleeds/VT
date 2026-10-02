import Foundation
import SwiftData
import SwiftUI

/// One saved session: its statistics, check-in and recordings.
struct SessionDetailView: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(RecordingPlayer.self) private var player
    let session: PracticeSession
    @State private var checkInRequest: CheckInRequest?

    private var recordings: [Recording] {
        (session.recordings ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            if let message = player.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            }

            Section("Session") {
                LabeledContent("Type", value: session.kind.title)
                LabeledContent("Practice time", value: SessionFormat.duration(session.duration))
                LabeledContent("Time speaking", value: SessionFormat.duration(session.voicedDuration))
                if let endDate = session.endDate {
                    LabeledContent("Finished") {
                        Text(endDate, format: .dateTime.hour().minute())
                    }
                } else {
                    LabeledContent("Status", value: "In progress")
                }
            }

            Section {
                LabeledContent("Average", value: session.averagePitch.map(SessionFormat.hertz) ?? "—")
                LabeledContent("Range", value: SessionFormat.range(low: session.minimumPitch, high: session.maximumPitch))
                LabeledContent("Time in target", value: session.percentInTarget.map(SessionFormat.percent) ?? "—")
                LabeledContent("Target zone", value: session.targetZone.formatted)
            } header: {
                Text("Pitch")
            }

            Section {
                LabeledContent("Resonance", value: SessionFormat.score(session.resonanceScore))
                if let bright = session.brightResonancePercent {
                    LabeledContent("Bright resonance", value: SessionFormat.percent(bright))
                }
                LabeledContent("Vocal weight", value: SessionFormat.score(session.weightScore))
                LabeledContent("Intonation", value: SessionFormat.score(session.intonationScore))
            } header: {
                Text("Scores (0–100)")
            } footer: {
                Text("Averages for the session. Higher means closer to your target: brighter resonance, lighter weight, more melody.")
            }

            Section {
                LabeledContent("Jitter", value: SessionFormat.precisePercent(session.jitterPercent))
                LabeledContent("Shimmer", value: SessionFormat.precisePercent(session.shimmerPercent))
                LabeledContent("Harmonics-to-noise", value: SessionFormat.decibels(session.harmonicsToNoiseDb))
                LabeledContent("Slip alerts", value: "\(session.slipAlertCount)")
                LabeledContent("“Voice sounds tired” warnings", value: "\(session.strainWarningCount)")
            } header: {
                Text("Voice quality")
            } footer: {
                Text("Rough indicators from your phone’s microphone, not a medical diagnosis.")
            }

            Section("Check-in") {
                if let comfort = session.comfort {
                    LabeledContent("Throat") {
                        Label(comfort.title, systemImage: comfort.systemImage)
                    }
                    LabeledContent("Naturalness", value: session.naturalnessRating.map { "\($0) of 5" } ?? "—")
                    Button("Edit Check-In") {
                        checkInRequest = CheckInRequest(id: session.id)
                    }
                } else {
                    Text("No check-in for this session.")
                        .foregroundStyle(.secondary)
                    if session.isFinished {
                        Button("Add Check-In") {
                            checkInRequest = CheckInRequest(id: session.id)
                        }
                    }
                }
            }

            Section {
                if recordings.isEmpty {
                    Text("Tap “Save Clip” while practicing to keep the last 30 seconds.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordings) { recording in
                        RecordingRow(recording: recording)
                    }
                    .onDelete(perform: deleteRecordings)
                }
            } header: {
                Text("Recordings")
            } footer: {
                if !recordings.isEmpty {
                    Text("Recordings stay on this iPhone. Swipe left to delete one.")
                }
            }
        }
        .navigationTitle(Text(session.startDate, format: .dateTime.month(.abbreviated).day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $checkInRequest) { request in
            CheckInSheet(request: request)
        }
        .onDisappear {
            player.stop()
        }
    }

    private func deleteRecordings(at offsets: IndexSet) {
        let current = recordings
        let doomed = offsets.map { current[$0] }
        for recording in doomed {
            sessionController.delete(recording)
        }
    }
}

/// A saved clip with play/stop, its stats and transcript.
private struct RecordingRow: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(RecordingPlayer.self) private var player
    let recording: Recording

    var body: some View {
        let isPlaying = player.playingID == recording.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    Task { await sessionController.togglePlayback(of: recording) }
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPlaying ? "Stop" : "Play recording")

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(recording.createdAt.formatted(date: .omitted, time: .shortened)) · \(SessionFormat.duration(recording.duration))")
                        .font(.headline)
                    Text(statsLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if isPlaying {
                ProgressView(value: player.progress)
                    .accessibilityLabel("Playback progress")
            }

            if let transcript = recording.transcript, !transcript.isEmpty {
                Text("“\(transcript)”")
                    .font(.callout)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let pitch = recording.averagePitch {
            parts.append(SessionFormat.hertz(pitch))
        }
        if let percent = recording.percentInTarget {
            parts.append("\(SessionFormat.percent(percent)) in target")
        }
        if let resonance = recording.resonanceScore {
            parts.append("resonance \(SessionFormat.score(resonance))")
        }
        if let weight = recording.weightScore {
            parts.append("weight \(SessionFormat.score(weight))")
        }
        if let intonation = recording.intonationScore {
            parts.append("intonation \(SessionFormat.score(intonation))")
        }
        return parts.isEmpty ? "No voice detected" : parts.joined(separator: " · ")
    }
}
