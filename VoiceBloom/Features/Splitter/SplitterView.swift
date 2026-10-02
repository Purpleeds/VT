import Foundation
import PhotosUI
import SwiftData
import SwiftUI

/// More › Tools › Vocal Splitter (SPEC section 23): import a song or video,
/// split it, and come back to saved splits.
struct SplitterView: View {
    @Query(sort: \SeparatedTrack.createdAt, order: .reverse) private var tracks: [SeparatedTrack]
    @State private var isImportingFile = false
    @State private var photoItem: PhotosPickerItem?
    @State private var source: SplitSource?
    @State private var openTrackID: UUID?
    @State private var isLoading = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Split a song or video into the voice and the music, then practice with either part: sing over the backing, or study the isolated voice.")
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
                        ProgressView("Opening…")
                    }
                    if let importError {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Everything is processed on this iPhone. Separated audio is for your own practice; please respect the rights of the original creators when sharing.")
            }

            Section {
                if tracks.isEmpty {
                    ContentUnavailableView(
                        "No splits yet",
                        systemImage: "waveform.path",
                        description: Text("Import a song or video to split it into vocals and backing.")
                    )
                } else {
                    ForEach(tracks) { track in
                        NavigationLink {
                            StemMixerView(track: track)
                        } label: {
                            SplitTrackRow(track: track)
                        }
                    }
                }
            } header: {
                Text("Saved splits")
            }
        }
        .navigationTitle("Vocal Splitter")
        .navigationDestination(item: $openTrackID) { id in
            SplitTrackDestination(id: id)
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url):
                let title = url.deletingPathExtension().lastPathComponent
                Task {
                    await open(title: title) {
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
                await open(title: "Video from Photos") {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw TargetImportError.copyFailed
                    }
                    return movie.url
                }
            }
        }
        .sheet(item: $source) { source in
            SplitSetupView(source: source) { id in
                self.source = nil
                openTrackID = id
            }
        }
    }

    private func open(title: String, copy: () async throws -> URL) async {
        importError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            source = SplitSource(url: try await copy(), title: title)
        } catch {
            importError = (error as? TargetImportError)?.errorDescription ?? TargetImportError.unreadable.errorDescription
        }
    }
}

/// Opens a saved split by id (after a split finishes).
struct SplitTrackDestination: View {
    let id: UUID
    @Query private var tracks: [SeparatedTrack]

    init(id: UUID) {
        self.id = id
        let wanted = id
        _tracks = Query(filter: #Predicate<SeparatedTrack> { $0.id == wanted })
    }

    var body: some View {
        if let track = tracks.first {
            StemMixerView(track: track)
        } else {
            ContentUnavailableView("Split not found", systemImage: "questionmark.circle", description: Text("It may have been deleted."))
        }
    }
}

private struct SplitTrackRow: View {
    let track: SeparatedTrack

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.sourceType == .video ? "film" : "music.note")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(SessionTime.clock(track.duration)) · \(parts) · \(track.engine.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var parts: String {
        switch (track.vocalsFileName != nil, track.backingFileName != nil) {
        case (true, true): "Vocals and backing"
        case (true, false): "Vocals"
        case (false, true): "Backing"
        case (false, false): "No parts"
        }
    }
}

/// Settings › Split Tracks Storage (SPEC section 23.3).
struct SplitStorageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SeparatedTrack.createdAt, order: .reverse) private var tracks: [SeparatedTrack]
    @State private var isConfirmingDeleteAll = false
    @State private var errorMessage: String?

    private var total: Int64 { tracks.reduce(0) { $0 + $1.totalFileSize } }

    var body: some View {
        List {
            Section {
                LabeledContent("Total", value: StorageFormat.text(total))
            } footer: {
                Text("Each split keeps its vocals, backing and a copy of the original (for video exports). Splits aren’t included in backups.")
            }

            Section {
                if tracks.isEmpty {
                    ContentUnavailableView("No saved splits", systemImage: "externaldrive", description: Text("Splits from the Vocal Splitter appear here."))
                } else {
                    ForEach(tracks) { track in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .lineLimit(1)
                            Text(sizes(track))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text("Splits")
            } footer: {
                if !tracks.isEmpty {
                    Text("Swipe left to delete one.")
                }
            }

            if !tracks.isEmpty {
                Section {
                    Button("Delete All Splits", role: .destructive) {
                        isConfirmingDeleteAll = true
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .navigationTitle("Split Tracks Storage")
        .confirmationDialog("Delete all splits?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                do {
                    try SeparationStore(context: modelContext).deleteAll()
                } catch {
                    errorMessage = "Some splits couldn’t be deleted."
                }
            }
        } message: {
            Text("Frees \(StorageFormat.text(total)). Your original files aren’t touched.")
        }
    }

    private func sizes(_ track: SeparatedTrack) -> String {
        var parts = [StorageFormat.text(track.totalFileSize)]
        if track.vocalsFileSize > 0 {
            parts.append("vocals \(StorageFormat.text(track.vocalsFileSize))")
        }
        if track.backingFileSize > 0 {
            parts.append("backing \(StorageFormat.text(track.backingFileSize))")
        }
        if track.sourceFileSize > 0 {
            parts.append("original \(StorageFormat.text(track.sourceFileSize))")
        }
        return parts.joined(separator: " · ")
    }

    private func delete(at offsets: IndexSet) {
        let store = SeparationStore(context: modelContext)
        for track in offsets.map({ tracks[$0] }) {
            do {
                try store.delete(track)
            } catch {
                errorMessage = "Some splits couldn’t be deleted."
            }
        }
    }
}
