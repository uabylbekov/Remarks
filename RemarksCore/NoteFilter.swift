import Foundation
import SwiftData

/// Where a note list is looking (Spec 04). Virtual folders are queries, not stored data.
public enum NoteScope: Hashable, Sendable {
    case all
    case unfiled
    case folder(UUID)
    case tag(UUID)
    case trash
}

extension NoteScope {
    /// The notes that belong in this scope, as a database predicate, so a `@Query` can load just them.
    /// Use it twice, with `isPinned` true and false, to get pinned notes first without sorting by a `Bool`.
    /// Recently Deleted does not split out a Pinned section: `isPinned: true` matches nothing and `isPinned: false`
    /// selects every trashed note.
    /// `widenedToAllNotes` is for a search that looks everywhere: every note that is not in Recently Deleted.
    /// Without a search text this selects exactly what `NoteFilter.apply` selects.
    public func predicate(isPinned: Bool, widenedToAllNotes: Bool = false) -> Predicate<Note> {
        switch self {
        case .trash:
            if isPinned {
                return #Predicate { $0.deletedAt != nil && $0.deletedAt == nil }
            }
            return #Predicate { $0.deletedAt != nil }
        case .all:
            return #Predicate { $0.deletedAt == nil && $0.isPinned == isPinned }
        case _ where widenedToAllNotes:
            return #Predicate { $0.deletedAt == nil && $0.isPinned == isPinned }
        case .unfiled:
            return #Predicate { $0.deletedAt == nil && $0.folder == nil && $0.isPinned == isPinned }
        case .folder(let id):
            return #Predicate { $0.deletedAt == nil && $0.folder?.id == id && $0.isPinned == isPinned }
        case .tag(let id):
            return #Predicate { $0.deletedAt == nil && $0.tags?.contains { $0.id == id } == true && $0.isPinned == isPinned }
        }
    }

    /// The primary sort order for notes in this scope: Recently Deleted sorts newest-deleted first; all other
    /// scopes sort newest-modified first. Notes with the same time go newest-created first, so rows never swap places.
    public var sortDescriptors: [SortDescriptor<Note>] {
        if self == .trash {
            return [
                SortDescriptor(\Note.deletedAt, order: .reverse),
                SortDescriptor(\Note.modifiedAt, order: .reverse),
                SortDescriptor(\Note.createdAt, order: .reverse),
            ]
        }
        return [
            SortDescriptor(\Note.modifiedAt, order: .reverse),
            SortDescriptor(\Note.createdAt, order: .reverse),
        ]
    }

    /// What a list loads for this scope. Without `includesBody` the Markdown of every note stays on disk until something
    /// asks for it, because a row only needs the title, the preview, and the dates. A search reads the bodies.
    public func fetchDescriptor(isPinned: Bool, widenedToAllNotes: Bool = false, includesBody: Bool = true) -> FetchDescriptor<Note> {
        var descriptor = FetchDescriptor<Note>(
            predicate: predicate(isPinned: isPinned, widenedToAllNotes: widenedToAllNotes),
            sortBy: sortDescriptors
        )
        if !includesBody {
            descriptor.propertiesToFetch = [
                \Note.id, \Note.title, \Note.snippet, \Note.createdAt, \Note.modifiedAt, \Note.isPinned, \Note.deletedAt,
                \Note.minimumReaderVersion,
            ]
        }
        return descriptor
    }

    /// A short text for keeping the place across launches. `init?(storageKey:)` reads it back.
    public var storageKey: String {
        switch self {
        case .all: "all"
        case .unfiled: "unfiled"
        case .trash: "trash"
        case .folder(let id): "folder:\(id.uuidString)"
        case .tag(let id): "tag:\(id.uuidString)"
        }
    }

    /// Nil for anything `storageKey` did not write, such as an old or damaged value.
    public init?(storageKey: String) {
        switch storageKey {
        case "all": self = .all
        case "unfiled": self = .unfiled
        case "trash": self = .trash
        default:
            let parts = storageKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "folder": self = .folder(id)
            case "tag": self = .tag(id)
            default: return nil
            }
        }
    }

    /// The date used for date grouping and row timestamps in this scope.
    public func sortDate(for note: Note) -> Date {
        if self == .trash {
            return note.deletedAt ?? note.modifiedAt
        }
        return note.modifiedAt
    }

    /// Notes in this scope whose derived title is empty — the small candidate set that may be empty notes.
    /// Every empty note has an empty title, so querying these avoids scanning the rest of the scope.
    public var untitledPredicate: Predicate<Note> {
        switch self {
        case .trash:
            return #Predicate { $0.deletedAt != nil && $0.title == "" }
        case .all:
            return #Predicate { $0.deletedAt == nil && $0.title == "" }
        case .unfiled:
            return #Predicate { $0.deletedAt == nil && $0.folder == nil && $0.title == "" }
        case .folder(let id):
            return #Predicate { $0.deletedAt == nil && $0.folder?.id == id && $0.title == "" }
        case .tag(let id):
            return #Predicate { $0.deletedAt == nil && $0.tags?.contains { $0.id == id } == true && $0.title == "" }
        }
    }

    /// Whether `note` belongs to this scope (including trash state and folder or tag membership).
    public func contains(_ note: Note) -> Bool {
        switch self {
        case .trash: note.deletedAt != nil
        case .all: note.deletedAt == nil
        case .unfiled: note.deletedAt == nil && note.folder == nil
        case .folder(let id): note.deletedAt == nil && note.folder?.id == id
        case .tag(let id): note.deletedAt == nil && (note.tags?.contains { $0.id == id } ?? false)
        }
    }
}

