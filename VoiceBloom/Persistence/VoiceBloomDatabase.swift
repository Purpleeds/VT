import Foundation
import SwiftData

/// Opens the app's SwiftData store.
nonisolated enum VoiceBloomDatabase {
    nonisolated struct OpenResult {
        let container: ModelContainer
        /// True if the saved data couldn't be opened and an in-memory store is
        /// used instead (practice works, but nothing is kept after quitting).
        let isTemporary: Bool
        let errorDescription: String?
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if !inMemory {
            // The store lives in Application Support, which doesn't exist on a
            // fresh install; creating it first avoids a failed first attempt.
            _ = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        let schema = Schema(versionedSchema: VoiceBloomSchemaV2.self)
        // Local only for now. iCloud sync (private database) is opt-in in a later stage.
        // In-memory stores get their own name so they never share data (tests).
        let configuration = ModelConfiguration(
            inMemory ? "VoiceBloom-\(UUID().uuidString)" : "VoiceBloom",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: VoiceBloomMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// Opens the on-disk store, falling back to memory so the app still works
    /// if the store is damaged. Returns nil only if even that fails.
    static func open() -> OpenResult? {
        do {
            return OpenResult(container: try makeContainer(), isTemporary: false, errorDescription: nil)
        } catch {
            let description = error.localizedDescription
            if let container = try? makeContainer(inMemory: true) {
                return OpenResult(container: container, isTemporary: true, errorDescription: description)
            }
            return nil
        }
    }
}
