import Foundation
import Observation
import SwiftData
import SwiftUI

/// The preview mixer's state (SPEC section 23.2).
@MainActor
@Observable
final class StemMixerModel {
    let trackID: UUID
    let vocalsURL: URL?
    let backingURL: URL?
    let cleanedVocalsURL: URL?

    var settings = StemMixSettings() {
        didSet { applyGains() }
    }
    private(set) var cleanup = CleanupOptions()
    private(set) var isPlaying = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var vocalsPeaks: [Float] = []
    private(set) var backingPeaks: [Float] = []
    private(set) var isLoading = true
    private(set) var isRenderingCleanup = false
    private(set) var errorMessage: String?
    var isLooping = false
    private(set) var loop: LoopRange?

    @ObservationIgnored private let playback = StemPlaybackEngine()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    init(track: SeparatedTrack) {
        trackID = track.id
        vocalsURL = track.vocalsURL
        backingURL = track.backingURL
        cleanedVocalsURL = track.cleanedVocalsURL
        duration = track.duration
    }

    var hasVocals: Bool { vocalsURL != nil }
    var hasBacking: Bool { backingURL != nil }

    /// The vocals file playing now (cleaned up, when that's on).
    var activeVocalsURL: URL? {
        cleanup.isEmpty ? vocalsURL : (cleanedVocalsURL ?? vocalsURL)
    }

