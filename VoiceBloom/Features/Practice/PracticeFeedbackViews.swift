import Foundation
import SwiftUI

// MARK: - % in target

/// The big "% in target" display: a ring for the whole session plus the
/// last 10 seconds and the share of bright resonance.
struct InTargetCard: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 116
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 34

    var body: some View {
        let percent = monitor.stats.pitch.percentInTarget
        VStack(spacing: 8) {
            Label("In target", systemImage: "target")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: (percent ?? 0) / 100)
                    .stroke(Theme.targetZone, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: percent)
                VStack(spacing: 0) {
                    Text(percent.map { "\($0.roundedInt)%" } ?? "—")
                        .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 2) {
                Text("Last 10 s: \(monitor.recentInTargetPercent.map { "\($0.roundedInt)%" } ?? "—")")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if let bright = monitor.stats.brightResonance.percent {
                    Text("Bright resonance: \(bright.roundedInt)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(monitor.targetZone.formatted)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.targetZone)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in target zone")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let zone = "Target zone \(monitor.targetZone.spokenDescription)."
        guard let percent = monitor.stats.pitch.percentInTarget else { return "No voiced time yet. \(zone)" }
        var parts = ["\(percent.roundedInt) percent of voiced time this session."]
        if let recent = monitor.recentInTargetPercent {
            parts.append("\(recent.roundedInt) percent in the last 10 seconds.")
        }
        if let bright = monitor.stats.brightResonance.percent {
            parts.append("Resonance bright \(bright.roundedInt) percent of the time.")
        }
        parts.append(zone)
        return parts.joined(separator: " ")
    }
}

// MARK: - Slip alerts

/// Subtle on-screen slip alert (icon + words, never color alone).
struct SlipAlertBanner: View {
    let channels: Set<SlipChannel>

    var body: some View {
        NoticeBanner(title: title, message: message, systemImage: "arrow.down.right.circle.fill")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var title: String {
        if channels.count > 1 { return "Pitch and resonance are slipping" }
        return channels.contains(.pitch) ? "Pitch is drifting down" : "Resonance is getting darker"
    }

    private var message: String {
        if channels.count > 1 {
            return "Ease back up into your target and keep the sound bright and forward."
        }
        if channels.contains(.pitch) {
            return "Lift gently back into your target zone. No pushing or squeezing."
        }
        return "Brighten the sound: a slight smile, tongue forward, the “small dog” feeling."
    }
}

extension View {
    /// A soft warm outline around a card while its measure is slipping.
    func slipHighlight(_ isSlipping: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.warning.opacity(isSlipping ? 0.8 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Strain

/// "Your voice sounds tired. Take a break." with a clear non-diagnosis note.
struct StrainWarningBanner: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    let warning: StrainWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your voice sounds tired. Take a break.")
                        .font(.headline)
                    Text("For a while now your voice has sounded rougher than usual (about \(percentAbove)% above your normal). Rest for a few minutes, sip some water, and stop if anything hurts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A rough indicator from your phone’s microphone, not a medical diagnosis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button {
                    Task {
                        await monitor.pause()
                        monitor.dismissStrainWarning()
                    }
                } label: {
                    Label("Take a Break", systemImage: "pause.fill")
                }
                .buttonStyle(.glassProminent)
                Button("Dismiss") {
                    monitor.dismissStrainWarning()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(16)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var percentAbove: Int {
        max(0, ((warning.roughnessRatio - 1) * 100).roundedInt)
    }
}

// MARK: - Voice quality

/// Jitter, shimmer and HNR, and how today compares with the user's normal.
struct VoiceQualityCard: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        let status = monitor.voiceQuality
        let summary = status?.assessment?.recent ?? status?.session
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Voice comfort", systemImage: "heart.text.square")
                    .font(.headline)
                Spacer()
                Text(statusText(status))
                    .font(.subheadline)
                    .foregroundStyle(statusIsElevated(status) ? Theme.warning : .secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack(spacing: 12) {
                StatTile(
                    title: "Jitter",
                    value: percentText(summary?.jitterPercent),
                    accessibilityValue: spokenPercent(summary?.jitterPercent)
                )
                StatTile(
                    title: "Shimmer",
                    value: percentText(summary?.shimmerPercent),
                    accessibilityValue: spokenPercent(summary?.shimmerPercent)
                )
                StatTile(
                    title: "HNR",
                    value: summary?.harmonicsToNoiseDb.map { "\($0.roundedInt) dB" } ?? "—",
                    accessibilityValue: summary?.harmonicsToNoiseDb.map { "\($0.roundedInt) decibels" } ?? "None yet"
                )
            }
            Text("Rough indicators from your phone’s mic, compared with your own usual voice. Not a medical diagnosis. See a doctor or speech-language pathologist about pain or hoarseness that lasts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func statusText(_ status: VoiceQualityStatus?) -> String {
        guard let status else { return "Speak or hold a vowel" }
        if let assessment = status.assessment {
            let change = ((assessment.roughnessRatio - 1) * 100).roundedInt
            if assessment.isElevated {
                return "Rougher than usual (+\(change)%)"
            }
            return change > 10 ? "A little rougher (+\(change)%)" : "Steady"
        }
        return status.isLearning ? "Learning your usual voice…" : "Keep practicing…"
    }

    private func statusIsElevated(_ status: VoiceQualityStatus?) -> Bool {
        status?.assessment?.isElevated ?? false
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private func spokenPercent(_ value: Double?) -> String {
        guard let value else { return "None yet" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) percent"
    }
}
