import Foundation
import SwiftData
import SwiftUI

/// Quick Check (SPEC section 8): a 10-second reading that gives today's
/// pitch, resonance and weight snapshot, compared with the last check.
struct QuickCheckView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        QuickCheckContent(monitor: monitor)
    }
}

private struct QuickCheckContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(
        filter: #Predicate<PracticeSession> { $0.kindRawValue == "quickCheck" },
        sort: \PracticeSession.startDate,
        order: .reverse
    ) private var checks: [PracticeSession]

    @State private var recorder: VoiceTakeRecorder
    @State private var comparison: QuickCheckComparison?
    @State private var savedRecording: Recording?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(monitor: LiveVoiceMonitor) {
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var profile: UserProfile? { profiles.first }
    private var target: PitchTargetZone { profile?.targetZone ?? recorder.monitor.targetZone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Read the sentence below in your practice voice. Ten seconds is enough for a snapshot of today.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ReadingPassages.quickCheck)
                    .font(.title2.weight(.medium))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                controls

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let comparison, recorder.phase == .finished {
                    resultCard(comparison)
                }

                if !checks.isEmpty {
                    recentChecks
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Quick Check")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recorder.phase) { _, phase in
            if phase == .finished {
                Task { await saveTake() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .onDisappear {
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .idle, .failed:
            Button {
                Task { await start() }
            } label: {
                Label(checks.isEmpty ? "Start Quick Check" : "Start Today’s Check", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        case .starting, .recording:
            TakeProgressView(recorder: recorder)
        case .finished:
            if isSaving {
                ProgressView("Saving…")
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    if let savedRecording {
                        let isPlaying = sessionController.player.playingID == savedRecording.id
                        Button {
                            Task { await sessionController.togglePlayback(of: savedRecording) }
                        } label: {
                            Label(isPlaying ? "Stop" : "Listen", systemImage: isPlaying ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    Button {
                        recorder.reset()
                        comparison = nil
                        savedRecording = nil
                    } label: {
                        Label("Check Again", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
    }

    private func resultCard(_ comparison: QuickCheckComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if comparison.changes.isEmpty {
                Label("No voice was detected. Try again a little closer to the phone.", systemImage: "mic.slash")
                    .foregroundStyle(.secondary)
            } else {
                Text(comparison.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(comparison.changes) { change in
                    QuickCheckChangeRow(change: change)
                    if change.id != comparison.changes.last?.id {
                        Divider()
                    }
                }
                Text("Target \(target.formatted). Scores are 0–100; one check is a snapshot, so look at the trend in Progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var recentChecks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent checks")
                .font(.headline)
            ForEach(checks.prefix(7)) { check in
                HStack {
                    Text(check.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                    Spacer()
                    Text(check.averagePitch.map(SessionFormat.hertz) ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("Res \(SessionFormat.score(check.resonanceScore))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Actions

    private func start() async {
        errorMessage = nil
        comparison = nil
        savedRecording = nil
        await recorder.start(
            duration: QuickCheckStore.duration,
            target: target,
            resonanceMode: .speech,
            references: profile?.personalReferences ?? .none
        )
    }

    private func saveTake() async {
        guard let result = recorder.result else { return }
        let store = QuickCheckStore(context: modelContext)
        // Compare with the check before this one.
        let previous = store.latestValues()
        comparison = QuickCheckComparison(current: result, previous: previous, target: target)
        guard result.hasVoice else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let session = try await store.save(take: result, audio: recorder.audio, target: target)
            savedRecording = session.recordings?.first
        } catch {
            errorMessage = "This check couldn’t be saved. Please try again."
        }
    }
}

/// One measure: today's value and the change since the last check.
private struct QuickCheckChangeRow: View {
    let change: QuickCheckComparison.Change

    var body: some View {
        HStack(spacing: 12) {
            Text(change.metric.title)
                .font(.subheadline)
            Spacer()
            Text(change.metric.formatted(change.value))
                .font(.headline)
                .monospacedDigit()
            if let difference = change.difference {
                Label(change.metric.formattedChange(difference), systemImage: symbol(for: difference))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .frame(minWidth: 80, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change.metric.title)
        .accessibilityValue(spokenValue)
    }

    private func symbol(for difference: Double) -> String {
        if abs(difference) < change.metric.threshold { return "equal" }
        return difference > 0 ? "arrow.up" : "arrow.down"
    }

    private var color: Color {
        switch change.isBetter {
        case .some(true): Theme.targetZone
        case .some(false): Theme.warning
        case .none: Color.secondary
        }
    }

    private var spokenValue: String {
        var text = change.metric.formatted(change.value)
        if let difference = change.difference {
            text += ", \(change.metric.formattedChange(difference)) since last time"
            switch change.isBetter {
            case .some(true): text += ", better"
            case .some(false): text += ", lower"
            case .none: text += ", about the same"
            }
        }
        return text
    }
}
