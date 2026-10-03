import Foundation
import PhotosUI
import SwiftData
import SwiftUI

/// Which track a screen shows: a saved upload or a built-in exercise.
nonisolated enum PitchTrackReference: Hashable {
    case saved(UUID)
    case builtIn(BuiltInTrack)
}

/// More › Tools › Pitch Track (SPEC section 22): built-in exercises, tracks
/// made from uploads, and importing a new clip.
struct PitchTrackLibraryView: View {
    @Query(sort: \PitchTrack.createdAt, order: .reverse) private var tracks: [PitchTrack]
    @State private var isImportingFile = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var importError: String?
    @State private var builderClip: ImportedClip?
    @State private var openTrack: PitchTrackReference?

    var body: some View {
        List {
            Section {
                SpeechSingingNote()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Import a clip of someone talking or singing, and Chirp turns it into bars to match.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
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
                    if isLoading {
                        ProgressView("Reading the clip…")
                    }
                    if let importError {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Make a track")
            } footer: {
                Text("MP3, M4A, WAV, MP4 or MOV. Everything is analyzed on this iPhone.")
            }

            Section {
                if tracks.isEmpty {
                    ContentUnavailableView(
                        "No tracks yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Tracks you make from clips appear here.")
                    )
                } else {
                    ForEach(tracks) { track in
                        NavigationLink(value: PitchTrackReference.saved(track.id)) {
                            PitchTrackRow(
                                title: track.name,
                                detail: savedDetail(track),
                                systemImage: track.kind.systemImage
                            )
                        }
                    }
                }
            } header: {
                Text("Your tracks")
            }

            Section {
                ForEach(BuiltInTrack.allCases.filter { !$0.isSpeechPattern }) { track in
                    NavigationLink(value: PitchTrackReference.builtIn(track)) {
                        PitchTrackRow(title: track.title, detail: track.detail, systemImage: track.systemImage)
                    }
                }
            } header: {
                Text("Pitch exercises")
            } footer: {
                Text("Built around your target zone, so they move with you as your targets change.")
            }

            Section {
                ForEach(BuiltInTrack.allCases.filter(\.isSpeechPattern)) { track in
                    NavigationLink(value: PitchTrackReference.builtIn(track)) {
                        PitchTrackRow(title: track.title, detail: track.detail, systemImage: track.systemImage)
                    }
                }
            } header: {
                Text("Speech patterns")
            }

            Section {
                NavigationLink {
                    PitchTrackLatencyView()
                } label: {
                    Label("Timing & Latency", systemImage: "metronome")
                }
            } footer: {
                Text("Bluetooth headphones add a delay. Calibrate once so your timing is scored fairly.")
            }
        }
        .navigationTitle("Pitch Track")
        .navigationDestination(for: PitchTrackReference.self) { reference in
            PitchTrackDetailView(reference: reference)
        }
        .navigationDestination(item: $openTrack) { reference in
            PitchTrackDetailView(reference: reference)
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
        .sheet(item: $builderClip) { clip in
            PitchTrackBuilderView(imported: clip) { id in
                builderClip = nil
                openTrack = .saved(id)
            }
        }
    }

    private func savedDetail(_ track: PitchTrack) -> String {
        var parts = [track.kind.title, SessionTime.clock(track.duration)]
        if let low = track.rangeLowMidi, let high = track.rangeHighMidi {
            parts.append(TrackRange.label(low...high))
        }
        return parts.joined(separator: " · ")
    }

    /// Copies the picked file, decodes it and opens the track builder.
    private func load(name: String, copy: () async throws -> URL) async {
        importError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let local = try await copy()
            do {
                let decoded = try await AudioFileDecoder.decodeInBackground(url: local)
                builderClip = ImportedClip(decoded: decoded, sourceName: name, sourceURL: local)
            } catch {
                TargetImportFiles.remove(local)
                throw error
            }
        } catch {
            importError = (error as? TargetImportError)?.errorDescription ?? TargetImportError.unreadable.errorDescription
        }
    }
}

private struct PitchTrackRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// SPEC section 22.7: singing and speaking use the voice differently.
struct SpeechSingingNote: View {
    var body: some View {
        Label {
            Text("Singing and speaking use the voice differently, and singing high doesn’t automatically make your speaking voice sound more feminine. Speech tracks help most with everyday voice goals; singing tracks are great for pitch control and range.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.targetZone)
        }
    }
}
