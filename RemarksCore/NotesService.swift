import Foundation
import SwiftData

// The note operations behind App Intents (Spec 06), and later the MCP server and widgets.
// It runs on its own `ModelContext`, off the main actor, and only hands out plain `Sendable` values,
// never `@Model` objects. The rules themselves (trash, restore, folders) stay in `Library`.

/// A note as the outside world sees it. The full text is read separately with `NotesService.text(of:)`.
public struct NoteInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let snippet: String
    public let modifiedAt: Date
    public let isPinned: Bool
    public let folderID: UUID?
    public let folderName: String?
    public let tags: [String]
    public let isTrashed: Bool
    public let createdAt: Date

    init(_ note: Note) {
        id = note.id
        title = note.title
        snippet = note.snippet
        createdAt = note.createdAt
        modifiedAt = note.modifiedAt
        isPinned = note.isPinned
        folderID = note.folder?.id
        folderName = note.folder?.name
        tags = (note.tags ?? []).map(\.name).sorted()
        isTrashed = note.deletedAt != nil
    }
}

public struct FolderInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let noteCount: Int
    public let parentID: UUID?
    public let parentName: String?
}

/// A file that arrived from outside (Siri, Shortcuts), as plain data the service can store on a note.
public struct IncomingFile: Sendable {
    public let data: Data
    public let fileName: String
    public let typeIdentifier: String

    public init(data: Data, fileName: String, typeIdentifier: String) {
        self.data = data
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
    }
}

public enum NotesServiceError: Error, Equatable {
    case noteNotFound
    case noteInTrash
    case folderNotFound
    case attachmentFailed(AttachmentError)
}

public enum AppendPosition: String, Sendable, CaseIterable {
    case start, end
}

