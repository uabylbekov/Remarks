import Foundation
import SwiftData

public enum LibraryError: Error, Equatable {
    case emptyName
    case wouldCreateCycle
}

/// The rules from Spec 01 that the store cannot enforce itself under CloudKit: uniqueness, cycle safety,
/// soft deletion, and purging. It works on any `ModelContext`, so the app (main context), App Intents, and
/// background `@ModelActor` wrappers all share one implementation.
public struct Library {
    /// Items stay in Recently Deleted this long before they are purged.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: Notes

    @discardableResult
    public func createNote(body: String = "", in folder: Folder? = nil, now: Date = .now) -> Note {
        let note = Note(body: body, now: now)
        context.insert(note)
        if let folder { note.move(to: folder, now: now) }
        return note
    }

    public func trash(_ note: Note, now: Date = .now) {
        note.deletedAt = now
    }

    /// Restores a note. A note whose folder is still in the trash goes back to Unfiled.
    public func restore(_ note: Note, now: Date = .now) {
        note.deletedAt = nil
        if let folder = note.folder, folder.deletedAt != nil {
            note.move(to: nil, now: now)
        }
    }

    /// Notes with no folder that are not in the trash.
    public func unfiledNotes() throws -> [Note] {
        try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.folder == nil && $0.deletedAt == nil }))
    }

    // MARK: Folders

    @discardableResult
    public func createFolder(named name: String, in parent: Folder? = nil, now: Date = .now) throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }

        let siblings = try siblings(of: parent)
        let folder = Folder(name: trimmed, now: now)
        folder.sortIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
        context.insert(folder)
        folder.parent = parent
        return folder
    }

    /// Rejects moves that would make a folder its own ancestor.
    public func move(_ folder: Folder, to newParent: Folder?) throws {
        if let newParent, newParent.id == folder.id || Self.isDescendant(newParent, of: folder) {
            throw LibraryError.wouldCreateCycle
        }
        folder.parent = newParent
    }

    /// Puts a folder under `parent` (nil is the top level), in front of `sibling`, or at the end when `sibling` is nil.
    /// Rejects moves that would make a folder its own ancestor. Only the moved folder's `sortIndex` changes: it goes
    /// halfway between its new neighbors, and a folder that is already first or last goes one step beyond. If repeated
    /// moves have squeezed the gap too small, the siblings are numbered again.
    public func move(_ folder: Folder, to parent: Folder?, before sibling: Folder?) throws {
        try move(folder, to: parent)

        let others = try siblings(of: parent)
            .filter { $0.id != folder.id && $0.deletedAt == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
        guard let sibling, let index = others.firstIndex(where: { $0.id == sibling.id }) else {
            folder.sortIndex = (others.last?.sortIndex ?? -1) + 1
            return
        }

        let next = others[index].sortIndex
        let previous = index > 0 ? others[index - 1].sortIndex : next - 2
        if next - previous > 1e-6 {
            folder.sortIndex = (previous + next) / 2
        } else {
            var ordered = others
            ordered.insert(folder, at: index)
            for (position, item) in ordered.enumerated() { item.sortIndex = Double(position) }
        }
    }

    /// Cycle-safe: sync could in theory deliver a cycle, so the walk tracks visited folders.
    public static func isDescendant(_ candidate: Folder, of ancestor: Folder) -> Bool {
        var visited: Set<UUID> = []
        var current = candidate.parent
        while let folder = current, visited.insert(folder.id).inserted {
            if folder.id == ancestor.id { return true }
            current = folder.parent
        }
        return false
    }

    /// Soft-deletes a folder, its subfolders, and the notes inside them, all with one timestamp
    /// so `restore(_ folder:)` can undo exactly this operation.
    public func trash(_ folder: Folder, now: Date = .now) {
        for item in Self.subtree(of: folder) {
            if item.deletedAt == nil { item.deletedAt = now }
            for note in item.notes ?? [] where note.deletedAt == nil {
                note.deletedAt = now
            }
        }
    }

    /// Restores the folder subtree and the notes that were trashed together with it.
    /// A folder whose parent is still in the trash goes back to the top level.
    public func restore(_ folder: Folder) {
        guard let stamp = folder.deletedAt else { return }
        for item in Self.subtree(of: folder) {
            if item.deletedAt == stamp { item.deletedAt = nil }
            for note in item.notes ?? [] where note.deletedAt == stamp {
                note.deletedAt = nil
            }
        }
        if let parent = folder.parent, parent.deletedAt != nil {
            folder.parent = nil
        }
    }

    private static func subtree(of root: Folder) -> [Folder] {
        var result: [Folder] = []
        var visited: Set<UUID> = []
        var queue = [root]
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            guard visited.insert(folder.id).inserted else { continue }
            result.append(folder)
            queue.append(contentsOf: folder.children ?? [])
        }
        return result
    }

    private func siblings(of parent: Folder?) throws -> [Folder] {
        if let parent { return parent.children ?? [] }
        return try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.parent == nil }))
    }

    // MARK: Tags

    /// Case- and diacritic-insensitive comparison key for tag names.
    public static func normalized(tagName: String) -> String {
        tagName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Finds the tag with this name (ignoring case and accents) or creates it.
    @discardableResult
    public func tag(named name: String, now: Date = .now) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }

        let key = Self.normalized(tagName: trimmed)
        let existing = try context.fetch(FetchDescriptor<Tag>())
            .filter { Self.normalized(tagName: $0.name) == key }
            .min { Self.isOlder($0, than: $1) }
        if let existing { return existing }

        let tag = Tag(name: trimmed, now: now)
        context.insert(tag)
        return tag
    }

    public func addTag(named name: String, to note: Note, now: Date = .now) throws {
        let tag = try tag(named: name, now: now)
        var tags = note.tags ?? []
        guard !tags.contains(where: { $0 === tag }) else { return }
        tags.append(tag)
        note.tags = tags
    }

    private static func isOlder(_ lhs: Tag, than rhs: Tag) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }

    // MARK: Folder and tag management (Spec 04)

    public func rename(_ folder: Folder, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        folder.name = trimmed
    }

    public func remove(_ tag: Tag, from note: Note) {
        note.tags = (note.tags ?? []).filter { $0 !== tag }
    }

    /// Renames a tag. If another tag already has that name (ignoring case and accents), the two are merged
    /// into the existing one and the existing tag is returned.
    @discardableResult
    public func rename(_ tag: Tag, to name: String) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }

        let key = Self.normalized(tagName: trimmed)
        let existing = try context.fetch(FetchDescriptor<Tag>())
            .first { $0 !== tag && Self.normalized(tagName: $0.name) == key }
        guard let existing else {
            tag.name = trimmed
            return tag
        }
        for note in tag.notes ?? [] {
            var tags = (note.tags ?? []).filter { $0 !== tag }
            if !tags.contains(where: { $0 === existing }) { tags.append(existing) }
            note.tags = tags
        }
        context.delete(tag)
        return existing
    }

    /// Removes a tag from every note. Notes are never deleted.
    public func delete(_ tag: Tag) {
        for note in tag.notes ?? [] { remove(tag, from: note) }
        context.delete(tag)
    }

    /// Permanently deletes one note, for "Delete Forever" in Recently Deleted.
    public func deleteForever(_ note: Note) {
        context.delete(note)
    }

    /// Permanently deletes everything in Recently Deleted.
    @discardableResult
    public func emptyTrash() throws -> (notes: Int, folders: Int) {
        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil }))
        notes.forEach(context.delete)
        let folders = try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.deletedAt != nil }))
        folders.forEach(context.delete)
        return (notes.count, folders.count)
    }

    // MARK: Deduplication (runs after sync imports)

    /// Merges tags with the same normalized name into the oldest one and relinks their notes.
    /// - Returns: how many duplicate tags were removed.
    @discardableResult
    public func dedupeTags() throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<Tag>())) {
            Self.normalized(tagName: $0.name)
        }
        var removed = 0
        for (key, group) in groups where group.count > 1 && !key.isEmpty {
            guard let keeper = group.min(by: Self.isOlder) else { continue }
            for duplicate in group where duplicate !== keeper {
                for note in duplicate.notes ?? [] {
                    var tags = note.tags ?? []
                    tags.removeAll { $0 === duplicate }
                    if !tags.contains(where: { $0 === keeper }) { tags.append(keeper) }
                    note.tags = tags
                }
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    /// Two notes with the same `id` can appear after a rare sync race. Keeps the most recently modified one.
    /// - Returns: how many duplicate notes were removed.
    @discardableResult
    public func dedupeNotes() throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<Note>()), by: \.id)
        var removed = 0
        for group in groups.values where group.count > 1 {
            guard let keeper = group.max(by: { $0.modifiedAt < $1.modifiedAt }) else { continue }
            for duplicate in group where duplicate !== keeper {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    // MARK: Maintenance (Spec 02)

    /// What a maintenance pass changed.
    public struct MaintenanceReport: Equatable, Sendable {
        public var mergedTags = 0
        public var mergedNotes = 0
        public var purgedNotes = 0
        public var purgedFolders = 0
        public var purgedAttachments = 0

        public var changedAnything: Bool {
            mergedTags + mergedNotes + purgedNotes + purgedFolders + purgedAttachments > 0
        }
    }

    /// Cleans up the duplicates that two devices can create at once. Run after each finished sync import.
    @discardableResult
    public func dedupe() throws -> MaintenanceReport {
        var report = MaintenanceReport()
        report.mergedTags = try dedupeTags()
        report.mergedNotes = try dedupeNotes()
        return report
    }

    /// Dedupe plus purging items that have been in the trash for 30 days. Run at launch and once a day.
    @discardableResult
    public func runMaintenance(now: Date = .now) throws -> MaintenanceReport {
        var report = try dedupe()
        let purged = try purgeExpired(now: now)
        report.purgedNotes = purged.notes
        report.purgedFolders = purged.folders
        report.purgedAttachments = try AttachmentStore(context: context).purgeUnreferenced(now: now)
        return report
    }

    // MARK: Purging

    /// Permanently deletes notes and folders that have been in the trash for 30 days or more.
    @discardableResult
    public func purgeExpired(now: Date = .now) throws -> (notes: Int, folders: Int) {
        let cutoff = now.addingTimeInterval(-Self.trashRetention)

        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil }))
            .filter { ($0.deletedAt ?? .distantFuture) <= cutoff }
        notes.forEach(context.delete)

        let folders = try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.deletedAt != nil }))
            .filter { ($0.deletedAt ?? .distantFuture) <= cutoff }
        folders.forEach(context.delete)

        return (notes.count, folders.count)
    }
}
