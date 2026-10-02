import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Live practice: current pitch, % of time in the target zone, the scrolling
/// pitch graph, live transcript, and the resonance, weight and intonation
/// meters. Sessions are saved automatically; "Finish" ends one and asks for
/// the post-session check-in.
struct PracticeView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @ScaledMetric(relativeTo: .body) private var graphHeight: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingCalibration = false
    @State private var isShowingFeedbackSettings = false
    @State private var isShowingEyesFree = false
    @State private var isConfirmingDiscard = false
    @State private var isRestBannerDismissed = false

    /// Whether to show slip alerts on screen right now.
    private var visibleSlips: Set<SlipChannel> {
        monitor.feedbackSettings.visualAlerts ? monitor.activeSlips : []
    }

    private var showsTranscript: Bool {
        switch monitor.transcription.status {
        case .off: false
        case .waitingForAudio, .listening, .unavailable: true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let storageWarning = sessionController.storageWarning {
                        NoticeBanner(title: "History unavailable", message: storageWarning, systemImage: "externaldrive.badge.exclamationmark")
                    }

                    if sessionController.isRestDaySuggested, !isRestBannerDismissed {
                        RestDayBanner {
                            isRestBannerDismissed = true
                        }
                    }

                    if let reminder = sessionController.checkInReminder {
                        CheckInReminderCard(
                            onCheckIn: { sessionController.showCheckIn(for: reminder) },
                            onDismiss: { sessionController.dismissCheckInReminder() }
                        )
                    }

                    if let warning = monitor.route?.warningMessage {
                        NoticeBanner(
                            title: "Microphone quality",
                            message: warning,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }

                    switch monitor.status {
                    case .permissionDenied:
                        MicrophoneAccessCard()
                    case .failed(let message):
                        NoticeBanner(title: "Microphone problem", message: message, systemImage: "mic.slash.fill")
                    default:
                        EmptyView()
                    }

                    if let notice = monitor.notice {
                        NoticeBanner(title: "Listening paused", message: notice, systemImage: "pause.circle.fill")
                    }

                    if let warning = monitor.strainWarning {
                        StrainWarningBanner(warning: warning)
                    }

                    if !visibleSlips.isEmpty {
                        SlipAlertBanner(channels: visibleSlips)
                            .transition(reduceMotion ? .identity : .opacity)
                    }

                    if monitor.calibration == nil {
                        CalibrationPromptCard {
                            isShowingCalibration = true
                        }
                    }

                    LiveReadoutPanel()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Pitch")
                                .font(.headline)
                            Spacer()
                            Text("Last 10 seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        LivePitchGraph()
                            .frame(height: graphHeight)
                    }
                    .cardStyle()
                    .slipHighlight(visibleSlips.contains(.pitch))

                    if showsTranscript {
                        LiveTranscriptCard()
                    }

                    VoiceMetersCard()
                        .slipHighlight(visibleSlips.contains(.resonance))

                    VoiceQualityCard()

                    SessionStatsRow()

                    Text("Practice should never hurt. If you feel pain, tightness, or hoarseness, stop and rest your voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visibleSlips)
            }
            .background { AppBackground() }
            // Start/pause, save and finish stay reachable without scrolling.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let toast = sessionController.toast {
                        ToastView(toast: toast) {
                            sessionController.dismissToast()
                        }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    PracticeControls()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: sessionController.toast)
            }
            .navigationTitle("Practice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Eyes-Free Practice", systemImage: "eye.slash") {
                        isShowingEyesFree = true
                    }
                    .disabled(monitor.status == .permissionDenied)
                    .accessibilityHint("Practice without looking: alerts come as gentle vibrations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ListeningIndicator()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Alerts & Feedback", systemImage: "bell.badge") {
                            isShowingFeedbackSettings = true
                        }
                        Button("Eyes-Free Practice", systemImage: "eye.slash") {
                            isShowingEyesFree = true
                        }
                        Button("Calibrate Microphone", systemImage: "mic.and.signal.meter") {
                            isShowingCalibration = true
                        }
                        Button(
                            monitor.transcription.isEnabled ? "Hide Live Transcript" : "Show Live Transcript",
                            systemImage: "captions.bubble"
                        ) {
                            let isEnabled = monitor.transcription.isEnabled
                            Task { await monitor.setTranscriptionEnabled(!isEnabled) }
                        }
                        Divider()
                        Button("Finish Session", systemImage: "checkmark.circle") {
                            Task { await sessionController.finishSession() }
                        }
                        .disabled(!sessionController.hasSessionInProgress)
                        Button("Discard Session", systemImage: "trash", role: .destructive) {
                            isConfirmingDiscard = true
                        }
                        .disabled(!sessionController.hasSessionInProgress)
                    } label: {
                        Label("Practice options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingCalibration) {
                MicCalibrationView(monitor: monitor)
            }
            .sheet(isPresented: $isShowingFeedbackSettings) {
                FeedbackSettingsView()
            }
            .fullScreenCover(isPresented: $isShowingEyesFree) {
                EyesFreePracticeView()
            }
            .confirmationDialog(
                "Discard this session?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Session", role: .destructive) {
                    Task { await sessionController.discardSession() }
                }
            } message: {
                Text("Its statistics and any recordings saved during it will be deleted.")
            }
        }
    }
}

