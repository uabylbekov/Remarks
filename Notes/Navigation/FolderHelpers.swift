import Foundation
import SwiftData
import NotesCore

extension Folder {
    /// Navigation and reordering share the List's selection identifier type.
    var sidebarScope: NoteScope { .folder(id) }

    /// A non-empty display label for UI chrome and paths.
    var displayName: String {
        guard !isDeleted, modelContext != nil else { return String(localized: "Untitled") }
        return name.isEmpty ? String(localized: "Untitled") : name
    }

    /// Whether the sidebar lists this folder at the top level: it has no parent, or its parent is in the trash. Sync can
    /// leave a folder inside a trashed one, and it must not vanish from the sidebar until maintenance moves it.
    var isTopLevel: Bool {
        guard !isDeleted, modelContext != nil else { return false }
        guard let parent, !parent.isDeleted, parent.modelContext != nil else { return true }
        return parent.deletedAt != nil
    }

    /// Subfolders that are not in the trash, in manual order. Nil for a leaf, so the sidebar shows no disclosure arrow.
    var childNodes: [Folder]? {
        guard !isDeleted, modelContext != nil else { return nil }
        let kids = (children ?? [])
            .filter { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
        return kids.isEmpty ? nil : kids
    }

    /// Whether this folder currently has any non-trashed subfolders.
    var hasActiveSubfolders: Bool {
        guard !isDeleted, modelContext != nil else { return false }
        return (children ?? []).contains { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }
    }

    /// Notes in this folder that are not in the trash.
    var activeNoteCount: Int {
        guard !isDeleted, modelContext != nil else { return 0 }
        return (notes ?? []).filter { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }.count
    }

    /// For example "Work / Projects". Cycle-safe, because sync could in theory deliver a cycle.
    var path: String {
        guard !isDeleted, modelContext != nil else { return "" }
        var names: [String] = []
        var visited: Set<UUID> = []
        var current: Folder? = self
        while let folder = current, !folder.isDeleted, folder.modelContext != nil, visited.insert(folder.id).inserted {
            names.insert(folder.displayName, at: 0)
            current = folder.parent
        }
        return names.joined(separator: " / ")
    }
}

extension Tag {
    /// Notes carrying this tag that are not in the trash.
    var activeNoteCount: Int {
        guard !isDeleted, modelContext != nil else { return 0 }
        return (notes ?? []).filter { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }.count
    }
}
