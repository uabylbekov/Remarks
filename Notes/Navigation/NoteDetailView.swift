import SwiftUI
import SwiftData
import NotesCore

/// Resolves note identity before creating a fresh editor screen and session.
struct NoteDetailView: View {
    private let noteID: UUID
    private let onDelete: () -> Void
    @Query private var matches: [Note]

    init(id: UUID, onDelete: @escaping () -> Void = {}) {
        self.noteID = id
        self.onDelete = onDelete
        _matches = Query(filter: #Predicate<Note> { $0.id == id })
    }

    var body: some View {
        if let note = matches.first, !note.isDeleted, note.modelContext != nil {
            EditorContainer(note: note, onDelete: onDelete)
                .id(noteID)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }
}
