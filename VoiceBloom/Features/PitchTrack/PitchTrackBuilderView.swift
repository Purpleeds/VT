import Foundation
import Observation
import SwiftData
import SwiftUI

/// A cancel switch the background analysis can check.
nonisolated final class TrackBuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Makes a Pitch Track from an imported clip (SPEC section 22.1): trim,
/// analyze with progress and cancel, check the type and warnings, save.
@MainActor
@Observable
final class PitchTrackBuilderModel {
    nonisolated enum Phase: Equatable {
        case trimming
        case building
        case review
    }

    let imported: ImportedClip
    private(set) var phase = Phase.trimming
    var selection: TrimSelection
    /// The clip being analyzed: the original, or the split's vocals.
    private(set) var audio: AudioClip
    private(set) var peaks: [Float] = []
    private(set) var splitTrackID: UUID?
    private(set) var isLoadingVocals = false
    private(set) var stage: TrackBuildStage = .detectingPitch
    private(set) var stageProgress = 0.0
    private(set) var analysis: PitchTrackAnalysis?
    private(set) var content: PitchTrackContent?
    private(set) var words: [TranscribedWord] = []
    private(set) var kind = PitchTrackKind.speech
    private(set) var hasMusic = false
    private(set) var errorMessage: String?
    private(set) var analyzedSelection: TrimSelection?
    var name = ""

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellation: TrackBuildCancellation?
    @ObservationIgnored private var stereo: SplitAssessment?
    @ObservationIgnored private var references = PersonalReferences.none

    init(imported: ImportedClip, selection: TrimSelection?) {
        self.imported = imported
        audio = imported.decoded.audio
        self.selection = selection ?? TrimSelection.initial(clipDuration: imported.decoded.audio.duration)
    }

    var isUsingVocals: Bool { splitTrackID != nil }

    func loadPeaks() async {
        let samples = audio.samples
        peaks = await Task.detached(priority: .userInitiated) {
            WaveformSummary.peaks(samples, bucketCount: 160)
        }.value
    }

    /// Swaps the clip for a split's isolated vocals (SPEC section 23.4: bars
    /// are generated from the isolated vocals).
    func useVocals(fromSplit id: UUID, context: ModelContext) async {
        guard let track = SeparationStore(context: context).track(id: id), let vocals = track.vocalsURL else {
            errorMessage = "That split has no vocals. Split again and keep the vocals."
            return
        }
        isLoadingVocals = true
        defer { isLoadingVocals = false }
        do {
            let decoded = try await AudioFileDecoder.decodeInBackground(url: vocals)
            audio = decoded.audio
            let previous = selection
            selection = TrimSelection(clipDuration: decoded.audio.duration, start: previous.start, end: previous.end)
            splitTrackID = id
            phase = .trimming
            analysis = nil
            content = nil
            await loadPeaks()
        } catch {
            errorMessage = "The isolated vocals couldn’t be opened."
        }
    }

