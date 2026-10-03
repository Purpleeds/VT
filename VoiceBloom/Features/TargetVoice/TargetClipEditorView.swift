import Foundation
import SwiftData
import SwiftUI

/// Trim an imported clip, check its quality, see its profile and save it
/// (SPEC section 9).
struct TargetClipEditorView: View {
    let imported: ImportedClip

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \TargetVoiceProfile.createdAt) private var targets: [TargetVoiceProfile]

    @State private var selection: TrimSelection
    @State private var audio: AudioClip
    @State private var splitSource: SplitSource?
    @State private var splitTrackID: UUID?
    @State private var isLoadingVocals = false
    @State private var peaks: [Float] = []
    @State private var player = SamplePlayer()
    @State private var report: TargetClipReport?
    @State private var analyzedSelection: TrimSelection?
    @State private var isAnalyzing = false
    @State private var isSaving = false
    @State private var name = ""
    @State private var setsTargets = true
    @State private var errorMessage: String?
    @State private var pitchTrackClip: ImportedClip?
    @State private var pitchTrackMessage: String?

    init(imported: ImportedClip) {
        self.imported = imported
        _selection = State(initialValue: TrimSelection.initial(clipDuration: imported.decoded.audio.duration))
        _audio = State(initialValue: imported.decoded.audio)
    }

    private var clip: AudioClip { audio }
    private var isUsingVocals: Bool { splitTrackID != nil }
    private var isReportCurrent: Bool { report != nil && analyzedSelection == selection }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    trimCard
                    if let report, isReportCurrent {
                        resultCard(report)
                        saveCard(report)
                    }
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
            .navigationTitle("New Target Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .task {
                let samples = clip.samples
                peaks = await Task.detached(priority: .userInitiated) {
                    WaveformSummary.peaks(samples, bucketCount: 160)
                }.value
                if name.isEmpty {
                    name = TargetVoiceStore.cleanName(imported.sourceName, existing: targets.count)
                }
            }
            .onChange(of: selection) { _, _ in
                player.stop()
            }
            .onDisappear {
                player.shutDown()
                if let url = imported.sourceURL {
                    TargetImportFiles.remove(url)
                }
            }
            .sheet(item: $splitSource) { source in
                SplitSetupView(source: source) { id in
                    splitSource = nil
                    Task { await useVocals(fromSplit: id) }
                }
            }
            .sheet(item: $pitchTrackClip) { clip in
                PitchTrackBuilderView(imported: clip, selection: selection, splitTrackID: splitTrackID) { _ in
                    pitchTrackClip = nil
                    pitchTrackMessage = "Track saved. Find it in More › Tools › Pitch Track."
                }
            }
        }
    }

    // MARK: Trim

    private var trimCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(imported.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Clip length \(SessionTime.clock(clip.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if imported.decoded.wasShortened {
                    Text("Only the first \(Int(AudioFileDecoder.maximumDuration / 60)) minutes were loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isUsingVocals {
                Label("Using the isolated vocals from the split, so the music doesn’t throw off the analysis.", systemImage: "waveform.path")
                    .font(.subheadline)
                    .foregroundStyle(Theme.targetZone)
                    .fixedSize(horizontal: false, vertical: true)
            } else if imported.sourceURL != nil {
                Button {
                    startSplit()
                } label: {
                    if isLoadingVocals {
                        ProgressView()
                    } else {
                        Label("Split Vocals / Backing", systemImage: "waveform.path")
                    }
                }
                .buttonStyle(.glass)
                .disabled(isLoadingVocals)
            }

            Button {
                makePitchTrack()
            } label: {
                Label("Make a Pitch Track", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.glass)
            if let pitchTrackMessage {
                Label(pitchTrackMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.targetZone)
            }

            Text("Drag the handles to choose 10–60 seconds of clear speech from just one person.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WaveformTrimView(peaks: peaks, selection: $selection)
                .frame(height: 120)

            HStack {
                Text("\(SessionTime.clock(selection.start)) – \(SessionTime.clock(selection.end))")
                    .monospacedDigit()
                Spacer()
                Text("\(selection.length.roundedInt) s selected")
                    .monospacedDigit()
                    .foregroundStyle(ClipQualityChecker.recommendedDuration.contains(selection.length) ? Color.secondary : Theme.warning)
            }
            .font(.subheadline)

            HStack(spacing: 12) {
                Stepper(
                    "Start",
                    onIncrement: { selection.setStart(selection.start + 0.5) },
                    onDecrement: { selection.setStart(selection.start - 0.5) }
                )
                Stepper(
                    "End",
                    onIncrement: { selection.setEnd(selection.end + 0.5) },
                    onDecrement: { selection.setEnd(selection.end - 0.5) }
                )
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Button {
                    Task { await togglePreview() }
                } label: {
                    Label(player.isPlaying ? "Stop" : "Play selection", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button {
                    Task { await analyze() }
                } label: {
                    if isAnalyzing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(isReportCurrent ? "Analyzed" : "Analyze", systemImage: "waveform.badge.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isAnalyzing || isReportCurrent)
            }
            .controlSize(.large)

            if let message = player.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()
    }

    // MARK: Result

    private func resultCard(_ report: TargetClipReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What we heard")
                .font(.headline)

            if report.quality.warnings.isEmpty {
                Label("Clear, solo speech. Looks good.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.targetZone)
            }
            ForEach(report.quality.warnings) { warning in
                NoticeBanner(
                    title: warning.title,
                    message: warning.message,
                    systemImage: warning.systemImage,
                    tint: warning.isSerious ? Theme.warning : Color.secondary
                )
            }
            if report.quality.warnings.contains(.music), !isUsingVocals, imported.sourceURL != nil {
                Button {
                    startSplit()
                } label: {
                    Label("Split First for Best Results", systemImage: "waveform.path")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }

            if report.take.hasVoice {
                TargetStatsGrid(snapshot: VoiceSnapshot(take: report.take), low: report.take.lowPitch, high: report.take.highPitch, tilt: report.take.spectralTilt)
                PitchHistogramChart(series: [
                    HistogramSeries(name: "Target", histogram: report.take.pitchHistogram, color: Theme.resonanceSeries),
                ])
                .frame(height: 150)
            }
        }
        .cardStyle()
    }

    private func saveCard(_ report: TargetClipReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
            Toggle("Set my targets from this voice", isOn: $setsTargets)
            Text("Sets your pitch range around this voice’s typical pitch, and your resonance, weight and intonation targets from it. You can still change any of them in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await save(report) }
            } label: {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Save Target Voice", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isSaving || !report.take.hasVoice)
            if !report.take.hasVoice {
                Text("No voice was found in this part. Choose a section where someone is talking.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()
    }

    // MARK: Actions

    private func togglePreview() async {
        if player.isPlaying {
            player.stop()
            return
        }
        // The microphone would otherwise analyze the clip as practice.
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
        player.play(clip, range: selection.start...selection.end)
    }

    /// SPEC section 22.1: a clip imported here can also become a Pitch Track
    /// (from the split's vocals when it was split).
    private func makePitchTrack() {
        player.stop()
        // The builder deletes its file when it closes, so it gets its own copy.
        let copy = imported.sourceURL.flatMap { try? TargetImportFiles.copy($0) }
        pitchTrackClip = ImportedClip(decoded: imported.decoded, sourceName: imported.sourceName, sourceURL: copy)
    }

    private func startSplit() {
        guard let url = imported.sourceURL else { return }
        player.stop()
        splitSource = SplitSource(url: url, title: imported.sourceName, removesFileWhenDone: false)
    }

    /// Swaps the clip for the split's isolated vocals (SPEC section 23.4).
    private func useVocals(fromSplit id: UUID) async {
        guard let track = SeparationStore(context: modelContext).track(id: id), let vocals = track.vocalsURL else {
            errorMessage = "That split has no vocals. Split again and keep the vocals."
            return
        }
        isLoadingVocals = true
        defer { isLoadingVocals = false }
        do {
            let decoded = try await AudioFileDecoder.decodeInBackground(url: vocals)
            audio = decoded.audio
            selection = TrimSelection.initial(clipDuration: decoded.audio.duration)
            report = nil
            analyzedSelection = nil
            splitTrackID = id
            let samples = decoded.audio.samples
            peaks = await Task.detached(priority: .userInitiated) {
                WaveformSummary.peaks(samples, bucketCount: 160)
            }.value
        } catch {
            errorMessage = "The isolated vocals couldn’t be opened."
        }
    }

    private func analyze() async {
        player.stop()
        errorMessage = nil
        isAnalyzing = true
        let audio = clip
        let current = selection
        let range = current.start...current.end
        let target = monitor.targetZone
        let result = await Task.detached(priority: .userInitiated) {
            TargetClipAnalyzer.analyze(audio, range: range, target: target)
        }.value
        report = result
        analyzedSelection = current
        isAnalyzing = false
    }

    private func save(_ report: TargetClipReport) async {
        isSaving = true
        defer { isSaving = false }
        let store = TargetVoiceStore(context: modelContext)
        do {
            let range = selection.start...selection.end
            let split = splitTrackID.flatMap { SeparationStore(context: modelContext).track(id: $0) }
            let saved = try await store.save(name: name, report: report, clip: clip, range: range, separatedTrack: split)
            if let user = profiles.first {
                try store.activate(saved, for: user, applyTargets: setsTargets)
                monitor.targetZone = user.targetZone
                monitor.applyReferences(user.personalReferences)
            }
            dismiss()
        } catch {
            errorMessage = "This target voice couldn’t be saved. Please try again."
        }
    }
}

/// Minutes and seconds, e.g. "1:05".
nonisolated enum SessionTime {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let tenths = Int(((seconds - Double(total)) * 10).rounded(.down))
        let base = "\(total / 60):\(String(format: "%02d", total % 60))"
        return seconds < 60 && tenths > 0 ? "\(base).\(min(tenths, 9))" : base
    }
}

/// The clip's waveform with draggable start and end handles.
struct WaveformTrimView: View {
    let peaks: [Float]
    @Binding var selection: TrimSelection

    private static let space = "waveform"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = proxy.size.height
            let duration = max(selection.clipDuration, 0.001)
            let startX = CGFloat(selection.start / duration) * width
            let endX = CGFloat(selection.end / duration) * width
            let selectedColor = Theme.pitchLine
            let otherColor = Color.secondary.opacity(0.3)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let barWidth = size.width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let x = CGFloat(index) * barWidth
                        let barHeight = max(2, CGFloat(peak) * size.height * 0.9)
                        let rect = CGRect(x: x + barWidth * 0.15, y: (size.height - barHeight) / 2, width: max(1, barWidth * 0.7), height: barHeight)
                        let center = x + barWidth / 2
                        let inside = center >= startX && center <= endX
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(inside ? selectedColor : otherColor))
                    }
                }

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.pitchLine.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.pitchLine.opacity(0.6), lineWidth: 1.5)
                    )
                    .frame(width: max(endX - startX, 2), height: height)
                    .offset(x: startX)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                handle(isStart: true, x: startX, height: height, width: width, duration: duration)
                handle(isStart: false, x: endX, height: height, width: width, duration: duration)
            }
            .coordinateSpace(.named(Self.space))
        }
        .overlay {
            if peaks.isEmpty {
                ProgressView()
            }
        }
    }

    private func handle(isStart: Bool, x: CGFloat, height: CGFloat, width: CGFloat, duration: Double) -> some View {
        ZStack {
            Capsule()
                .fill(Theme.pitchLine)
                .frame(width: 4, height: height)
            Circle()
                .fill(Theme.pitchLine)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
        }
        .frame(width: 34, height: height)
        .contentShape(Rectangle())
        .offset(x: x - 17)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let time = Double(min(max(value.location.x, 0), width) / width) * duration
                    if isStart {
                        selection.setStart(time)
                    } else {
                        selection.setEnd(time)
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(isStart ? "Start of selection" : "End of selection")
        .accessibilityValue("\(SessionTime.clock(isStart ? selection.start : selection.end))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            if isStart {
                selection.setStart(selection.start + step)
            } else {
                selection.setEnd(selection.end + step)
            }
        }
    }
}
