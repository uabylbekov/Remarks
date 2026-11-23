import SwiftUI
import SwiftData
import NotesCore

/// Pin, move, tag, and delete actions for one note. Used by the list's context menu and the editor's toolbar.
/// "New Tag…" needs a text prompt, so the caller supplies it.
struct NoteActionsMenu: View {
    let note: Note
    let onNewTag: () -> Void
    let onExport: (NoteExportFormat) -> Void
    let onDeleteForever: () -> Void
    let onError: (String) -> Void

    @Environment(\.modelContext) private var context
    @Query private var folders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]

    private var library: Library { Library(context: context) }

    private var movableFolders: [Folder] {
        folders
            .filter { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var liveTags: [Tag] {
        tags.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    var body: some View {
        if !note.isDeleted, note.modelContext != nil {
            if note.deletedAt != nil {
                Button("Restore", systemImage: "arrow.uturn.backward") { perform { library.restore(note) } }
                Button("Delete Forever", systemImage: "trash", role: .destructive, action: onDeleteForever)
            } else {
                Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                    perform { note.setPinned(!note.isPinned) }
                }
                Menu("Move to", systemImage: "folder") {
                    Picker("Move to", selection: folderBinding) {
                        Label("Unfiled", systemImage: "tray")
                            .tag(UUID?.none)
                        if !movableFolders.isEmpty {
                            Divider()
                            ForEach(movableFolders, id: \.persistentModelID) { folder in
                                Label(folder.path, systemImage: "folder")
                                    .tag(Optional(folder.id))
                            }
                        }
                    }
                    .pickerStyle(.inline)
                }
                Menu("Tags", systemImage: "tag") {
                    ForEach(liveTags) { tag in
                        Toggle(tag.name, isOn: binding(for: tag))
                    }
                    Button("New Tag…", systemImage: "plus", action: onNewTag)
                }
                Menu("Export as", systemImage: "square.and.arrow.up") {
                    ForEach(NoteExportFormat.allCases) { format in
                        Button(format.title, systemImage: format.systemImage) { onExport(format) }
                    }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    perform { library.delete(note) }
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        guard !note.isDeleted, note.modelContext != nil else { return }
        do {
            try action()
            try context.save()
        } catch {
            context.rollback()
            onError(error.localizedDescription)
        }
    }

    private var folderBinding: Binding<UUID?> {
        Binding(
            get: {
                guard !note.isDeleted, note.modelContext != nil,
                      let folder = note.folder, !folder.isDeleted, folder.modelContext != nil else { return nil }
                return folder.id
            },
            set: { targetID in
                let destination = targetID.flatMap { id in movableFolders.first { $0.id == id } }
                perform { note.move(to: destination) }
            }
        )
    }

    private func binding(for tag: Tag) -> Binding<Bool> {
        Binding(
            get: {
                guard !note.isDeleted, note.modelContext != nil, !tag.isDeleted, tag.modelContext != nil else { return false }
                return note.tags?.contains { $0 === tag } ?? false
            },
            set: { isOn in
                guard !tag.isDeleted, tag.modelContext != nil else { return }
                perform {
                    if isOn {
                        try library.addTag(named: tag.name, to: note)
                    } else {
                        library.remove(tag, from: note)
                    }
                }
            }
        )
    }
}

/// Asks for a tag name and adds that tag to the note. Set the binding to the note to show the prompt.
private struct NewTagPrompt: ViewModifier {
    @Binding var note: Note?
    @State private var text = ""
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.alert("New Tag", item: $note) { note in
            TextField("Tag name", text: $text)
            Button("Add") {
                guard !note.isDeleted, note.modelContext != nil else { text = ""; return }
                do {
                    try Library(context: context).addTag(named: text, to: note)
                    try context.save()
                    text = ""
                } catch {
                    context.rollback()
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { text = "" }
        }
        .alert("Unable to Add Tag", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: $0) }
    }
}

/// Asks before a note is deleted for good, which cannot be undone. Holds the note's UUID (not a live `@Model`)
/// so deleting the note while the dialog dismisses can never fault a detached SwiftData backing store.
private struct DeleteForeverConfirmation: ViewModifier {
    @State private var errorMessage: String?
    @Binding var noteID: UUID?
    let onWillDelete: (UUID) -> Void
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this note forever?", item: $noteID, titleVisibility: .visible) { id in
            Button("Delete Forever", role: .destructive) {
                onWillDelete(id)
                do {
                    let matches = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))
                    for note in matches where !note.isDeleted && note.modelContext != nil {
                        Library(context: context).deleteForever(note)
                    }
                    try context.save()
                } catch {
                    context.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        } message: { _ in
            Text("This note can’t be recovered.")
        }
        .alert("Unable to Delete Note", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: $0) }
    }
}

extension View {
    func newTagPrompt(for note: Binding<Note?>) -> some View {
        modifier(NewTagPrompt(note: note))
    }

    func deleteForeverConfirmation(
        for noteID: Binding<UUID?>,
        onWillDelete: @escaping (UUID) -> Void = { _ in }
    ) -> some View {
        modifier(DeleteForeverConfirmation(noteID: noteID, onWillDelete: onWillDelete))
    }
}
