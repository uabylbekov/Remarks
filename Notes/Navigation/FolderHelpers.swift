import Foundation
import NotesCore

extension Folder {
    /// Subfolders that are not in the trash, in manual order. Nil for a leaf, so the sidebar shows no disclosure arrow.
    var childNodes: [Folder]? {
        let kids = (children ?? []).filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
        return kids.isEmpty ? nil : kids
    }

    /// Notes in this folder that are not in the trash.
    var activeNoteCount: Int {
        (notes ?? []).filter { $0.deletedAt == nil }.count
    }

    /// For example "Work / Projects". Cycle-safe, because sync could in theory deliver a cycle.
    var path: String {
        var names: [String] = []
        var visited: Set<UUID> = []
        var current: Folder? = self
        while let folder = current, visited.insert(folder.id).inserted {
            names.insert(folder.name.isEmpty ? "Untitled" : folder.name, at: 0)
            current = folder.parent
        }
        return names.joined(separator: " / ")
    }
}
