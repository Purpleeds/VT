import Foundation
import SwiftUI

/// Mic Check in a sheet (from the Practice screen).
struct MicCheckSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MicCheckView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// "It's noisy here": at most once per session (SPEC section 24.6).
struct NoiseSuggestionBanner: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    let suggestion: NoiseSuggestion
    let onOpenMicCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "ear.trianglebadge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.headline)
                    Text(suggestion.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    buttons
                }
                VStack(alignment: .leading, spacing: 10) {
                    buttons
                }
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

    @ViewBuilder
    private var buttons: some View {
        if let title = suggestion.actionTitle, let strength = suggestion.suggestedStrength {
            Button(title) {
                Task {
                    await monitor.setClearMicStrength(strength)
                    monitor.dismissNoiseSuggestion()
                }
            }
            .buttonStyle(.glassProminent)
        }
        Button("Mic Check", action: onOpenMicCheck)
            .buttonStyle(.glass)
        Button("Dismiss") {
            monitor.dismissNoiseSuggestion()
        }
        .buttonStyle(.glass)
    }
}

/// Input level from −60 to 0 dBFS with the recent peak as a tick.
struct MicLevelBar: View {
    let levelDb: Double
    let peakDb: Double
    let isActive: Bool

    static let range = -60.0...0.0

    var body: some View {
        let level = Self.fraction(levelDb)
        let peak = Self.fraction(peakDb)
        let isClipping = peakDb >= MicCalibrationAnalysis.clippingPeakDb
        let fillColor = isClipping ? Theme.warning : Theme.pitchLine
        let active = isActive
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(.secondary.opacity(0.2)))
            guard active else { return }
            let filled = CGRect(x: 0, y: 0, width: max(size.height, size.width * level), height: size.height)
            if level > 0 {
                context.fill(
                    Path(roundedRect: filled, cornerRadius: size.height / 2),
                    with: .color(fillColor)
                )
            }
            if peak > 0 {
                var tick = Path()
                let x = min(size.width - 1, max(1, size.width * peak))
                tick.move(to: CGPoint(x: x, y: 0))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(.primary), lineWidth: 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard isActive else { return "Not listening" }
        let clipping = peakDb >= MicCalibrationAnalysis.clippingPeakDb ? ", clipping" : ""
        return "\(levelDb.roundedInt) decibels, peak \(peakDb.roundedInt)\(clipping)"
    }

    static func fraction(_ decibels: Double) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// Play with Clear Mic, and share the original or a Clear Mic copy, for a
/// saved recording (SPEC section 24.7). The saved file is never changed.
struct RecordingClearMicMenu: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(LiveVoiceMonitor.self) private var monitor
    let recording: Recording

    var body: some View {
        let isEnhancedPlaying = sessionController.player.playingID == recording.id && sessionController.player.isPlayingEnhanced
        let isPreparing = sessionController.preparingEnhancedID == recording.id
        Menu {
            Button(
                isEnhancedPlaying ? "Stop" : "Play with Clear Mic",
                systemImage: isEnhancedPlaying ? "stop.fill" : "mic.and.signal.meter"
            ) {
                Task { await sessionController.togglePlayback(of: recording, enhanced: true) }
            }
            .disabled(isPreparing)
            if let url = recording.fileURL {
                Divider()
                ShareLink(
                    item: url,
                    preview: SharePreview("Recording", image: Image(systemName: "waveform"))
                ) {
                    Label("Share Original", systemImage: "square.and.arrow.up")
                }
                ShareLink(
                    item: EnhancedRecordingFile(source: url, id: recording.id, strength: monitor.clearMicSettings.effectiveStrength),
                    preview: SharePreview("Recording with Clear Mic", image: Image(systemName: "waveform"))
                ) {
                    Label("Share with Clear Mic", systemImage: "square.and.arrow.up.on.square")
                }
            }
        } label: {
            if isPreparing {
                ProgressView()
                    .accessibilityLabel("Preparing the Clear Mic version")
            } else {
                Image(systemName: isEnhancedPlaying ? "mic.and.signal.meter.fill" : "ellipsis.circle")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .accessibilityLabel("More for this recording")
        .accessibilityHint("Play it with Clear Mic or share it")
    }
}
