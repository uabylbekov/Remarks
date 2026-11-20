#if DEBUG
import Foundation
import CoreData
import SwiftData

/// Creates every CloudKit field in the **development** environment up front (Spec 02, schema lifecycle).
/// Without this, optional fields that were never set (such as `deletedAt`) may not exist in the schema yet,
/// and promoting an incomplete schema to production is permanent.
///
/// Run it once from Xcode before a release: add `-InitializeCloudKitSchema` to the scheme's launch
/// arguments, run on a device signed into iCloud, then remove the argument. It must run before the
/// SwiftData container is created, so the app calls it at the very start of launch.
public enum CloudKitSchema {
    public enum SchemaError: Error {
        case noManagedObjectModel
    }

    public static func initialize() throws {
        let configuration = ModelConfiguration(schema: NotesStore.schema, cloudKitDatabase: .private(NotesStore.cloudKitContainerID))

        // An autorelease pool makes sure the Core Data container is deallocated before SwiftData opens the
        // same store, so only one of them syncs it.
        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: configuration.url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: NotesStore.cloudKitContainerID)
            // Load synchronously so loading finishes before the schema is initialized.
            description.shouldAddStoreAsynchronously = false

            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [Note.self, Folder.self, Tag.self, Attachment.self]) else {
                throw SchemaError.noManagedObjectModel
            }
            let container = NSPersistentCloudKitContainer(name: "Notes", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]

            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }

            try container.initializeCloudKitSchema()

            // Unload the store so SwiftData can open it without two frameworks syncing it.
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
}
#endif
