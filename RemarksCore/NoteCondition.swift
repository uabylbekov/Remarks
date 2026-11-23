import Foundation

/// One condition of a "Find Notes where…" filter (Spec 06). Shortcuts parses what the person built into these,
/// and `NotesService.find` runs them. Keeping them in `RemarksCore` makes the rules testable and reusable by MCP.
public enum NoteCondition: Sendable, Equatable {
    case titleEquals(String)
    case titleContains(String)
    case titleHasPrefix(String)
    case modifiedBefore(Date)
    case modifiedAfter(Date)
    case isPinned(Bool)
    case folderNameEquals(String)
    case folderNameContains(String)
    case hasTag(String)

    func matches(_ note: Note) -> Bool {
        switch self {
        case .titleEquals(let value):
            return NoteSearch.equals(note.title, value)
        case .titleContains(let value):
            return NoteSearch.contains(note.title, value)
        case .titleHasPrefix(let value):
            return NoteSearch.hasPrefix(note.title, value)
        case .modifiedBefore(let date):
            return note.modifiedAt < date
        case .modifiedAfter(let date):
            return note.modifiedAt > date
        case .isPinned(let pinned):
            return note.isPinned == pinned
        case .folderNameEquals(let value):
            return NoteSearch.equals(note.folder?.name ?? "", value)
        case .folderNameContains(let value):
            return NoteSearch.contains(note.folder?.name ?? "", value)
        case .hasTag(let value):
            return (note.tags ?? []).contains { NoteSearch.equals($0.name, value) }
        }
    }
}

public struct NoteSort: Sendable, Equatable {
    public enum Key: Sendable, Equatable { case title, modifiedAt, isPinned }

    public let key: Key
    public let ascending: Bool

    public init(_ key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// -1, 0, or 1 for the order of two notes by this key alone.
    func compare(_ lhs: Note, _ rhs: Note) -> Int {
        let result: Int
        switch key {
        case .title:
            result = switch lhs.title.localizedCaseInsensitiveCompare(rhs.title) {
            case .orderedAscending: -1
            case .orderedSame: 0
            case .orderedDescending: 1
            }
        case .modifiedAt:
            result = lhs.modifiedAt < rhs.modifiedAt ? -1 : (lhs.modifiedAt == rhs.modifiedAt ? 0 : 1)
        case .isPinned:
            result = lhs.isPinned == rhs.isPinned ? 0 : (lhs.isPinned ? 1 : -1)
        }
        return ascending ? result : -result
    }
}

extension NoteSearch {
    /// Equal ignoring case and accents, and surrounding spaces.
    public static func equals(_ text: String, _ other: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces)
            .compare(other.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    public static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }
}
