import AppIntents
import CoreSpotlight
import CoreTransferable

// What Siri, Shortcuts, and Spotlight see of a note or folder (Spec 06). These types follow Apple's `notes`
// schemas, so Siri and Apple Intelligence know they are notes, folders, and an account, and can match
// everyday requests like "add this to my wishlist note" to them.

/// Remarks keeps every note in one place, so there is one account. The schema asks for it.
@AppEntity(schema: .notes.account)
public struct AccountEntity {
    public static let defaultQuery = AccountEntityQuery()

    /// Never changes, so saved shortcuts and Siri's memory of the account stay valid. Written as bytes, so there is no
    /// string to parse. This is 5C1B0B3E-6E52-4B33-9B64-0A1B6A52D0A1.
    public static let accountID = UUID(uuid: (
        0x5C, 0x1B, 0x0B, 0x3E, 0x6E, 0x52, 0x4B, 0x33, 0x9B, 0x64, 0x0A, 0x1B, 0x6A, 0x52, 0xD0, 0xA1
    ))
    public static let shared = AccountEntity()

    public let id = AccountEntity.accountID

    var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Remarks")
    }

    public init() {
        name = "Remarks"
    }
}

public struct AccountEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
        identifiers.contains(AccountEntity.accountID) ? [AccountEntity.shared] : []
    }

    public func suggestedEntities() async throws -> [AccountEntity] {
        [AccountEntity.shared]
    }
}

@AppEntity(schema: .notes.note)
public struct NoteEntity: IndexedEntity {
    public static let defaultQuery = NoteEntityQuery()

    /// `Note.id`: minted once, stored with the note, and the same on every device.
    public let id: UUID

    // The schema's properties. `content` is the Markdown, and is only filled in when a note is looked up by id,
    // so it never reaches Spotlight (Spec 06, D1: only the title, the preview, and the tags are indexed).
    var name: AttributedString
    var content: AttributedString?
    var attachments: [IntentFile]
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    var folder: FolderEntity?

    // More for Shortcuts and Spotlight. `title` and `modifiedAt` are plain values that "Find Notes where…" can compare.
    @Property(title: "Title", indexingKey: \.title) var title: String
    @Property(title: "Snippet", indexingKey: \.contentDescription) var snippet: String
    @Property(title: "Modified") var modifiedAt: Date
    /// Empty when the note is not in a folder.
    @Property(title: "Folder Name") var folderName: String
    @Property(title: "Tags", indexingKey: \.keywords) var tags: [String]

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: title.isEmpty ? LocalizedStringResource("Untitled Note", bundle: #bundle) : LocalizedStringResource("\(title)"),
            subtitle: snippet.isEmpty ? nil : LocalizedStringResource("\(snippet)")
        )
    }

    public init(_ info: NoteInfo, content: String? = nil) {
        id = info.id
        name = AttributedString(info.title)
        self.content = content.map { AttributedString($0) }
        attachments = []
        isPinned = info.isPinned
        creationDate = info.createdAt
        modificationDate = info.modifiedAt
        folder = info.folderID.map { FolderEntity(id: $0, name: info.folderName ?? "") }
        title = info.title
        snippet = info.snippet
        modifiedAt = info.modifiedAt
        folderName = info.folderName ?? ""
        tags = info.tags
    }
}

/// Lets Siri and other apps take a note as text, for requests like "send this note to Mail".
/// It is the note's text when the entity has it (a note Siri looked up by id), and the title and preview otherwise.
extension NoteEntity: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { entity in entity.plainText }
    }

    var plainText: String {
        if let content, !content.characters.isEmpty { return String(content.characters) }
        return snippet.isEmpty ? title : "\(title)\n\(snippet)"
    }
}

public struct NoteEntityQuery: EntityPropertyQuery, EntityStringQuery, IndexedEntityQuery {
    public typealias ComparatorMappingType = NoteCondition

    @Dependency var service: NotesService

    public init() {}

