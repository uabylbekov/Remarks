import SwiftUI
import SwiftData
import NotesCore

/// Resolves note identity before creating a fresh editor screen and session.
struct NoteDetailView: View {
    @Query private var matches: [Note]

    init(id: UUID) {
        _matches = Query(filter: #Predicate<Note> { $0.id == id })
    }

    var body: some View {
        if let note = matches.first {
            EditorContainer(note: note)
                .id(note.id)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }
}
