import Foundation
import Observation
import os
import SwiftData
import SwiftUI
import UIKit

/// A file to split.
struct SplitSource: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    /// Delete `url` when finished (a temporary copy of a picked file).
    var removesFileWhenDone = true
}

/// Runs the splitter screen: checks the source, then splits it with progress
/// and cancel (SPEC section 23.2).
@MainActor
@Observable
final class SplitSetupModel {
    nonisolated enum Phase: Equatable {
        case checking
        case ready
        case running
        case finished(UUID)
        case failed(String)
    }

    let source: SplitSource
    private(set) var phase = Phase.checking
    private(set) var duration = 0.0
    private(set) var hasVideo = false
    private(set) var assessment: SplitAssessment?
    private(set) var progress = SeparationProgress(fraction: 0, elapsed: 0, chunk: nil)
    private(set) var fallbackReason: String?
    var outputs = SplitOutputs.both
    var engine: SeparationEngineKind = SeparationEngineFactory.isHighQualityAvailable ? .highQuality : .basic
    var quality = SeparationQuality.fast

    @ObservationIgnored private var job: Task<SeparationResult, any Error>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(source: SplitSource) {
        self.source = source
    }

    /// Splits longer than this get a battery warning.
    static let longDuration = 5 * 60.0

    var isLong: Bool { duration > Self.longDuration }

    /// The Basic engine can't split mono files.
    var blocksBasic: Bool { assessment?.isMono == true }

    var canStart: Bool {
        guard phase == .ready, assessment?.isSilent != true else { return false }
        return !(engine == .basic && blocksBasic)
    }

    func check() async {
        phase = .checking
        let url = source.url
        do {
            let info = try await StereoAssetReader.info(url: url)
            duration = info.duration
            hasVideo = info.hasVideo
            let start = try await Task.detached(priority: .userInitiated) {
                try await StereoAssetReader.readStart(of: url, seconds: SeparationJob.assessmentSeconds)
            }.value
            assessment = SplitAssessment.assess(start, sampleRate: StereoAssetReader.decodeRate)
            if assessment?.isMono == true, SeparationEngineFactory.isHighQualityAvailable {
                engine = .highQuality
            }
            phase = .ready
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? SeparationError.unreadable.errorDescription ?? "")
        }
    }

    func start(context: ModelContext) async {
        guard canStart else { return }
        let request = SeparationRequest(
            id: UUID(),
            sourceURL: source.url,
            title: source.title,
            outputs: outputs,
            engine: engine,
            quality: quality
        )
        phase = .running
        progress = SeparationProgress(fraction: 0, elapsed: 0, chunk: nil)
        beginBackgroundTime()
        defer { endBackgroundTime() }

        let (updates, continuation) = AsyncStream.makeStream(of: SeparationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try await SeparationJob.run(request) { update in
                _ = continuation.yield(update)
            }
        }
        job = work
        var stats: [ChunkStat] = []
        for await update in updates {
            progress = update
            if let chunk = update.chunk {
                stats.append(chunk)
            }
        }
        do {
            let result = try await work.value
            fallbackReason = result.fallbackReason
            let track = try SeparationStore(context: context).save(result)
            SeparationDiagnostics.lastRun = SeparationRunStats(
                engine: result.engine,
                chunks: result.chunkStats,
                availableMemoryBytes: os_proc_available_memory()
            )
            phase = .finished(track.id)
        } catch {
            if work.isCancelled {
                phase = .ready
            } else {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? SeparationError.engineFailed.errorDescription ?? "")
            }
        }
        job = nil
    }

    func cancel() {
        job?.cancel()
    }

    /// Asks iOS for extra time so a brief screen lock doesn't stop the split.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Split vocals") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// The last split's timing, shown on the debug screen.
@MainActor
enum SeparationDiagnostics {
    static var lastRun: SeparationRunStats?
}

