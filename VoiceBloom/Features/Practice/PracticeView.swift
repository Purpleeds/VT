/// Live practice: current pitch, % of time in the target zone, the scrolling
/// pitch graph, and the resonance, weight and intonation meters.
struct PracticeView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @ScaledMetric(relativeTo: .body) private var graphHeight: CGFloat = 220
    @State private var isShowingCalibration = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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

                    VoiceMetersCard()

                    SessionStatsRow()

                    Text("Practice should never hurt. If you feel pain, tightness, or hoarseness, stop and rest your voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background { AppBackground() }
            // Start/pause stays reachable without scrolling.
            .safeAreaInset(edge: .bottom) {
                PracticeControls()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            .navigationTitle("Practice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ListeningIndicator()
                }
            }
            .sheet(isPresented: $isShowingCalibration) {
                MicCalibrationView(monitor: monitor)
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
                Text(pitchText)
                    .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Hz")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(noteText)
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
        VStack(alignment: .leading, spacing: 6) {
            Label("In target", systemImage: "target")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(percentText)
                .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(monitor.targetZone.formatted)
                .font(.headline)
                .foregroundStyle(Theme.targetZone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in target zone")
        .accessibilityValue(targetAccessibilityValue)
    }

    private var pitchText: String {
        guard let frequency = monitor.readoutFrequency else { return "—" }
        return "\(Int(frequency.rounded()))"
    }

    private var noteText: String {
        guard let frequency = monitor.readoutFrequency,
              let note = PitchMath.noteName(for: frequency)
        else {
            return monitor.status.isRunning ? monitor.resonanceMode.prompt : " "
        }
        return note
    }

    private var percentText: String {
        guard let percent = monitor.stats.pitch.percentInTarget else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var pitchAccessibilityValue: String {
        guard let frequency = monitor.readoutFrequency else { return "No voice detected" }
        let note = PitchMath.spokenNoteName(for: frequency).map { ", note \($0)" } ?? ""
        return "\(Int(frequency.rounded())) hertz\(note)"
    }

    private var targetAccessibilityValue: String {
        let zone = "Target zone \(monitor.targetZone.spokenDescription)"
        guard let percent = monitor.stats.pitch.percentInTarget else { return "No voiced time yet. \(zone)" }
        return "\(Int(percent.rounded())) percent of voiced time. \(zone)"
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

/// Start / pause / resume and reset.
private struct PracticeControls: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            primaryButton
            if monitor.stats.pitch.voicedFrameCount > 0 {
                Button {
                    monitor.resetSession()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .accessibilityHint("Clears the graph and session statistics")
            }
        }
        .controlSize(.large)
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