public enum NoteSearch {
    /// Splits a query into words. Every word must match.
    public static func words(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether `text` contains `word`, ignoring case and accents. This is the system's own search comparison for
    /// user-facing text, and it is much faster than `range(of:options:)` with the same options.
    public static func contains(_ text: String, _ word: String) -> Bool {
        text.localizedStandardContains(word)
    }

    /// A short plain-text excerpt of `body` around the first match of any query word, with ellipses where it was cut.
    /// Markdown syntax is stripped so previews stay clean. Pass `skippingTitleLine: true` in list rows so title-only
    /// matches don't repeat the title line in the snippet. Nil if no word matches.
    public static func snippet(in body: String, query: String, radius: Int = 60, skippingTitleLine: Bool = false) -> String? {
        let plain = NoteText.plainText(from: body, skippingFirstLine: skippingTitleLine)
        guard !plain.isEmpty else { return nil }
        for word in words(in: query) {
            guard let match = plain.localizedStandardRange(of: word) else { continue }
            let start = plain.index(match.lowerBound, offsetBy: -radius, limitedBy: plain.startIndex) ?? plain.startIndex
            let end = plain.index(match.upperBound, offsetBy: radius, limitedBy: plain.endIndex) ?? plain.endIndex
            var excerpt = String(plain[start..<end]).trimmingCharacters(in: .whitespaces)
            if start > plain.startIndex { excerpt = "…" + excerpt }
            if end < plain.endIndex { excerpt += "…" }
            return excerpt
        }
        return nil
    }
}

/// Filters, searches, and orders notes for the list. Works on any array of notes, so a SwiftUI `@Query`
/// can feed it and the list stays live.
public enum NoteFilter {
    public static func apply(
        to notes: [Note],
        scope: NoteScope,
        query: String = "",
        searchEverywhere: Bool = true
    ) -> [Note] {
        let words = NoteSearch.words(in: query)
        let searching = !words.isEmpty

        // Recently Deleted is searched only when it is selected. Other searches skip the trash.
        let inScope = notes.filter { note in
            if scope == .trash { return note.deletedAt != nil }
            guard note.deletedAt == nil else { return false }
            if searching && searchEverywhere { return true }
            return scope.contains(note)
        }

        let newestFirst: (Note, Note) -> Bool = { lhs, rhs in
            if scope == .trash {
                let lhsDeleted = lhs.deletedAt ?? .distantPast
                let rhsDeleted = rhs.deletedAt ?? .distantPast
                if lhsDeleted != rhsDeleted { return lhsDeleted > rhsDeleted }
            }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.createdAt > rhs.createdAt
        }

        guard searching else {
            if scope == .trash {
                return inScope.sorted(by: newestFirst)
            }
            return ordered(inScope)
        }

        // Ranking: title matches first, then body and tag matches. Each group keeps newest first.
        var titleMatches: [Note] = []
        var otherMatches: [Note] = []
        for note in inScope {
            let tagNames = (note.tags ?? []).map(\.name)
            // The raw Markdown is a quick first check. A match counts only if the word is also in the text a person
            // reads, so attachment ids and link addresses never produce a result with nothing to see. The readable text
            // is worked out once per note, and only for notes that pass the first check.
            var readable: String?
            func inReadableBody(_ word: String) -> Bool {
                guard NoteSearch.contains(note.body, word) else { return false }
                if readable == nil { readable = NoteText.plainText(from: note.body) }
                return NoteSearch.contains(readable ?? "", word)
            }
            let allMatch = words.allSatisfy { word in
                NoteSearch.contains(note.title, word)
                    || inReadableBody(word)
                    || tagNames.contains { NoteSearch.contains($0, word) }
            }
            guard allMatch else { continue }
            if words.allSatisfy({ NoteSearch.contains(note.title, $0) }) {
                titleMatches.append(note)
            } else {
                otherMatches.append(note)
            }
        }
        return titleMatches.sorted(by: newestFirst) + otherMatches.sorted(by: newestFirst)
    }

    /// Pinned notes first, then newest modified first.
    private static func ordered(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
