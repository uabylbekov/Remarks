import SwiftUI
import SwiftData
import NotesCore

/// The editor column. Looks the note up by id so it stays live if the note changes by sync.
struct NoteDetailView: View {
    @Query private var matches: [Note]
    @Environment(\.modelContext) private var context
    @State private var tagTarget: Note?
    @State private var historyTarget: Note?

    init(id: UUID) {
        _matches = Query(filter: #Predicate<Note> { $0.id == id })
    }

    var body: some View {
        if let note = matches.first {
            NoteEditor(note: note)
                // Switching notes must rebuild the editor so text and undo history never leak across notes.
                .id(note.id)
                .safeAreaInset(edge: .top) {
                    if note.deletedAt != nil { deletedBanner(for: note) }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Note", systemImage: "ellipsis.circle") {
                            NoteActionsMenu(note: note, onNewTag: { tagTarget = note }, onShowHistory: { historyTarget = note })
                        }
                    }
                }
                .newTagPrompt(for: $tagTarget)
                .versionHistorySheet(for: $historyTarget)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }

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
