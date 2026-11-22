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
    /// `widenedToAllNotes` is for a search that looks everywhere: every note that is not in Recently Deleted.
    /// Without a search text this selects exactly what `NoteFilter.apply` selects.
    public func predicate(isPinned: Bool, widenedToAllNotes: Bool = false) -> Predicate<Note> {
        switch self {
        case .trash:
            return #Predicate { $0.deletedAt != nil && $0.isPinned == isPinned }
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

    /// A short excerpt of `body` around the first match of any query word, with ellipses where it was cut.
    /// Nil if no word matches the body.
    public static func snippet(in body: String, query: String, radius: Int = 60) -> String? {
        let flattened = body.replacingOccurrences(of: "\n", with: " ")
        for word in words(in: query) {
            guard let match = flattened.localizedStandardRange(of: word) else { continue }
            let start = flattened.index(match.lowerBound, offsetBy: -radius, limitedBy: flattened.startIndex) ?? flattened.startIndex
            let end = flattened.index(match.upperBound, offsetBy: radius, limitedBy: flattened.endIndex) ?? flattened.endIndex
            var excerpt = String(flattened[start..<end]).trimmingCharacters(in: .whitespaces)
            if start > flattened.startIndex { excerpt = "…" + excerpt }
            if end < flattened.endIndex { excerpt += "…" }
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
            return matches(note, scope: scope)
        }

        guard searching else { return ordered(inScope) }

        // Ranking: title matches first, then body and tag matches. Each group keeps newest first.
        var titleMatches: [Note] = []
        var otherMatches: [Note] = []
        for note in inScope {
            let tagNames = (note.tags ?? []).map(\.name)
            let allMatch = words.allSatisfy { word in
                NoteSearch.contains(note.title, word)
                    || NoteSearch.contains(note.body, word)
                    || tagNames.contains { NoteSearch.contains($0, word) }
            }
            guard allMatch else { continue }
            if words.allSatisfy({ NoteSearch.contains(note.title, $0) }) {
                titleMatches.append(note)
            } else {
                otherMatches.append(note)
            }
        }
        let newestFirst: (Note, Note) -> Bool = { $0.modifiedAt > $1.modifiedAt }
        return titleMatches.sorted(by: newestFirst) + otherMatches.sorted(by: newestFirst)
    }

    private static func matches(_ note: Note, scope: NoteScope) -> Bool {
        switch scope {
        case .all: true
        case .unfiled: note.folder == nil
        case .folder(let id): note.folder?.id == id
        case .tag(let id): note.tags?.contains { $0.id == id } ?? false
        case .trash: note.deletedAt != nil
        }
    }

    /// Pinned notes first, then newest modified first.
    private static func ordered(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }
}
