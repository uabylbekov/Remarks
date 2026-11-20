import Foundation
import SwiftData

/// One factory so the app, App Intents, widgets, and tests all build identical containers (Spec 01).
public enum NotesStore {
    public static let cloudKitContainerID = "iCloud.io.github.uabylbekov.notes"

    public static var schema: Schema {
        Schema(versionedSchema: SchemaV1.self)
    }

    /// - Parameters:
    ///   - inMemory: Use a throwaway store. Never syncs. For tests and previews.
    ///   - syncsWithCloudKit: Sync through the CloudKit private database. Ignored when `inMemory` is true.
    public static func makeContainer(inMemory: Bool = false, syncsWithCloudKit: Bool = true) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if syncsWithCloudKit {
            // Explicit container, so a second container added later cannot change which one is used.
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainerID))
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: NotesMigrationPlan.self, configurations: configuration)
    }
}