    /// Analyzes the selection, then looks for words.
    func build(references: PersonalReferences) {
        task?.cancel()
        errorMessage = nil
        self.references = references
        let section = TargetClipAnalyzer.section(of: audio, range: selection.start...selection.end)
        let cancellation = TrackBuildCancellation()
        self.cancellation = cancellation
        let current = selection
        let sourceURL = isUsingVocals ? nil : imported.sourceURL
        phase = .building
        stage = .detectingPitch
        stageProgress = 0

        let reportProgress: @Sendable (TrackBuildStage, Double) -> Void = { [weak self] stage, fraction in
            guard let model = self else { return }
            Task { @MainActor in
                model.report(stage, fraction)
            }
        }

        task = Task { [weak self] in
            let outcome: Result<PitchTrackAnalysis, Error> = await Task.detached(priority: .userInitiated) {
                var lastReported = -1.0
                do {
                    let analysis = try PitchTrackBuilder.analyze(
                        section,
                        references: references,
                        isCancelled: { cancellation.isCancelled }
                    ) { stage, fraction in
                        guard fraction - lastReported >= 0.02 || fraction >= 1 || fraction == 0 else { return }
                        lastReported = fraction
                        reportProgress(stage, fraction)
                    }
                    return .success(analysis)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(let error):
                self.phase = .trimming
                if (error as? PitchTrackError) != .cancelled {
                    self.errorMessage = (error as? PitchTrackError)?.errorDescription ?? "The clip couldn’t be analyzed."
                }
                return
            case .success(let analysis):
                guard !cancellation.isCancelled else { return }
                self.analysis = analysis
                self.analyzedSelection = current
                self.kind = analysis.detection.kind
                if let sourceURL {
                    self.stereo = try? await StereoAssetReader.readStart(of: sourceURL, seconds: 60).assess()
                }
            }

            // Words (SPEC section 22.1: words under the bars).
            self.stage = .findingWords
            self.stageProgress = 0
            let found = await Self.transcribe(section)
            // Skipped (the review is already showing) or cancelled.
            guard !cancellation.isCancelled else { return }
            self.words = found
            self.finishReview()
        }
    }

    /// Stops the analysis, or skips the word search.
    func cancel() {
        cancellation?.cancel()
        guard phase == .building else { return }
        if stage == .findingWords, analysis != nil {
            words = []
            finishReview()
        } else {
            task?.cancel()
            phase = .trimming
        }
    }

    /// The user's choice of speech or singing (SPEC: show the result with a
    /// manual override).
    func setKind(_ newKind: PitchTrackKind) {
        guard newKind != kind, newKind != .builtIn else { return }
        kind = newKind
        refreshContent()
    }

    func shutDown() {
        cancellation?.cancel()
        task?.cancel()
    }

    /// Back to choosing the part, keeping the clip (and split) as they are.
    func returnToTrimming() {
        cancellation?.cancel()
        task?.cancel()
        if let analyzedSelection {
            selection = analyzedSelection
        }
        phase = .trimming
    }

    // MARK: Saving

    func save(context: ModelContext) async -> UUID? {
        guard let content, let analysis else { return nil }
        let range = (analyzedSelection ?? selection)
        let original = TargetClipAnalyzer.section(of: imported.decoded.audio, range: range.start...range.end)
        let settings = TrackSettings.defaults(kind: content.kind, hasOriginalAudio: true, hasSplit: isUsingVocals)
        do {
            let track = try await PitchTrackStore(context: context).save(
                name: name,
                content: content,
                detectedKind: analysis.detection.kind,
                settings: settings,
                audio: original,
                separatedTrackID: splitTrackID,
                splitOffset: range.start,
                hasBackgroundMusic: hasMusic,
                hasMultipleSpeakers: analysis.hasMultipleSpeakers
            )
            return track.id
        } catch {
            errorMessage = "The track couldn’t be saved. Please try again."
            return nil
        }
    }

    // MARK: Internals

    private func report(_ newStage: TrackBuildStage, _ fraction: Double) {
        guard phase == .building, stage != .findingWords else { return }
        if newStage != stage {
            stage = newStage
        }
        stageProgress = fraction
    }

    private func finishReview() {
        refreshContent()
        phase = .review
    }

    private func refreshContent() {
        guard let analysis else { return }
        var made = analysis.content(as: kind, references: references)
        if PitchTrackBuilder.shouldShowWords(words, kind: kind) {
            made.bars = PitchTrackBuilder.attach(words, to: made.bars)
        }
        content = made
        hasMusic = !isUsingVocals && analysis.hasMusic(kind: kind, stereo: stereo)
    }

    /// Writes the section to a temporary file and transcribes it on device.
    private static func transcribe(_ clip: AudioClip) async -> [TranscribedWord] {
        let url = FileManager.default.temporaryDirectory.appending(path: "track-words-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try RecordingFileStore.write(clip, to: url)
            }.value
        } catch {
            return []
        }
        return await TrackTranscriber.words(in: url)
    }
}

extension StereoBuffer {
    /// The stereo checks for a clip decoded at the splitter's rate.
    nonisolated func assess() -> SplitAssessment {
        SplitAssessment.assess(self, sampleRate: StereoAssetReader.decodeRate)
    }
}

struct PitchTrackBuilderView: View {
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var model: PitchTrackBuilderModel
    @State private var player = SamplePlayer()
    @State private var splitSource: SplitSource?
    @State private var targetClip: ImportedClip?
    @State private var isSaving = false
    /// The type picker's value, synced with the model.
    @State private var kindSelection = PitchTrackKind.speech
    private let initialSplitID: UUID?

    init(imported: ImportedClip, selection: TrimSelection? = nil, splitTrackID: UUID? = nil, onSaved: @escaping (UUID) -> Void) {
        _model = State(initialValue: PitchTrackBuilderModel(imported: imported, selection: selection))
        initialSplitID = splitTrackID
        self.onSaved = onSaved
    }