/// Invites the user to calibrate before their first session.
private struct CalibrationPromptCard: View {
    let onCalibrate: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.and.signal.meter")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrate your microphone")
                    .font(.headline)
                Text("15 seconds for more accurate meters in your room.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Calibrate", action: onCalibrate)
                .buttonStyle(.glass)
        }
        .cardStyle()
    }
}

/// Small status label in the navigation bar (icon + text, never color alone).
private struct ListeningIndicator: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        switch monitor.status {
        case .running:
            Label("Listening", systemImage: "mic.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.targetZone)
        case .starting:
            ProgressView()
                .accessibilityLabel("Starting microphone")
        case .paused:
            Label("Paused", systemImage: "pause.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        case .idle, .permissionDenied, .failed:
            EmptyView()
        }
    }
}

/// The two big glanceable numbers: current pitch and % in target.
private struct LiveReadoutPanel: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    private var units: DisplayUnits { profiles.first?.displayUnits ?? .both }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 54

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            pitchCard
            targetCard
        }
    }

    private var pitchCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pitch", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(units == .noteNames ? noteOnlyText : pitchText)
                    .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if units != .noteNames {
                    Text("Hz")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(units == .both ? noteText : promptText)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .opacity(monitor.readoutIsLive || monitor.readoutFrequency == nil ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current pitch")
        .accessibilityValue(pitchAccessibilityValue)
    }

    private var targetCard: some View {
        InTargetCard()
    }

    private var pitchText: String {
        guard let frequency = monitor.readoutFrequency else { return "—" }
        return "\(Int(frequency.rounded()))"
    }

    /// The note name as the big number ("Note names" display setting).
    private var noteOnlyText: String {
        guard let frequency = monitor.readoutFrequency else { return "—" }
        return PitchMath.noteName(for: frequency) ?? "—"
    }

    /// Below the big number when it alone shows the pitch.
    private var promptText: String {
        monitor.status.isRunning && monitor.readoutFrequency == nil ? monitor.resonanceMode.prompt : " "
    }

    private var noteText: String {
        guard let frequency = monitor.readoutFrequency,
              let note = PitchMath.noteName(for: frequency)
        else {
            return monitor.status.isRunning ? monitor.resonanceMode.prompt : " "
        }
        return note
    }

    private var pitchAccessibilityValue: String {
        guard let frequency = monitor.readoutFrequency else { return "No voice detected" }
        let note = PitchMath.spokenNoteName(for: frequency).map { ", note \($0)" } ?? ""
        return "\(Int(frequency.rounded())) hertz\(note)"
    }
}