    func prepare() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try playback.load(vocals: vocalsURL, backing: backingURL)
            duration = playback.duration
            applyGains()
        } catch {
            errorMessage = "These parts couldn’t be opened. They may have been deleted."
            return
        }
        let vocals = vocalsURL
        let backing = backingURL
        vocalsPeaks = await Task.detached(priority: .userInitiated) {
            vocals.flatMap { try? FileWaveform.peaks(url: $0, bucketCount: 180) } ?? []
        }.value
        backingPeaks = await Task.detached(priority: .userInitiated) {
            backing.flatMap { try? FileWaveform.peaks(url: $0, bucketCount: 180) } ?? []
        }.value
    }

    // MARK: Transport

    func togglePlay(monitor: LiveVoiceMonitor) async {
        if isPlaying {
            pause()
            return
        }
        // The microphone would hear the music.
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
        var start = position >= duration - 0.05 ? 0 : position
        if isLooping, let loop {
            start = loop.position(after: start)
        }
        do {
            try playback.play(from: start)
            isPlaying = true
            errorMessage = nil
            startTicker()
        } catch {
            errorMessage = playback.errorMessage ?? "Audio can’t play right now."
        }
    }

    func pause() {
        playback.stop()
        isPlaying = false
        position = playback.currentTime
        ticker?.cancel()
        ticker = nil
    }

    func seek(to time: Double) {
        do {
            try playback.seek(to: time)
            position = min(max(0, time), duration)
        } catch {
            errorMessage = playback.errorMessage ?? "Audio can’t play right now."
            pause()
        }
    }

    /// Marks the current position as the loop's start or end.
    func setLoopPoint(isStart: Bool) {
        let current = position
        let start = isStart ? current : (loop?.start ?? 0)
        let end = isStart ? (loop?.end ?? duration) : current
        if let range = LoopRange.make(start: start, end: end, duration: duration) {
            loop = range
            isLooping = true
        }
    }

    func clearLoop() {
        loop = nil
        isLooping = false
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard isPlaying else { return }
        let now = playback.currentTime
        if isLooping, let loop, now >= loop.end {
            seek(to: loop.start)
            return
        }
        if now >= duration - 0.02 {
            pause()
            position = duration
            return
        }
        if abs(now - position) > 0.02 {
            position = now
        }
    }

    private func applyGains() {
        playback.setGains(vocals: settings.gain(.vocals), backing: settings.gain(.backing))
    }

    // MARK: Clean-up

    func setCleanup(_ options: CleanupOptions) {
        guard options != cleanup else { return }
        cleanup = options
        cleanupTask?.cancel()
        guard let source = vocalsURL else { return }
        if options.isEmpty {
            reloadVocals()
            return
        }
        guard let destination = cleanedVocalsURL else { return }
        isRenderingCleanup = true
        cleanupTask = Task { [weak self] in
            let succeeded = await Task.detached(priority: .userInitiated) {
                do {
                    try SeparationJob.renderCleanup(from: source, to: destination, options: options)
                    return true
                } catch {
                    return false
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isRenderingCleanup = false
            if succeeded {
                self.reloadVocals()
            } else {
                self.errorMessage = "Clean-up couldn’t be applied."
                self.cleanup = CleanupOptions()
            }
        }
    }

    private func reloadVocals() {
        do {
            try playback.load(vocals: activeVocalsURL, backing: backingURL)
            applyGains()
            if !playback.isPlaying, isPlaying {
                isPlaying = false
            }
        } catch {
            errorMessage = "The vocals couldn’t be reloaded."
        }
    }

    func shutDown() {
        ticker?.cancel()
        cleanupTask?.cancel()
        playback.shutDown()
        isPlaying = false
    }
}

/// Preview, mix, export and discard a split (SPEC sections 23.2–23.3).
struct StemMixerView: View {
    let track: SeparatedTrack

    var body: some View {
        StemMixerContent(track: track)
            .id(track.id)
    }
}

private struct StemMixerContent: View {
    let track: SeparatedTrack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var model: StemMixerModel
    @State private var isExporting = false
    @State private var isRecordingOver = false
    @State private var isConfirmingDiscard = false
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var noiseGate = false
    @State private var deReverb = false

    init(track: SeparatedTrack) {
        self.track = track
        _model = State(initialValue: StemMixerModel(track: track))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                waveformCard
                transportCard
                partsCard
                if model.hasVocals {
                    cleanupCard
                }
                actionsCard
                SplitRightsNote()
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.prepare()
        }
        .onChange(of: model.position) { _, newValue in
            if !isScrubbing {
                scrubPosition = newValue
            }
        }
        .onChange(of: noiseGate) { _, _ in updateCleanup() }
        .onChange(of: deReverb) { _, _ in updateCleanup() }
        .onDisappear {
            model.shutDown()
        }
        .sheet(isPresented: $isExporting) {
            StemExportView(track: track, settings: model.settings, cleanedVocals: model.cleanup.isEmpty ? nil : model.activeVocalsURL)
        }
        .fullScreenCover(isPresented: $isRecordingOver) {
            RecordOverBackingView(track: track)
        }
        .confirmationDialog("Discard this split?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Split", role: .destructive) {
                discard()
            }
        } message: {
            Text("The vocals and backing files are deleted. The original file in Files or Photos isn’t touched.")
        }
    }

    // MARK: Cards

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(SessionTime.clock(track.duration)) · \(track.engine.title) engine")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if track.engine == .basic {
                Text("Basic quality: some instruments may stay in the vocals, and some voice in the backing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasVocals {
                StemWaveformRow(title: "Vocals", peaks: model.vocalsPeaks, color: Theme.resonanceSeries, progress: progress, loop: loopFractions)
            }
            if model.hasBacking {
                StemWaveformRow(title: "Backing", peaks: model.backingPeaks, color: Theme.pitchLine, progress: progress, loop: loopFractions)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waveforms")
        .accessibilityValue("\(SessionTime.clock(model.position)) of \(SessionTime.clock(model.duration))")
    }

    private var progress: Double {
        model.duration > 0 ? min(max(scrubPosition / model.duration, 0), 1) : 0
    }

    private var loopFractions: ClosedRange<Double>? {
        guard model.isLooping, let loop = model.loop, model.duration > 0 else { return nil }
        return (loop.start / model.duration)...(loop.end / model.duration)
    }

    private var transportCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Slider(value: $scrubPosition, in: 0...max(model.duration, 0.1), onEditingChanged: { editing in
                isScrubbing = editing
                if !editing {
                    model.seek(to: scrubPosition)
                }
            })
            .accessibilityLabel("Position")
            .accessibilityValue(SessionTime.clock(scrubPosition))
            HStack {
                Text(SessionTime.clock(scrubPosition))
                Spacer()
                Text(SessionTime.clock(model.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task { await model.togglePlay(monitor: monitor) }
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isLoading)

                Menu {
                    Button("Set Loop Start Here", systemImage: "arrow.right.to.line") {
                        model.setLoopPoint(isStart: true)
                    }
                    Button("Set Loop End Here", systemImage: "arrow.left.to.line") {
                        model.setLoopPoint(isStart: false)
                    }
                    if model.loop != nil {
                        Button("Clear Loop", systemImage: "xmark") {
                            model.clearLoop()
                        }
                    }
                } label: {
                    Label(model.isLooping ? "Looping" : "Loop", systemImage: "repeat")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            if let loop = model.loop, model.isLooping {
                Text("Loop \(SessionTime.clock(loop.start)) – \(SessionTime.clock(loop.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Listen to", selection: $model.settings.mode) {
                ForEach(StemListenMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Compare the original with the vocals, the backing, or your mix")
        }
        .cardStyle()
        .sensoryFeedback(.selection, trigger: model.settings.mode)
    }

    private var partsCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Text("Mix")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.hasVocals {
                StemPartControls(
                    part: .vocals,
                    volume: $model.settings.vocalsVolume,
                    isMuted: $model.settings.vocalsMuted,
                    isSolo: $model.settings.vocalsSolo
                )
            }
            if model.hasBacking {
                StemPartControls(
                    part: .backing,
                    volume: $model.settings.backingVolume,
                    isMuted: $model.settings.backingMuted,
                    isSolo: $model.settings.backingSolo
                )
            }
            if model.settings.mode != .mix {
                Text("Volumes, mute and solo apply in Mix mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean up vocals")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Noise Gate", isOn: $noiseGate)
            Toggle("Light De-reverb", isOn: $deReverb)
            if model.isRenderingCleanup {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Applying…")
                        .font(.subheadline)
                }
            }
            Text("The gate quiets the gaps between phrases; de-reverb shortens the echo. Both are simple and optional, and also apply to exports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isRenderingCleanup)
        .cardStyle()
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                model.pause()
                isExporting = true
            } label: {
                Label("Export or Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            if model.hasBacking {
                Button {
                    model.pause()
                    isRecordingOver = true
                } label: {
                    Label("Record Over Backing", systemImage: "mic.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            Button(role: .destructive) {
                isConfirmingDiscard = true
            } label: {
                Label("Discard Split", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }

    // MARK: Actions

    private func updateCleanup() {
        model.setCleanup(CleanupOptions(noiseGate: noiseGate, deReverb: deReverb))
    }

    /// Leaves the screen first, then deletes (reading a deleted model crashes).
    private func discard() {
        model.shutDown()
        let store = SeparationStore(context: modelContext)
        let id = track.id
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if let toDelete = store.track(id: id) {
                try? store.delete(toDelete)
            }
        }
    }
}

/// Volume (0–150 %), mute and solo for one part.
private struct StemPartControls: View {
    let part: StemPart
    @Binding var volume: Double
    @Binding var isMuted: Bool
    @Binding var isSolo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(part.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\((volume * 100).roundedInt)%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Toggle(isOn: $isSolo) {
                    Text("S")
                        .fontWeight(.bold)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Solo \(part.title.lowercased())")
                Toggle(isOn: $isMuted) {
                    Text("M")
                        .fontWeight(.bold)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Mute \(part.title.lowercased())")
            }
            Slider(value: $volume, in: StemMixSettings.volumeRange, step: 0.05) {
                Text("\(part.title) volume")
            }
            .accessibilityValue("\((volume * 100).roundedInt) percent")
        }
    }
}

/// A part's waveform with the playhead and loop region.
private struct StemWaveformRow: View {
    let title: String
    let peaks: [Float]
    let color: Color
    let progress: Double
    let loop: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Canvas { context, size in
                if let loop {
                    let rect = CGRect(x: size.width * loop.lowerBound, y: 0, width: size.width * (loop.upperBound - loop.lowerBound), height: size.height)
                    context.fill(Path(rect), with: .color(color.opacity(0.12)))
                }
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                let middle = size.height / 2
                var played = Path()
                var unplayed = Path()
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(min(peak, 1)) * size.height)
                    let rect = CGRect(x: CGFloat(index) * barWidth, y: middle - height / 2, width: max(1, barWidth * 0.7), height: height)
                    if Double(index) / Double(peaks.count) <= progress {
                        played.addRect(rect)
                    } else {
                        unplayed.addRect(rect)
                    }
                }
                context.fill(played, with: .color(color))
                context.fill(unplayed, with: .color(color.opacity(0.35)))
                var playhead = Path()
                let x = size.width * progress
                playhead.move(to: CGPoint(x: x, y: 0))
                playhead.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(playhead, with: .color(.primary), lineWidth: 1.5)
            }
            .frame(height: 56)
            .accessibilityHidden(true)
        }
    }
}

/// SPEC section 23.3: a small note about rights.
struct SplitRightsNote: View {
    var body: some View {
        Label("Separated audio is for your own practice. Please respect the rights of the original creators when sharing.", systemImage: "c.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