/// Choose outputs and engine, then split with progress (SPEC section 23.2).
struct SplitSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var model: SplitSetupModel
    let onFinished: (UUID) -> Void

    init(source: SplitSource, onFinished: @escaping (UUID) -> Void) {
        _model = State(initialValue: SplitSetupModel(source: source))
        self.onFinished = onFinished
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: model.source.title)
                    if model.duration > 0 {
                        LabeledContent("Length", value: SessionTime.clock(model.duration))
                    }
                }

                switch model.phase {
                case .checking:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the file…")
                        }
                    }
                case .ready:
                    warnings
                    optionsSection
                    Section {
                        Button {
                            Task { await model.start(context: modelContext) }
                        } label: {
                            Label("Split", systemImage: "scissors")
                        }
                        .disabled(!model.canStart)
                    } footer: {
                        Text("Splitting happens on this iPhone. Nothing is uploaded.")
                    }
                case .running:
                    progressSection
                case .finished:
                    Section {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.targetZone)
                        if let reason = model.fallbackReason {
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Button("Try Again") {
                            Task { await model.check() }
                        }
                    }
                }

                Section {
                    SplitRightsNote()
                }
            }
            .navigationTitle("Split Vocals / Backing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(model.phase == .running)
            .task {
                await model.check()
            }
            .onChange(of: model.phase) { _, phase in
                if case .finished(let id) = phase {
                    onFinished(id)
                }
            }
            .onDisappear {
                model.cancel()
                if model.source.removesFileWhenDone {
                    TargetImportFiles.remove(model.source.url)
                }
            }
            .sensoryFeedback(.success, trigger: model.phase) { _, phase in
                Self.isFinished(phase)
            }
        }
    }

    private static func isFinished(_ phase: SplitSetupModel.Phase) -> Bool {
        if case .finished = phase {
            return true
        }
        return false
    }

    @ViewBuilder
    private var warnings: some View {
        if let assessment = model.assessment {
            if assessment.isSilent {
                Section {
                    Label("This file seems to be silent, so there’s nothing to split.", systemImage: "speaker.slash")
                }
            } else if assessment.isLikelySpeechOnly {
                Section {
                    Label("This sounds like plain speech without music, so splitting probably isn’t needed. You can use it as it is, or split anyway.", systemImage: "text.bubble")
                        .font(.subheadline)
                }
            }
            if assessment.isMono {
                Section {
                    Label(
                        SeparationEngineFactory.isHighQualityAvailable
                            ? "This file is mono, so only the High Quality engine can split it."
                            : "This file is mono (both channels are the same), so the Basic engine can’t split it. Try a stereo version of the song.",
                        systemImage: "speaker.wave.1"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                }
            }
        }
        if model.isLong {
            Section {
                Label("Long songs can take several minutes and use battery. Keep Chirp open; a brief screen lock is fine.", systemImage: "battery.50percent")
                    .font(.subheadline)
            }
        }
    }

    private var optionsSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Keep", selection: $model.outputs) {
                ForEach(SplitOutputs.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Picker("Engine", selection: $model.engine) {
                ForEach(SeparationEngineKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            if model.engine == .highQuality {
                Picker("Quality", selection: $model.quality) {
                    ForEach(SeparationQuality.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Options")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.engine.detail)
                if model.engine == .highQuality, !SeparationEngineFactory.isHighQualityAvailable {
                    Text(SeparationEngineFactory.highQualityUnavailableReason)
                }
                if model.engine == .highQuality {
                    Text(model.quality == .fast ? "Fast: one pass." : "Best: an extra pass for cleaner parts; takes about twice as long.")
                }
            }
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.progress.fraction)
                HStack {
                    Text("\((model.progress.fraction * 100).roundedInt)%")
                        .monospacedDigit()
                    Spacer()
                    Text(ProgressEstimate.text(remaining: model.progress.remainingSeconds))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Splitting")
            .accessibilityValue("\((model.progress.fraction * 100).roundedInt) percent. \(ProgressEstimate.text(remaining: model.progress.remainingSeconds))")
            Button("Cancel", role: .destructive) {
                model.cancel()
            }
        } footer: {
            Text("You can lock the screen briefly; for long songs keep Chirp open.")
        }
    }
}
