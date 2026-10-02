import CoreTransferable
import Foundation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Target Voice tab (SPEC section 9): import a clip of a voice you like,
/// analyze it, and use it as a guide.
struct TargetVoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \TargetVoiceProfile.createdAt) private var targets: [TargetVoiceProfile]

    @State private var isImportingFile = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var importError: String?
    @State private var editorClip: ImportedClip?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TargetGuideNote()

                    if let importError {
                        NoticeBanner(title: "Couldn’t import", message: importError, systemImage: "exclamationmark.triangle.fill")
                    }

                    if targets.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your target voices")
                                .font(.headline)
                            ForEach(targets) { target in
                                NavigationLink {
                                    TargetProfileDetailView(target: target)
                                } label: {
                                    TargetProfileCard(target: target)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    importCard
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Target Voice")
            .overlay {
                if isLoading {
                    ProgressView("Reading the clip…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.audio, .movie]) { result in
                switch result {
                case .success(let url):
                    let name = url.deletingPathExtension().lastPathComponent
                    Task {
                        await load(name: name) {
                            try await Task.detached(priority: .userInitiated) {
                                try TargetImportFiles.copyPickedFile(url)
                            }.value
                        }
                    }
                case .failure:
                    importError = TargetImportError.copyFailed.errorDescription
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    await load(name: "Video from Photos") {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                            throw TargetImportError.copyFailed
                        }
                        return movie.url
                    }
                }
            }
            .sheet(item: $editorClip) { clip in
                TargetClipEditorView(imported: clip)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.wave.2")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Find a voice you’d like to grow toward")
                .font(.title3.weight(.semibold))
            Text("Import 10–60 seconds of one person talking (an interview, a vlog, a voice memo from a friend who agreed). VoiceBloom measures its pitch, resonance, weight and melody on this iPhone, and can set your targets from it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(targets.isEmpty ? "Add a target voice" : "Add another")
                .font(.headline)
            HStack(spacing: 10) {
                Button {
                    importError = nil
                    isImportingFile = true
                } label: {
                    Label("From Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .disabled(isLoading)
            Text("MP3, M4A, WAV, MP4 or MOV. The clip stays on this iPhone; only the part you choose is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Copies the picked file, decodes its sound and opens the trim editor.
    private func load(name: String, copy: () async throws -> URL) async {
        importError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let local = try await copy()
            defer { TargetImportFiles.remove(local) }
            let decoded = try await AudioFileDecoder.decodeInBackground(url: local)
            editorClip = ImportedClip(decoded: decoded, sourceName: name)
        } catch {
            importError = (error as? TargetImportError)?.errorDescription ?? TargetImportError.unreadable.errorDescription
        }
    }
}

/// A decoded clip waiting to be trimmed.
struct ImportedClip: Identifiable {
    let id = UUID()
    let decoded: DecodedClip
    let sourceName: String
}

/// A video picked from Photos, copied to a temporary file.
nonisolated struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = try TargetImportFiles.copy(received.file)
            return PickedMovie(url: copy)
        }
    }
}

/// SPEC section 9: the target is a guide, not something to copy.
struct TargetGuideNote: View {
    var body: some View {
        Label {
            Text("The target is a guide, not something to copy exactly. Aim for a voice that feels natural and comfortable for you.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "heart.circle")
                .foregroundStyle(Theme.targetZone)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.targetZone.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A saved target voice in the list.
private struct TargetProfileCard: View {
    let target: TargetVoiceProfile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: target.isActive ? "person.wave.2.fill" : "person.wave.2")
                .font(.title2)
                .foregroundStyle(target.isActive ? Theme.targetZone : Color.secondary)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .font(.headline)
                    if target.isActive {
                        Text("Active")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.targetZone.opacity(0.2), in: Capsule())
                    }
                }
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(target.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if let pitch = target.averagePitch {
            parts.append("\(pitch.roundedInt) Hz")
        }
        if let low = target.minimumPitch, let high = target.maximumPitch {
            parts.append("range \(low.roundedInt)–\(high.roundedInt)")
        }
        if let f2 = target.averageF2 {
            parts.append("F2 \(f2.roundedInt)")
        }
        return parts.isEmpty ? "No voice measured" : parts.joined(separator: " · ")
    }
}
