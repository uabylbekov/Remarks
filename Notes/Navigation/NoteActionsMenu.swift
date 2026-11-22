import SwiftUI
import SwiftData
import NotesCore

/// Pin, move, tag, and delete actions for one note. Used by the list's context menu and the editor's toolbar.
/// "New Tag…" needs a text prompt, so the caller supplies it.
struct NoteActionsMenu: View {
    let note: Note
    let onNewTag: () -> Void
    let onExport: () -> Void
    let onDeleteForever: () -> Void
    let onError: (String) -> Void

    @Environment(\.modelContext) private var context
    @Query private var folders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]

    private var library: Library { Library(context: context) }

    private var movableFolders: [Folder] {
        folders.filter { $0.deletedAt == nil }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        if note.deletedAt != nil {
            Button("Restore", systemImage: "arrow.uturn.backward") { perform { library.restore(note) } }
            Button("Delete Forever", systemImage: "trash", role: .destructive, action: onDeleteForever)
        } else {
            Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                perform { note.setPinned(!note.isPinned) }
            }
            Menu("Move to", systemImage: "folder") {
                Button("Unfiled", systemImage: "tray") { perform { note.move(to: nil) } }
                ForEach(movableFolders) { folder in
                    Button(folder.path, systemImage: "folder") { perform { note.move(to: folder) } }
                }
            }
            Menu("Tags", systemImage: "tag") {
                ForEach(tags) { tag in
                    Toggle(tag.name, isOn: binding(for: tag))
                }
                Button("New Tag…", systemImage: "plus", action: onNewTag)
            }
            Button("Export as Markdown…", systemImage: "square.and.arrow.up", action: onExport)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { perform { library.trash(note) } }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            try context.save()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func binding(for tag: Tag) -> Binding<Bool> {
        Binding(
            get: { note.tags?.contains { $0 === tag } ?? false },
            set: { isOn in
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
                do {
                    try Library(context: context).addTag(named: text, to: note)
                    try context.save()
                    text = ""
                } catch {
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

/// Asks before a note is deleted for good, which cannot be undone. Set the binding to the note to ask.
private struct DeleteForeverConfirmation: ViewModifier {
    @State private var errorMessage: String?
    @Binding var note: Note?
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this note forever?", item: $note, titleVisibility: .visible) { note in
            Button("Delete Forever", role: .destructive) {
                do {
                    Library(context: context).deleteForever(note)
                    try context.save()
                } catch {
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

    func deleteForeverConfirmation(for note: Binding<Note?>) -> some View {
        modifier(DeleteForeverConfirmation(note: note))
    }
}