/// Session summary: pitch average, range and voiced time, plus the
/// average resonance, weight and intonation scores.
private struct SessionStatsRow: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        let stats = monitor.stats
        VStack(alignment: .leading, spacing: 12) {
            Text("This session")
                .font(.headline)
            HStack(spacing: 12) {
                StatTile(
                    title: "Average",
                    value: stats.pitch.averageFrequency.map { "\(Int($0.rounded())) Hz" } ?? "—",
                    accessibilityValue: stats.pitch.averageFrequency.map { "\(Int($0.rounded())) hertz" } ?? "None yet"
                )
                StatTile(
                    title: "Range",
                    value: rangeText(stats.pitch),
                    accessibilityValue: rangeAccessibilityText(stats.pitch)
                )
                StatTile(
                    title: "Voiced time",
                    value: durationText(stats.pitch),
                    accessibilityValue: durationText(stats.pitch)
                )
            }
            HStack(spacing: 12) {
                StatTile(title: "Resonance", value: scoreText(stats.resonance), accessibilityValue: scoreSpoken(stats.resonance))
                StatTile(title: "Weight", value: scoreText(stats.weight), accessibilityValue: scoreSpoken(stats.weight))
                StatTile(title: "Intonation", value: scoreText(stats.intonation), accessibilityValue: scoreSpoken(stats.intonation))
            }
        }
        .cardStyle()
    }

    private func scoreText(_ average: ScoreAverage) -> String {
        average.mean.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private func scoreSpoken(_ average: ScoreAverage) -> String {
        average.mean.map { "average \(Int($0.rounded())) out of 100" } ?? "None yet"
    }

    private func rangeText(_ stats: PitchSessionStats) -> String {
        guard let low = stats.minimumFrequency, let high = stats.maximumFrequency else { return "—" }
        return "\(Int(low.rounded()))–\(Int(high.rounded()))"
    }

    private func rangeAccessibilityText(_ stats: PitchSessionStats) -> String {
        guard let low = stats.minimumFrequency, let high = stats.maximumFrequency else { return "None yet" }
        return "\(Int(low.rounded())) to \(Int(high.rounded())) hertz"
    }

    private func durationText(_ stats: PitchSessionStats) -> String {
        let interval = monitor.analysisConfiguration?.hopDuration ?? AnalysisConfiguration().hopDuration
        let seconds = Int(stats.voicedDuration(frameInterval: interval).rounded())
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// Start / pause / resume, "save this as a recording" and finish.
private struct PracticeControls: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(\.openURL) private var openURL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryButton
                secondaryButtons
            }
            VStack(spacing: 10) {
                primaryButton
                HStack(spacing: 10) {
                    secondaryButtons
                }
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if monitor.status != .permissionDenied {
            Button {
                Task { await sessionController.saveRecentClip() }
            } label: {
                if sessionController.isSavingClip {
                    ProgressView()
                } else {
                    Label("Save Clip", systemImage: "record.circle")
                }
            }
            .buttonStyle(.glass)
            .disabled(!sessionController.hasSessionInProgress || sessionController.isSavingClip)
            .accessibilityLabel("Save the last 30 seconds as a recording")

            Button {
                Task { await sessionController.finishSession() }
            } label: {
                Label("Finish", systemImage: "checkmark.circle")
            }
            .buttonStyle(.glass)
            .disabled(!sessionController.hasSessionInProgress)
            .accessibilityHint("Saves this session and asks how your voice felt")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch monitor.status {
        case .idle:
            Button {
                Task { await monitor.start() }
            } label: {
                Label("Start Listening", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        case .starting:
            ProgressView("Starting microphone…")
                .frame(maxWidth: .infinity)
        case .running:
            Button {
                Task { await monitor.pause() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        case .paused, .failed:
            Button {
                Task { await monitor.start() }
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        case .permissionDenied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
    }
}

/// Shown when microphone access was declined.
private struct MicrophoneAccessCard: View {
    var body: some View {
        NoticeBanner(
            title: "Microphone access is off",
            message: "VoiceBloom needs the microphone to hear your voice. Your voice is analyzed on this iPhone and never leaves it. Turn on Microphone for VoiceBloom in Settings.",
            systemImage: "mic.slash.fill"
        )
    }
}
