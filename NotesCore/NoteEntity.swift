import AppIntents

// What Siri, Shortcuts, and Spotlight see of a note or folder (Spec 06). These types are `nonisolated` because
// App Intents calls them from its own contexts, while this target is main-actor by default.

public struct NoteEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Note",
        numericFormat: "\(placeholder: .int) notes"
    )
    public static let defaultQuery = NoteEntityQuery()

    /// `Note.id`: minted once, stored with the note, and the same on every device.
    public let id: UUID

    @Property(title: "Title") var title: String
    @Property(title: "Snippet") var snippet: String
    @Property(title: "Modified") var modifiedAt: Date
    @Property(title: "Pinned") var isPinned: Bool
    /// Empty when the note is not in a folder.
    @Property(title: "Folder") var folderName: String
    @Property(title: "Tags") var tags: [String]

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: title.isEmpty ? LocalizedStringResource("Untitled Note") : LocalizedStringResource("\(title)"),
            subtitle: snippet.isEmpty ? nil : LocalizedStringResource("\(snippet)")
        )
    }

    public init(_ info: NoteInfo) {
        id = info.id
        title = info.title
        snippet = info.snippet
        modifiedAt = info.modifiedAt
        isPinned = info.isPinned
        folderName = info.folderName ?? ""
        tags = info.tags
    }
}

public struct NoteEntityQuery: EntityPropertyQuery, EntityStringQuery {
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

    /// One batched fetch for every id. Notes that no longer exist are left out.
    public func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        try await service.notes(withIDs: identifiers).map(NoteEntity.init)
    }

    /// The picker's first choices: the 20 most recently changed notes.
    public func suggestedEntities() async throws -> [NoteEntity] {
        try await service.recentNotes(limit: 20).map(NoteEntity.init)
    }

    /// The framework does not filter for us. This is the same search the app uses.
    public func entities(matching string: String) async throws -> [NoteEntity] {
        try await service.search(string, limit: 25).map(NoteEntity.init)
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
            .map(NoteEntity.init)
    }
}

public struct FolderEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Folder",
        numericFormat: "\(placeholder: .int) folders"
    )
    public static let defaultQuery = FolderEntityQuery()

    public let id: UUID

    @Property(title: "Name") var name: String
    @Property(title: "Notes") var noteCount: Int

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource("\(name)"))
    }

    public init(_ info: FolderInfo) {
        id = info.id
        name = info.name
        noteCount = info.noteCount
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
