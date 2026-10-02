import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A CSV file of every session, written when the user shares it.
nonisolated struct SessionsCSVFile: Transferable, Sendable {
    let rows: [SessionExportRow]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory
                .appending(path: ProgressCSV.fileName(), directoryHint: .notDirectory)
            try ProgressCSV.make(rows: file.rows).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// The picture shared by "Share progress image".
struct ProgressShareCard: View {
    let range: ProgressRange
    let summary: WeeklySummary
    let points: [SessionPoint]

    private var averagePitch: Double? {
        let values = points.compactMap(\.averagePitch)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func average(_ metric: ProgressMetric) -> Double? {
        let values = points.compactMap { $0.value(of: metric) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform")
                    .font(.title2)
                Text("My voice progress")
                    .font(.title2.weight(.bold))
            }
            Text(range.spokenTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                tile("Sessions", "\(points.count)")
                tile("Minutes", "\(Int(points.reduce(0) { $0 + $1.minutes }.rounded()))")
                tile("Avg pitch", averagePitch.map(SessionFormat.hertz) ?? "—")
            }
            HStack(spacing: 12) {
                tile("In target", average(.inTarget).map(SessionFormat.percent) ?? "—")
                tile("Resonance", SessionFormat.score(average(.resonance)))
                tile("Weight", SessionFormat.score(average(.weight)))
            }
            Text("Made with Chirp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .background(Theme.backgroundTint)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Export buttons: CSV of all sessions and a shareable progress picture.
struct ProgressExportCard: View {
    let csv: SessionsCSVFile
    let shareImage: Image?

    var body: some View {
        ChartCard(title: "Export", subtitle: "Your data stays on this iPhone unless you share it.") {
            VStack(spacing: 10) {
                ShareLink(
                    item: csv,
                    preview: SharePreview("Chirp sessions (CSV)", image: Image(systemName: "tablecells"))
                ) {
                    Label("Export All Stats as CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(csv.rows.isEmpty)

                if let shareImage {
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview("My voice progress", image: shareImage)
                    ) {
                        Label("Share Progress Image", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }
}
