import Foundation
import SwiftUI

/// Suggests a day off after repeated "Sore" check-ins.
struct RestDayBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticeBanner(
                title: "Rest day suggested",
                message: "Your recent check-ins said your throat felt sore. Give your voice a day off from training. If the soreness continues, see a doctor or speech-language pathologist.",
                systemImage: "bed.double.fill"
            )
            Button("Got It", action: onDismiss)
                .buttonStyle(.glass)
        }
    }
}

/// Asks about an earlier session that ended without a check-in.
struct CheckInReminderCard: View {
    let onCheckIn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.text.square")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How did your last session feel?")
                        .font(.headline)
                    Text("A 5-second check-in on your throat helps you train safely.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button("Check In", action: onCheckIn)
                    .buttonStyle(.glassProminent)
                Button("Not Now", action: onDismiss)
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// A short confirmation or error above the practice controls.
struct ToastView: View {
    let toast: SessionToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Theme.warning : Theme.targetZone)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
        .accessibilityElement(children: .combine)
        .task(id: toast.id) {
            // VoiceOver users hear the message without having to find it.
            AccessibilityNotification.Announcement(toast.message).post()
        }
    }
}

/// Live, on-device transcript of what the user is saying.
struct LiveTranscriptCard: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 140

    var body: some View {
        let transcription = monitor.transcription
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Transcript", systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                if transcription.status == .listening {
                    Text("Listening")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await monitor.setTranscriptionEnabled(false) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Turn off live transcript")
            }

            switch transcription.status {
            case .unavailable(let reason):
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .off, .waitingForAudio, .listening:
                if transcription.text.isEmpty {
                    Text(transcription.status == .listening
                         ? "Start speaking. Your words will appear here."
                         : "Start listening to see your words here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(transcription.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: maximumHeight)
                    .defaultScrollAnchor(.bottom)
                    .accessibilityLabel("Transcript")
                }
            }

            Label("Transcribed on this iPhone. Audio never leaves your device.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
