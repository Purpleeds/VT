import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Clear Mic copies of saved recordings, made on the fly (SPEC section 24.7).
/// The saved file stays the raw master and is never changed; copies live in
/// the temporary folder and can be deleted at any time.
nonisolated enum EnhancedRecordingCache {
    static let folderName = "ClearMic"
    static let fileName = "Recording with Clear Mic.m4a"

    static func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Where the copy of one recording at one strength goes (a folder each,
    /// so the shared file gets a readable name).
    static func copyURL(id: UUID, strength: ClearMicStrength) throws -> URL {
        let used = ClearMicOffline.parameters(for: strength) == .strong ? "strong" : "light"
        return try directory()
            .appending(path: "\(id.uuidString)-\(used)", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Makes (or reuses) a Clear Mic copy of a recording.
    static func enhancedCopy(of source: URL, id: UUID, strength: ClearMicStrength) throws -> URL {
        let manager = FileManager.default
        let destination = try copyURL(id: id, strength: strength)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            return destination
        }
        let folder = destination.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let clip = try RecordingFileStore.readSamples(from: source)
        let enhanced = ClearMicOffline.enhance(clip, strength: strength)
        // Written under a temporary name and moved into place, so a half-made
        // file is never reused.
        let partial = folder.appending(path: "\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        do {
            try RecordingFileStore.write(enhanced, to: partial)
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: partial, to: destination)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
        return destination
    }

    /// Deletes every Clear Mic copy.
    static func removeAll() {
        let folder = FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// "Share with Clear Mic": the copy is made when the user picks where to
/// send it.
nonisolated struct EnhancedRecordingFile: Transferable, Sendable {
    let source: URL
    let id: UUID
    let strength: ClearMicStrength

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { file in
            let url = try EnhancedRecordingCache.enhancedCopy(of: file.source, id: file.id, strength: file.strength)
            return SentTransferredFile(url)
        }
    }
}
