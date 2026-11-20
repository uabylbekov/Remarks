import SwiftUI
import SwiftData
import NotesCore

/// The editor column. Looks the note up by id so it stays live if the note changes by sync.
struct NoteDetailView: View {
    @Query private var matches: [Note]
    @Environment(\.modelContext) private var context
    @State private var tagTarget: Note?
    @State private var historyTarget: Note?
    @State private var commands = EditorCommands()

    init(id: UUID) {
        _matches = Query(filter: #Predicate<Note> { $0.id == id })
    }

    var body: some View {
        if let note = matches.first {
            NoteEditor(note: note, commands: commands)
                // Switching notes must rebuild the editor so text and undo history never leak across notes.
                .id(note.id)
                .safeAreaInset(edge: .top) {
                    if note.deletedAt != nil { deletedBanner(for: note) }
                }
                .toolbar {
                    #if os(macOS)
                    // Just left of the note's `…` menu, inside the editor's own toolbar area, with the search field after it.
                    ToolbarItemGroup(placement: .secondaryAction) {
                        formattingButtons
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Note", systemImage: "ellipsis.circle") {
                            NoteActionsMenu(note: note, onNewTag: { tagTarget = note }, onShowHistory: { historyTarget = note })
                        }
                    }
                }
                .focusedSceneValue(\.editorCommands, commands)
                .attachmentPickers(for: note, commands: commands)
                .newTagPrompt(for: $tagTarget)
                .versionHistorySheet(for: $historyTarget)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }

    #if os(macOS)
    /// The Mac has no keyboard bar, so the same formatting commands live in the window toolbar.
    @ViewBuilder
    private var formattingButtons: some View {
        // The most used first: the system folds the last buttons into the » menu when the window is narrow.
        Button("Heading", systemImage: "h.square") { commands.perform(.heading) }
        Button("Bold", systemImage: "bold") { commands.perform(.bold) }
        Button("Italic", systemImage: "italic") { commands.perform(.italic) }
        Button("Checklist", systemImage: "checklist") { commands.perform(.checklist) }
        Button("Table", systemImage: "tablecells") { commands.perform(.table) }
        Menu("Attach", systemImage: "paperclip") {
            Button("Photo Library…", systemImage: "photo.on.rectangle") { commands.attach(from: .photoLibrary) }
            Button("Choose File…", systemImage: "doc") { commands.attach(from: .file) }
        }
        Button("Bulleted List", systemImage: "list.bullet") { commands.perform(.bulletList) }
        Button("Numbered List", systemImage: "list.number") { commands.perform(.numberedList) }
        Menu("More", systemImage: "ellipsis") {
            Button("Strikethrough", systemImage: "strikethrough") { commands.perform(.strikethrough) }
            Button("Quote", systemImage: "text.quote") { commands.perform(.quote) }
            Button("Inline Code", systemImage: "chevron.left.forwardslash.chevron.right") { commands.perform(.inlineCode) }
            Button("Code Block", systemImage: "curlybraces") { commands.perform(.codeBlock) }
            Button("Link", systemImage: "link") { commands.perform(.link) }
            Button("Format Table", systemImage: "tablecells.badge.ellipsis") { commands.perform(.formatTable) }
        }
    }
    #endif

    private func deletedBanner(for note: Note) -> some View {
        HStack {
            Label("In Recently Deleted", systemImage: "trash")
            Spacer()
            Button("Restore") { Library(context: context).restore(note) }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
