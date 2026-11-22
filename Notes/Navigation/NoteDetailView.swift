import SwiftUI
import SwiftData
import QuickLook
import NotesCore

/// The editor column. Looks the note up by id so it stays live if the note changes by sync.
struct NoteDetailView: View {
    @Query private var matches: [Note]
    @Environment(\.modelContext) private var context
    @State private var tagTarget: Note?
    @State private var exportTarget: Note?
    @State private var deleteForeverTarget: Note?
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var commands = EditorCommands()

    init(id: UUID) {
        _matches = Query(filter: #Predicate<Note> { $0.id == id })
    }

    var body: some View {
        if let note = matches.first {
            NoteEditor(note: note, commands: commands, onOpenAttachment: { previewURL = AttachmentFiles.temporaryURL(for: $0) }, onSaveError: { errorMessage = $0 })
                .safeAreaInset(edge: .top) {
                    if note.deletedAt != nil { deletedBanner(for: note) }
                }
                .toolbar {
                    #if os(macOS)
                    // Just left of the note's `…` menu, inside the editor's own toolbar area, with the search field after it.
                    FormattingToolbarContent(commands: commands)
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Note", systemImage: "ellipsis.circle") {
                            Toggle("Show Markdown", systemImage: "number", isOn: Bindable(commands).showsMarkdown)
                            Divider()
                            NoteActionsMenu(note: note, onNewTag: { tagTarget = note }, onExport: { exportTarget = note }, onDeleteForever: { deleteForeverTarget = note }, onError: { errorMessage = $0 })
                        }
                    }
                }
                .focusedSceneValue(\.editorCommands, commands)
                .attachmentPickers(for: note, commands: commands)
                .newTagPrompt(for: $tagTarget)
                .noteExport(for: $exportTarget)
                .deleteForeverConfirmation(for: $deleteForeverTarget)
                .quickLookPreview($previewURL)
                .alert("Unable to Complete Action", item: $errorMessage) { _ in
                    Button("OK", role: .cancel) {}
                } message: { Text(verbatim: $0) }
                // Reset editor and presentation tasks together when changing notes.
                .id(note.id)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }

    private func deletedBanner(for note: Note) -> some View {
        HStack {
            Label("In Recently Deleted", systemImage: "trash")
            Spacer()
            Button("Restore") {
                do {
                    Library(context: context).restore(note)
                    try context.save()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
