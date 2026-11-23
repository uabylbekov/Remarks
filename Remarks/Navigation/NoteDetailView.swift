import SwiftUI
import SwiftData
import AppIntents
import RemarksCore

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
                // Tells Siri and Apple Intelligence which note is on screen, so "add this to my note" has a target.
                .appEntityIdentifier(EntityIdentifier(for: NoteEntity.self, identifier: noteID))
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }
}