@ModelActor
public actor NotesService {
    /// Replaces `ModelContext.save()` so tests can make a save fail; a real failure (a full disk) can't be provoked.
    private var saveOverride: (@Sendable (ModelContext) throws -> Void)?

    func setSaveForTesting(_ save: (@Sendable (ModelContext) throws -> Void)?) {
        saveOverride = save
    }

    /// Writes the changes. A failed save leaves its edits in this long-lived context, where the next call's
    /// successful save would write them although the caller was told they failed.
    private func commit() throws {
        do {
            try (saveOverride ?? { try $0.save() })(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: Create and change

    /// Creates a note. `title`, if given, becomes a first-level heading above the text.
    @discardableResult
    public func createNote(
        text: String,
        title: String? = nil,
        folderID: UUID? = nil,
        isPinned: Bool = false,
        attachments: [IncomingFile] = [],
        now: Date = .now
    ) throws -> NoteInfo {
        // Resolve everything first, then write once (an intent can be run again from the top).
        let folder = try folderID.map { try requireFolder($0) }

        var body = text
        if let title = title.map(Self.singleLine), !title.isEmpty {
            body = text.isEmpty ? "# \(title)\n" : "# \(title)\n\n\(text)"
        }
        let note = Library(context: modelContext).createNote(body: body, in: folder, now: now)
        if isPinned { note.setPinned(true, now: now) }
        do {
            try attach(attachments, to: note, now: now)
        } catch {
            // Nothing is saved yet, so drop the half-made note.
            modelContext.rollback()
            throw error
        }
        try commit()
        return NoteInfo(note)
    }

    /// Changes only what is given: the title (the note's first line), pinning, the folder, or more attachments.
    /// A `nil` folder or title leaves it as it is.
    @discardableResult
    public func update(
        _ id: UUID,
        title: String? = nil,
        isPinned: Bool? = nil,
        folderID: UUID? = nil,
        attachments: [IncomingFile] = [],
        now: Date = .now
    ) throws -> NoteInfo {
        let note = try requireNote(id)
        guard note.deletedAt == nil else { throw NotesServiceError.noteInTrash }
        let folder = try folderID.map { try requireFolder($0) }

        do {
            if let title = title.map(Self.singleLine), !title.isEmpty {
                note.setBody(Self.body(note.body, retitledTo: title), now: now)
            }
            if let isPinned { note.setPinned(isPinned, now: now) }
            if let folder { note.move(to: folder, now: now) }
            try attach(attachments, to: note, now: now)
        } catch {
            modelContext.rollback()
            throw error
        }
        try commit()
        return NoteInfo(note)
    }

    /// A title is one line. Dictated or pasted text can hold line breaks, and those would turn the rest of the title into
    /// body text. Each line is trimmed and the lines are joined with a space.
    static func singleLine(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Replaces the first line with `title`, keeping a heading marker if the line had one.
    static func body(_ body: String, retitledTo title: String) -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "# \(title)\n" }
        let firstBreak = body.firstIndex(of: "\n") ?? body.endIndex
        let first = body[..<firstBreak]
        let rest = body[firstBreak...]
        let hashes = first.prefix { $0 == "#" }
        let isHeading = (1...6).contains(hashes.count) && first.dropFirst(hashes.count).first == " "
        return (isHeading ? "\(hashes) \(title)" : title) + rest
    }

    /// Stores each file on the note and puts its line at the end of the text.
    private func attach(_ files: [IncomingFile], to note: Note, now: Date) throws {
        guard !files.isEmpty else { return }
        let store = AttachmentStore(context: modelContext)
        var body = note.body
        for file in files {
            let attachment: Attachment
            do {
                attachment = try store.add(data: file.data, fileName: file.fileName, typeIdentifier: file.typeIdentifier, to: note, now: now)
            } catch let error as AttachmentError {
                throw NotesServiceError.attachmentFailed(error)
            }
            body += (body.isEmpty || body.hasSuffix("\n\n") ? "" : body.hasSuffix("\n") ? "\n" : "\n\n")
            body += AttachmentStore.markdown(for: attachment) + "\n"
        }
        note.setBody(body, now: now)
    }

    /// Adds text to the start or end of a note. Notes in Recently Deleted are refused, not silently changed.
    @discardableResult
    public func append(_ text: String, to id: UUID, at position: AppendPosition = .end, now: Date = .now) throws -> NoteInfo {
        let note = try requireNote(id)
        guard note.deletedAt == nil else { throw NotesServiceError.noteInTrash }
        guard !text.isEmpty else { return NoteInfo(note) }

        let body = note.body
        let separator = body.isEmpty || body.hasSuffix("\n") ? "" : "\n"
        switch position {
        case .end: note.setBody(body + separator + text, now: now)
        case .start: note.setBody(text + (text.hasSuffix("\n") ? "" : "\n") + body, now: now)
        }
        try commit()
        return NoteInfo(note)
    }

    /// Moves a note to Recently Deleted. Already-trashed notes are left alone, so running it again is safe.
    public func trash(_ id: UUID, now: Date = .now) throws {
        let note = try requireNote(id)
        guard note.deletedAt == nil else { return }
        Library(context: modelContext).trash(note, now: now)
        try commit()
    }

    /// Undoes `trash(_:)`.
    public func restore(_ id: UUID, now: Date = .now) throws {
        let note = try requireNote(id)
        guard note.deletedAt != nil else { return }
        Library(context: modelContext).restore(note, now: now)
        try commit()
    }

    // MARK: Read

    public func info(for id: UUID) throws -> NoteInfo {
        NoteInfo(try requireNote(id))
    }

    /// The Markdown of one note.
    public func text(of id: UUID) throws -> String {
        let note = try requireNote(id)
        guard note.deletedAt == nil else { throw NotesServiceError.noteInTrash }
        return note.body
    }

    /// Resolves many ids with a single fetch. Ids that no longer exist are simply left out.
    public func notes(withIDs ids: [UUID]) throws -> [NoteInfo] {
        guard !ids.isEmpty else { return [] }
        let found = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) }))
        // Keep the order that was asked for.
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { $0.deletedAt == nil }.map(NoteInfo.init)
    }

    /// The Markdown of each note that still exists, by id. One fetch, for entities that carry their text.
    public func texts(withIDs ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let found = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) }))
        return Dictionary(found.filter { $0.deletedAt == nil }.map { ($0.id, $0.body) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every note that is not in Recently Deleted. For Spotlight indexing, which only keeps titles and previews.
    public func liveNotes() throws -> [NoteInfo] {
        try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil })).map(NoteInfo.init)
    }

    /// The most recently changed notes, pinned first. Bounded, so it is cheap to call often.
    public func recentNotes(limit: Int = 20) throws -> [NoteInfo] {
        // A fetch limit of 0 means "no limit" to SwiftData, so ask for nothing explicitly.
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(NoteInfo.init)
    }

    /// Same matching and ranking as the app's search (Spec 04).
    public func search(_ query: String, scope: NoteScope = .all, limit: Int = 50) throws -> [NoteInfo] {
        let live = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))
        // An intent that names a scope means it, so the search stays inside it (the app's list widens to everywhere).
        return NoteFilter.apply(to: live, scope: scope, query: query, searchEverywhere: false)
            .prefix(max(0, limit))
            .map(NoteInfo.init)
    }

    /// "Find Notes where…": conditions combined with AND or OR, then sorted and limited. Newest first by default.
    public func find(
        matching conditions: [NoteCondition],
        matchAll: Bool = true,
        sortedBy sorts: [NoteSort] = [],
        limit: Int? = nil
    ) throws -> [NoteInfo] {
        if let limit, limit <= 0 { return [] }
        let live = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))
        let matching = live.filter { note in
            guard !conditions.isEmpty else { return true }
            return matchAll ? conditions.allSatisfy { $0.matches(note) } : conditions.contains { $0.matches(note) }
        }
        let ordered = matching.sorted { lhs, rhs in
            for sort in sorts {
                let result = sort.compare(lhs, rhs)
                if result != 0 { return result < 0 }
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return ordered.prefix(limit ?? ordered.count).map(NoteInfo.init)
    }

    public func folders() throws -> [FolderInfo] {
        let all = try modelContext.fetch(FetchDescriptor<Folder>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        ))
        return all.map { folder in
            FolderInfo(
                id: folder.id,
                name: folder.name,
                noteCount: (folder.notes ?? []).filter { $0.deletedAt == nil }.count,
                parentID: folder.parent?.id,
                parentName: folder.parent?.name
            )
        }
    }

    public func folders(withIDs ids: [UUID]) throws -> [FolderInfo] {
        let byID = Dictionary(try folders().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    // MARK: Lookup

    private func requireNote(_ id: UUID) throws -> Note {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let note = try modelContext.fetch(descriptor).first else { throw NotesServiceError.noteNotFound }
        return note
    }

    private func requireFolder(_ id: UUID) throws -> Folder {
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })
        descriptor.fetchLimit = 1
        guard let folder = try modelContext.fetch(descriptor).first else { throw NotesServiceError.folderNotFound }
        return folder
    }
}
