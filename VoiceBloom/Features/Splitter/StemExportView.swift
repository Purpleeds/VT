import Foundation
import SwiftUI

/// What to export from a split.
nonisolated enum StemExportContent: String, CaseIterable, Identifiable, Sendable {
    case vocals
    case backing
    case mix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vocals: "Vocals Only"
        case .backing: "Backing Only"
        case .mix: "My Mix"
        }
    }

    var fileSuffix: String {
        switch self {
        case .vocals: "Vocals"
        case .backing: "Backing"
        case .mix: "Mix"
        }
    }
}

/// Builds export files (SPEC section 23.3).
nonisolated enum StemExport {
    /// A file name without characters Files doesn't like.
    static func fileName(title: String, content: StemExportContent, fileExtension: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Split" : String(cleaned.prefix(60))
        return "\(base) - \(content.fileSuffix).\(fileExtension)"
    }

    /// The mixdown inputs for an export.
    static func inputs(
        content: StemExportContent,
        vocals: URL?,
        backing: URL?,
        settings: StemMixSettings
    ) -> [MixInput] {
        switch content {
        case .vocals:
            return vocals.map { [MixInput(url: $0, gain: 1)] } ?? []
        case .backing:
            return backing.map { [MixInput(url: $0, gain: 1)] } ?? []
        case .mix:
            var mixSettings = settings
            mixSettings.mode = .mix
            var result: [MixInput] = []
            if let vocals, mixSettings.gain(.vocals) > 0 {
                result.append(MixInput(url: vocals, gain: Float(mixSettings.gain(.vocals))))
            }
            if let backing, mixSettings.gain(.backing) > 0 {
                result.append(MixInput(url: backing, gain: Float(mixSettings.gain(.backing))))
            }
            return result
        }
    }

    /// Writes the export and returns its URL.
    static func make(
        title: String,
        content: StemExportContent,
        format: AudioExportFormat,
        asVideo: Bool,
        inputs: [MixInput],
        sourceVideo: URL?
    ) async throws -> URL {
        guard !inputs.isEmpty else { throw SeparationError.unreadable }
        let folder = try SeparationFiles.exportsFolder()
        if asVideo, let sourceVideo {
            let audio = folder.appending(path: "audio.m4a", directoryHint: .notDirectory)
            try StemMixdown.render(inputs, to: audio, format: .m4a, isCancelled: { Task.isCancelled })
            let destination = folder.appending(path: fileName(title: title, content: content, fileExtension: "mp4"), directoryHint: .notDirectory)
            try await VideoAudioReplacer.export(video: sourceVideo, audio: audio, to: destination)
            try? FileManager.default.removeItem(at: audio)
            return destination
        }
        let destination = folder.appending(path: fileName(title: title, content: content, fileExtension: format.fileExtension), directoryHint: .notDirectory)
        try StemMixdown.render(inputs, to: destination, format: format, isCancelled: { Task.isCancelled })
        return destination
    }
}

struct StemExportView: View {
    let track: SeparatedTrack
    let settings: StemMixSettings
    /// Cleaned-up vocals to use instead of the raw ones.
    let cleanedVocals: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var content = StemExportContent.vocals
    @State private var format = AudioExportFormat.m4a
    @State private var asVideo = false
    @State private var isWorking = false
    @State private var exported: URL?
    @State private var errorMessage: String?
    @State private var work: Task<URL, any Error>?

    private var available: [StemExportContent] {
        StemExportContent.allCases.filter { option in
            switch option {
            case .vocals: track.vocalsURL != nil
            case .backing: track.backingURL != nil
            case .mix: track.vocalsURL != nil && track.backingURL != nil
            }
        }
    }

    private var canExportVideo: Bool {
        guard track.sourceType == .video, let source = track.sourceURL else { return false }
        return FileManager.default.fileExists(atPath: source.path(percentEncoded: false))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Export", selection: $content) {
                        ForEach(available) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if content == .mix {
                        Text("Uses your mixer volumes, mute and solo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if canExportVideo {
                        Toggle("Video With This Audio", isOn: $asVideo)
                    }
                    if !asVideo {
                        Picker("Format", selection: $format) {
                            ForEach(AudioExportFormat.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    Text(asVideo
                        ? "The original video, untouched, with its sound replaced (MP4)."
                        : "M4A is small; WAV is uncompressed and larger.")
                }

                Section {
                    if isWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Exporting…")
                            Spacer()
                            Button("Cancel") {
                                work?.cancel()
                            }
                        }
                    } else if let exported {
                        ShareLink(item: exported) {
                            Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        }
                        Text(exported.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            startExport()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.down.on.square")
                        }
                        .disabled(available.isEmpty)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                } footer: {
                    Text("Separated audio is for your own practice. Please respect the rights of the original creators when sharing.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        work?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let first = available.first, !available.contains(content) {
                    content = first
                }
            }
            .onChange(of: content) { _, _ in exported = nil }
            .onChange(of: format) { _, _ in exported = nil }
            .onChange(of: asVideo) { _, _ in exported = nil }
        }
    }

    private func startExport() {
        errorMessage = nil
        isWorking = true
        let inputs = StemExport.inputs(
            content: content,
            vocals: cleanedVocals ?? track.vocalsURL,
            backing: track.backingURL,
            settings: settings
        )
        let title = track.title
        let content = content
        let format = format
        let video = asVideo && canExportVideo ? track.sourceURL : nil
        let job = Task.detached(priority: .userInitiated) {
            try await StemExport.make(
                title: title,
                content: content,
                format: format,
                asVideo: video != nil,
                inputs: inputs,
                sourceVideo: video
            )
        }
        work = job
        Task {
            do {
                exported = try await job.value
            } catch {
                errorMessage = job.isCancelled
                    ? "Export cancelled."
                    : ((error as? LocalizedError)?.errorDescription ?? "The export didn’t work. Please try again.")
            }
            isWorking = false
        }
    }
}
