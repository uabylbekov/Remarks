import SwiftUI
import SwiftData
import NotesCore

/// Pin, move, tag, and delete actions for one note. Used by the list's context menu and the editor's toolbar.
/// "New Tag…" needs a text prompt, so the caller supplies it.
struct NoteActionsMenu: View {
    let note: Note
    let onNewTag: () -> Void
    let onShowHistory: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var folders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]

    private var library: Library { Library(context: context) }

    private var movableFolders: [Folder] {
        folders.filter { $0.deletedAt == nil }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        if note.deletedAt != nil {
            Button("Restore", systemImage: "arrow.uturn.backward") { library.restore(note) }
            Button("Delete Forever", systemImage: "trash", role: .destructive) { library.deleteForever(note) }
        } else {
            Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                note.setPinned(!note.isPinned)
            }
            Menu("Move to", systemImage: "folder") {
                Button("Unfiled", systemImage: "tray") { note.move(to: nil) }
                ForEach(movableFolders) { folder in
                    Button(folder.path, systemImage: "folder") { note.move(to: folder) }
                }
            }
            Menu("Tags", systemImage: "tag") {
                ForEach(tags) { tag in
                    Toggle(tag.name, isOn: binding(for: tag))
                }
                Button("New Tag…", systemImage: "plus", action: onNewTag)
            }
            Button("Version History…", systemImage: "clock.arrow.circlepath", action: onShowHistory)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { library.trash(note) }
        }
    }

    private func binding(for tag: Tag) -> Binding<Bool> {
        Binding(
            get: { note.tags?.contains { $0 === tag } ?? false },
            set: { isOn in
                if isOn {
                    try? library.addTag(named: tag.name, to: note)
                } else {
                    library.remove(tag, from: note)
                }
            }
        )
    }
}

/// Asks for a tag name and adds that tag to the note. Set the binding to the note to show the prompt.
private struct NewTagPrompt: ViewModifier {
    @Binding var note: Note?
    @State private var text = ""
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.alert("New Tag", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            TextField("Tag name", text: $text)
            Button("Add") {
                if let note { try? Library(context: context).addTag(named: text, to: note) }
                text = ""
                note = nil
            }
            Button("Cancel", role: .cancel) {
                text = ""
                note = nil
            }
        }
    }
}

extension View {
    func newTagPrompt(for note: Binding<Note?>) -> some View {
        modifier(NewTagPrompt(note: note))
    }
}
