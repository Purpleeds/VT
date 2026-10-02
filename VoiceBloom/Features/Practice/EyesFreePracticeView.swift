import Foundation
import SwiftUI
import UIKit

/// Practice without looking at the screen. Feedback comes as haptics (and
/// optional soft chimes). The screen stays awake, and with proximity sensing
/// it turns off when the phone is face down or in a pocket, while listening
/// continues (the app stays in the foreground, like during a call).
struct EyesFreePracticeView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var statusSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            Image(systemName: state.systemImage)
                .font(.system(size: statusSize * 1.4))
                .foregroundStyle(state.tint)
                .accessibilityHidden(true)

            Text(state.title)
                .font(.system(size: statusSize, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)

            if let percent = monitor.stats.pitch.percentInTarget {
                Text("\(Int(percent.rounded()))% in target")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Two soft taps: pitch drifting down", systemImage: "hand.tap")
                Label("Low buzz: resonance getting darker", systemImage: "waveform.path")
                Label("Light tap: back on target", systemImage: "checkmark.circle")
                Label("Put the phone face down: the screen turns off but listening continues.", systemImage: "iphone.gen3")
            }
            .font(.callout)
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal)

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Label("End Eyes-Free", systemImage: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isProximityMonitoringEnabled = true
            Task { await monitor.beginEyesFree() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIDevice.current.isProximityMonitoringEnabled = false
            monitor.endEyesFree()
        }
        .onChange(of: monitor.activeSlips) { _, slips in
            // VoiceOver users hear the change as well as feel it.
            if !slips.isEmpty {
                AccessibilityNotification.Announcement(state.title).post()
            }
        }
    }

    private var state: EyesFreeState {
        EyesFreeState(
            status: monitor.status,
            slips: monitor.activeSlips,
            pitch: monitor.readoutIsLive ? monitor.readoutFrequency : nil,
            target: monitor.targetZone
        )
    }
}

/// What the eyes-free screen says, in big words.
@MainActor
struct EyesFreeState {
    let title: String
    let systemImage: String
    let tint: Color

    init(status: MonitorStatus, slips: Set<SlipChannel>, pitch: Double?, target: PitchTargetZone) {
        if !status.isRunning {
            title = status == .starting ? "Starting…" : "Paused"
            systemImage = "pause.circle"
            tint = .white
        } else if slips.count > 1 {
            title = "Pitch and resonance slipping"
            systemImage = "arrow.down.circle.fill"
            tint = Theme.warning
        } else if slips.contains(.pitch) {
            title = "Pitch slipping"
            systemImage = "arrow.down.circle.fill"
            tint = Theme.warning
        } else if slips.contains(.resonance) {
            title = "Resonance darkening"
            systemImage = "arrow.down.circle.fill"
            tint = Theme.warning
        } else if let pitch, target.contains(pitch) {
            title = "On target"
            systemImage = "checkmark.circle.fill"
            tint = Theme.targetZone
        } else {
            title = "Listening"
            systemImage = "ear"
            tint = .white
        }
    }
}
