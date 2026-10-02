import Foundation
import SwiftData
import SwiftUI

/// Debug-screen buttons for trying features without real data.
struct DebugTestingSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isWorking = false
    @State private var message: String?
    @State private var hasSampleData = SampleDataGenerator.hasSampleData

    var body: some View {
        Section {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    Label(hasSampleData ? "Regenerate sample history" : "Generate sample history", systemImage: "wand.and.stars")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)

            if hasSampleData {
                Button("Remove sample history", systemImage: "trash", role: .destructive) {
                    remove()
                }
                .disabled(isWorking)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Testing tools")
        } footer: {
            Text("Sample history adds about 90 days of improving sessions, check-ins, scenario scores and two synthetic recordings for “Then vs Now”, so the Progress tab can be tried out. Only the sample items are removed; your real sessions are never touched.")
        }
    }

    private func generate() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await SampleDataGenerator.generate(in: modelContext)
            message = "Added \(count) sample sessions. Open the Progress tab."
        } catch {
            message = "Sample history couldn’t be created: \(error.localizedDescription)"
        }
        hasSampleData = SampleDataGenerator.hasSampleData
    }

    private func remove() {
        do {
            try SampleDataGenerator.remove(from: modelContext)
            message = "Sample history removed."
        } catch {
            message = "Sample history couldn’t be removed: \(error.localizedDescription)"
        }
        hasSampleData = SampleDataGenerator.hasSampleData
    }
}