    private var references: PersonalReferences {
        profiles.first?.personalReferences ?? monitor.personalReferences
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.phase {
                    case .trimming:
                        trimCard
                    case .building:
                        PitchTrackBuildProgress(stage: model.stage, progress: model.stageProgress) {
                            model.cancel()
                        }
                    case .review:
                        if let content = model.content, let analysis = model.analysis {
                            reviewCard(content: content, analysis: analysis)
                            saveCard
                        }
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SpeechSingingNote()
                        .cardStyle()
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("New Pitch Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(isSaving || model.phase == .building)
            .task {
                await model.loadPeaks()
                if model.name.isEmpty {
                    model.name = PitchTrackStore.cleanName(model.imported.sourceName)
                }
                if let initialSplitID, model.splitTrackID == nil {
                    await model.useVocals(fromSplit: initialSplitID, context: modelContext)
                }
            }
            .onChange(of: model.selection) { _, _ in
                player.stop()
            }
            .onDisappear {
                player.shutDown()
                model.shutDown()
                if let url = model.imported.sourceURL {
                    TargetImportFiles.remove(url)
                }
            }
            .sheet(item: $splitSource) { source in
                SplitSetupView(source: source) { id in
                    splitSource = nil
                    Task { await model.useVocals(fromSplit: id, context: modelContext) }
                }
            }
            .sheet(item: $targetClip) { clip in
                TargetClipEditorView(imported: clip)
            }
        }
    }

    // MARK: Trim

    private var trimCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.imported.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Clip length \(SessionTime.clock(model.audio.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isUsingVocals {
                Label("Using the isolated vocals from the split: bars come from the voice only.", systemImage: "waveform.path")
                    .font(.subheadline)
                    .foregroundStyle(Theme.targetZone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Drag the handles to choose up to two minutes. A clear solo voice gives the cleanest bars.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WaveformTrimView(peaks: model.peaks, selection: $model.selection)
                .frame(height: 110)

            HStack {
                Text("\(SessionTime.clock(model.selection.start)) – \(SessionTime.clock(model.selection.end))")
                    .monospacedDigit()
                Spacer()
                Text("\(model.selection.length.roundedInt) s selected")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Button {
                    Task { await togglePreview() }
                } label: {
                    Label(player.isPlaying ? "Stop" : "Play Selection", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    player.stop()
                    model.build(references: references)
                } label: {
                    Label("Make Track", systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isLoadingVocals)
            }
            .controlSize(.large)

            HStack(spacing: 10) {
                if !model.isUsingVocals, model.imported.sourceURL != nil {
                    Button {
                        startSplit()
                    } label: {
                        if model.isLoadingVocals {
                            ProgressView()
                        } else {
                            Label("Split Vocals First", systemImage: "waveform.path")
                        }
                    }
                    .buttonStyle(.glass)
                }
                Button {
                    openAsTargetVoice()
                } label: {
                    Label("Use as Target Voice", systemImage: "person.wave.2")
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline)

            if let message = player.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()
    }

    // MARK: Review

    private func reviewCard(content: PitchTrackContent, analysis: PitchTrackAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What we found")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Type", selection: $kindSelection) {
                    Text(PitchTrackKind.speech.title).tag(PitchTrackKind.speech)
                    Text(PitchTrackKind.singing.title).tag(PitchTrackKind.singing)
                }
                .pickerStyle(.segmented)
                Text(detectionText(analysis.detection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PitchTrackPreview(bars: content.bars)
                .frame(height: 120)
                .accessibilityLabel("Preview of \(content.bars.count) bars")

            HStack {
                StatTile(title: "Bars", value: "\(content.bars.count)")
                StatTile(title: "Range", value: content.range.map(TrackRange.label) ?? "–")
                StatTile(title: "Words", value: model.words.isEmpty ? "None" : "\(model.words.count)")
            }

            if model.hasMusic {
                NoticeBanner(
                    title: "Background music",
                    message: "Music makes the bars less accurate. Split the vocals first, or choose a clip with a clear solo voice.",
                    systemImage: "music.note"
                )
                if model.imported.sourceURL != nil {
                    Button {
                        startSplit()
                    } label: {
                        Label("Split First for Best Results", systemImage: "waveform.path")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
            if analysis.hasMultipleSpeakers {
                NoticeBanner(
                    title: ClipQualityWarning.multipleSpeakers.title,
                    message: "We heard voices at clearly different pitches. Trim to a part with just one person, or the bars will jump between them.",
                    systemImage: ClipQualityWarning.multipleSpeakers.systemImage
                )
            }
            if model.kind == .singing, !model.words.isEmpty, !PitchTrackBuilder.shouldShowWords(model.words, kind: .singing) {
                Text("The words weren’t clear enough to show under the bars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Choose a Different Part") {
                model.returnToTrimming()
            }
            .font(.subheadline)
        }
        .cardStyle()
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Track name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Save Track", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isSaving || (model.content?.bars.isEmpty ?? true))
            if model.content?.bars.isEmpty ?? false {
                Text("No bars were found. Try the other type, or a part with a clearer voice.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .cardStyle()
        .onAppear {
            kindSelection = model.kind
        }
        .onChange(of: kindSelection) { _, newKind in
            model.setKind(newKind)
        }
        .onChange(of: model.kind) { _, newKind in
            if kindSelection != newKind {
                kindSelection = newKind
            }
        }
    }

    private func detectionText(_ detection: ClipTypeDetection) -> String {
        let guess = detection.kind == .singing ? "singing" : "speech"
        let certainty = detection.isConfident ? "This sounds like" : "This might be"
        return "\(certainty) \(guess). Change it if we got it wrong: speech keeps the natural pitch curves, singing snaps notes to the nearest semitone."
    }

    // MARK: Actions

    private func togglePreview() async {
        if player.isPlaying {
            player.stop()
            return
        }
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
        player.play(model.audio, range: model.selection.start...model.selection.end)
    }

    private func startSplit() {
        guard let url = model.imported.sourceURL else { return }
        player.stop()
        splitSource = SplitSource(url: url, title: model.imported.sourceName, removesFileWhenDone: false)
    }

    /// SPEC section 22.1: a clip imported here can also become a target voice.
    private func openAsTargetVoice() {
        player.stop()
        // The editor deletes its file when it closes, so it gets its own copy.
        let copy = model.imported.sourceURL.flatMap { try? TargetImportFiles.copy($0) }
        targetClip = ImportedClip(decoded: model.imported.decoded, sourceName: model.imported.sourceName, sourceURL: copy)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if let id = await model.save(context: modelContext) {
            dismiss()
            onSaved(id)
        }
    }
}

/// "Detecting pitch… Measuring resonance… Building track…" with cancel.
struct PitchTrackBuildProgress: View {
    let stage: TrackBuildStage
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TrackBuildStage.allCases, id: \.rawValue) { step in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: step))
                        .foregroundStyle(step <= stage ? Theme.targetZone : Color.secondary)
                        .accessibilityHidden(true)
                    Text(step.title)
                        .foregroundStyle(step == stage ? Color.primary : Color.secondary)
                    Spacer()
                    if step == stage, step != .findingWords {
                        Text("\((progress * 100).roundedInt)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if step == stage {
                        ProgressView()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(step < stage ? "Done" : step == stage ? "In progress" : "Waiting")
            }
            ProgressView(value: overall)
            Button(stage == .findingWords ? "Skip Words" : "Cancel", role: stage == .findingWords ? nil : .cancel) {
                onCancel()
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
        }
        .cardStyle()
    }

    private var overall: Double {
        let steps = Double(TrackBuildStage.allCases.count)
        return min(1, (Double(stage.rawValue) + min(max(progress, 0), 1)) / steps)
    }

    private func icon(for step: TrackBuildStage) -> String {
        if step < stage { return "checkmark.circle.fill" }
        if step == stage { return "circle.dotted" }
        return "circle"
    }
}

/// A small static drawing of a track's bars.
struct PitchTrackPreview: View {
    let bars: [TrackBar]

    var body: some View {
        let window = PitchTrackGameModel.window(for: bars)
        let duration = max(bars.last?.end ?? 1, 1)
        let color = Theme.pitchLine
        Canvas { context, size in
            func x(_ time: Double) -> CGFloat { size.width * CGFloat(time / duration) }
            func y(_ midi: Double) -> CGFloat {
                let fraction = (midi - window.lowerBound) / max(window.upperBound - window.lowerBound, 1)
                return size.height * CGFloat(1 - fraction)
            }
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(Color.secondary.opacity(0.08)))
            let thickness = max(3, size.height / CGFloat(max(window.upperBound - window.lowerBound, 1)) * 0.6)
            for bar in bars {
                if bar.isCurved {
                    var path = Path()
                    for (index, point) in bar.contour.enumerated() {
                        let location = CGPoint(x: x(point.time), y: y(point.midi))
                        if index == 0 {
                            path.move(to: location)
                        } else {
                            path.addLine(to: location)
                        }
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
                } else {
                    let rect = CGRect(x: x(bar.start), y: y(bar.midi) - thickness / 2, width: max(2, x(bar.end) - x(bar.start)), height: thickness)
                    context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
                }
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
