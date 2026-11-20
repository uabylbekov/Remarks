import Foundation
import SwiftData

/// Version 1 of the synced schema (Spec 01).
///
/// CloudKit rules applied: no unique constraints, every property has a default or is optional, every
/// relationship is optional with an inverse, and no `.deny` delete rule. After release the schema is
/// additive-only: never delete, rename, or retype a property.
///
/// Models are nested in the schema version so a future `SchemaV2` can keep a frozen copy of these.
/// Use the top-level typealiases (`Note`, `Folder`, `Tag`) everywhere else.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [Note.self, Folder.self, Tag.self, Attachment.self]
    }

    @Model
    public final class Note {
        /// Stable across devices and launches. Used as the App Intents entity id. Not unique-constrained.
        public var id: UUID = UUID()
        /// The Markdown. The only source of truth for content. Change it with `setBody(_:)`.
        public private(set) var body: String = ""
        /// Derived from `body`. Safe to overwrite on conflict.
        public private(set) var title: String = ""
        /// Derived from `body`. Safe to overwrite on conflict.
        public private(set) var snippet: String = ""
        public var createdAt: Date = Date.now
        public private(set) var modifiedAt: Date = Date.now
        public private(set) var isPinned: Bool = false
        /// Non-nil means the note is in Recently Deleted.
        public var deletedAt: Date?
        /// Older app versions must hide notes whose value exceeds what they understand.
        public var minimumReaderVersion: Int = 1
        public private(set) var folder: Folder?
        public var tags: [Tag]?
        /// Files and images the Markdown refers to as `attachment://<id>` (Spec 07).
        @Relationship(deleteRule: .cascade, inverse: \Attachment.note)
        public var attachments: [Attachment]?

        public init(body: String = "", now: Date = .now) {
            self.createdAt = now
            self.modifiedAt = now
            applyBody(body)
        }

        /// The single entry point for body edits, so derived fields and `modifiedAt` never drift.
        public func setBody(_ newBody: String, now: Date = .now) {
            guard newBody != body else { return }
            applyBody(newBody)
            modifiedAt = now
        }

        public func setPinned(_ pinned: Bool, now: Date = .now) {
            guard pinned != isPinned else { return }
            isPinned = pinned
            modifiedAt = now
        }

        public func move(to newFolder: Folder?, now: Date = .now) {
            guard newFolder?.id != folder?.id else { return }
            folder = newFolder
            modifiedAt = now
        }

        private func applyBody(_ newBody: String) {
            body = newBody
            let derived = NoteText.derive(from: newBody)
            title = derived.title
            snippet = derived.snippet
        }
    }

    @Model
    public final class Folder {
        public var id: UUID = UUID()
        public var name: String = ""
        public var createdAt: Date = Date.now
        /// Manual ordering. A `Double` lets us insert between two items without renumbering.
        public var sortIndex: Double = 0
        public var deletedAt: Date?
        public var parent: Folder?

        @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
        public var children: [Folder]?

        @Relationship(deleteRule: .nullify, inverse: \Note.folder)
        public var notes: [Note]?

        public init(name: String = "", now: Date = .now) {
            self.name = name
            self.createdAt = now
        }
    }

    @Model
    public final class Tag {
        public var id: UUID = UUID()
        /// Stored as typed. Compared case- and diacritic-insensitively by `TagService` (not yet written).
        public var name: String = ""
        public var createdAt: Date = Date.now

        @Relationship(deleteRule: .nullify, inverse: \Note.tags)
        public var notes: [Note]?

        public init(name: String = "", now: Date = .now) {
            self.name = name
            self.createdAt = now
        }
    }

    /// A file or image attached to a note (Spec 07). The Markdown in `Note.body` refers to it as `attachment://<id>`.
    @Model
    public final class Attachment {
        /// Referenced from the Markdown. Never changes. Not unique-constrained.
        public var id: UUID = UUID()
        /// The original name, shown on the file chip.
        public var fileName: String = ""
        /// A UTI such as `public.jpeg`. Decides image or file, the icon, and the preview.
        public var typeIdentifier: String = ""
        public var byteCount: Int = 0
        public var createdAt: Date = Date.now
        /// A description of an image, for VoiceOver.
        public var altText: String = ""
        /// Images only, so the editor can reserve the right height before the picture is loaded.
        public var pixelWidth: Int = 0
        public var pixelHeight: Int = 0
        /// Stored outside the database and mirrored by CloudKit as an asset.
        @Attribute(.externalStorage) public var data: Data?
        public var note: Note?

        public init(
            id: UUID = UUID(),
            fileName: String = "",
            typeIdentifier: String = "",
            data: Data? = nil,
            now: Date = .now
        ) {
            self.id = id
            self.fileName = fileName
            self.typeIdentifier = typeIdentifier
            self.data = data
            self.byteCount = data?.count ?? 0
            self.createdAt = now
        }
    }
}

public typealias Note = SchemaV1.Note
public typealias Folder = SchemaV1.Folder
public typealias Tag = SchemaV1.Tag
public typealias Attachment = SchemaV1.Attachment

public enum NotesMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    /// No stages yet. Each future schema version adds one (lightweight for additive changes).
    public static var stages: [MigrationStage] { [] }
}
