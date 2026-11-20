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

    init(_ note: Note) {
        id = note.id
        title = note.title
        snippet = note.snippet
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
}

public enum NotesServiceError: Error, Equatable {
    case noteNotFound
    case noteInTrash
    case folderNotFound
}

public enum AppendPosition: String, Sendable, CaseIterable {
    case start, end
}

@ModelActor
public actor NotesService {
    // MARK: Create and change

    /// Creates a note. `title`, if given, becomes a first-level heading above the text.
    @discardableResult
    public func createNote(text: String, title: String? = nil, folderID: UUID? = nil, now: Date = .now) throws -> NoteInfo {
        // Resolve everything first, then write once (an intent can be run again from the top).
        let folder = try folderID.map { try requireFolder($0) }

        var body = text
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            body = text.isEmpty ? "# \(title)\n" : "# \(title)\n\n\(text)"
        }
        let note = Library(context: modelContext).createNote(body: body, in: folder, now: now)
        try modelContext.save()
        return NoteInfo(note)
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
        try modelContext.save()
        return NoteInfo(note)
    }

    /// Moves a note to Recently Deleted. Already-trashed notes are left alone, so running it again is safe.
    public func trash(_ id: UUID, now: Date = .now) throws {
        let note = try requireNote(id)
        guard note.deletedAt == nil else { return }
        Library(context: modelContext).trash(note, now: now)
        try modelContext.save()
    }

    /// Undoes `trash(_:)`.
    public func restore(_ id: UUID, now: Date = .now) throws {
        let note = try requireNote(id)
        guard note.deletedAt != nil else { return }
        Library(context: modelContext).restore(note, now: now)
        try modelContext.save()
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
            FolderInfo(id: folder.id, name: folder.name, noteCount: (folder.notes ?? []).filter { $0.deletedAt == nil }.count)
        }
    }

    public func folders(withIDs ids: [UUID]) throws -> [FolderInfo] {
        let wanted = Set(ids)
        let all = try folders()
        return ids.compactMap { id in all.first { $0.id == id && wanted.contains($0.id) } }
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