    // The properties people can filter by in "Find Notes where…". Shortcuts parses the filter into
    // `NoteCondition`s; `NotesService.find` runs them against the store.
    public static var properties: QueryProperties {
        QueryProperties {
            Property(\.$title) {
                EqualToComparator { NoteCondition.titleEquals($0) }
                ContainsComparator { NoteCondition.titleContains($0) }
                HasPrefixComparator { NoteCondition.titleHasPrefix($0) }
            }
            Property(\.$modifiedAt) {
                LessThanComparator { NoteCondition.modifiedBefore($0) }
                GreaterThanComparator { NoteCondition.modifiedAfter($0) }
            }
            Property(\.$isPinned) {
                EqualToComparator { NoteCondition.isPinned($0) }
            }
            Property(\.$folderName) {
                EqualToComparator { NoteCondition.folderNameEquals($0) }
                ContainsComparator { NoteCondition.folderNameContains($0) }
            }
            Property(\.$tags) {
                ContainsComparator { NoteCondition.hasTag($0) }
            }
        }
    }

    public static var sortingOptions: SortingOptions {
        SortingOptions {
            SortableBy(\.$title)
            SortableBy(\.$modifiedAt)
            SortableBy(\.$isPinned)
        }
    }

    // MARK: Spotlight reindexing (the system asks when its index has a problem)

    public func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        guard SpotlightSettings.isEnabled else { return }
        try await SpotlightIndexer.index(try await service.notes(withIDs: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        guard SpotlightSettings.isEnabled else { return }
        try await SpotlightIndexer.index(try await service.liveNotes())
    }

    /// One batched fetch for every id, with the text, so Siri can read a note it was pointed at.
    /// Notes that no longer exist are left out.
    public func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        let infos = try await service.notes(withIDs: identifiers)
        let texts = try await service.texts(withIDs: infos.map(\.id))
        return infos.map { NoteEntity($0, content: texts[$0.id]) }
    }

    /// The picker's first choices: the 20 most recently changed notes.
    public func suggestedEntities() async throws -> [NoteEntity] {
        try await service.recentNotes(limit: 20).map { NoteEntity($0) }
    }

    /// The framework does not filter for us. This is the same search the app uses.
    public func entities(matching string: String) async throws -> [NoteEntity] {
        try await service.search(string, limit: 25).map { NoteEntity($0) }
    }

    public func entities(
        matching comparators: [NoteCondition],
        mode: ComparatorMode,
        sortedBy: [Sort<NoteEntity>],
        limit: Int?
    ) async throws -> [NoteEntity] {
        let sorts = sortedBy.compactMap { sort -> NoteSort? in
            let ascending = sort.order == .ascending
            if sort.by == \NoteEntity.$title { return NoteSort(.title, ascending: ascending) }
            if sort.by == \NoteEntity.$modifiedAt { return NoteSort(.modifiedAt, ascending: ascending) }
            if sort.by == \NoteEntity.$isPinned { return NoteSort(.isPinned, ascending: ascending) }
            return nil
        }
        return try await service
            .find(matching: comparators, matchAll: mode == .and, sortedBy: sorts, limit: limit)
            .map { NoteEntity($0) }
    }
}

@AppEntity(schema: .notes.folder)
public struct FolderEntity {
    public static let defaultQuery = FolderEntityQuery()

    public let id: UUID

    var name: String
    var parentFolder: FolderEntity?
    var account: AccountEntity?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource("\(name)"))
    }

    /// A folder with just a name, for the folder a note sits in or a folder's parent.
    init(id: UUID, name: String, parent: FolderEntity? = nil) {
        self.id = id
        self.name = name
        parentFolder = parent
        account = AccountEntity.shared
    }

    public init(_ info: FolderInfo) {
        self.init(
            id: info.id,
            name: info.name,
            parent: info.parentID.map { FolderEntity(id: $0, name: info.parentName ?? "") }
        )
    }
}

public struct FolderEntityQuery: EntityStringQuery {
    @Dependency var service: NotesService

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [FolderEntity] {
        try await service.folders(withIDs: identifiers).map(FolderEntity.init)
    }

    /// Folders are few, so offering all of them is fine.
    public func suggestedEntities() async throws -> [FolderEntity] {
        try await service.folders().map(FolderEntity.init)
    }

    public func entities(matching string: String) async throws -> [FolderEntity] {
        try await service.folders()
            .filter { NoteSearch.contains($0.name, string) }
            .map(FolderEntity.init)
    }
}
