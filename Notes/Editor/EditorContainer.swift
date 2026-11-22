import SwiftUI
import SwiftData
import QuickLook
import NotesCore

/// Owns screen chrome and presentations for exactly one note. The editor surface owns native text input only.
struct EditorContainer: View {
    let note: Note
    var rendersMarkdown = true
    @Environment(\.modelContext) private var context
    @State private var tagTarget: Note?
    @State private var exportTarget: Note?
    @State private var deleteForeverTarget: Note?
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var commands = EditorCommands()

    var body: some View {
        EditorViewport {
            NoteEditor(note: note, commands: commands, onOpenAttachment: { previewURL = AttachmentFiles.temporaryURL(for: $0) }, onSaveError: reportSaveError, rendersMarkdown: rendersMarkdown)
        }
        // A note in Recently Deleted says so in the navigation bar, which the editor already reaches under.
        .navigationSubtitle(note.deletedAt != nil ? Text("In Recently Deleted") : Text(verbatim: ""))
        .toolbar {
            #if os(macOS)
            // Just left of the note's `…` menu, inside the editor's own toolbar area, with the search field after it.
            FormattingToolbarContent(commands: commands)
            #endif
            if note.deletedAt != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Circled, to tell it from the formatting toolbar's own "More" menu beside it on the Mac.
                Menu("Note", systemImage: "ellipsis.circle") {
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
    }

    private func reportSaveError(_ message: String) {
        // A final save can be reported while SwiftUI dismantles the native editor.
        Task { @MainActor in errorMessage = message }
    }

    private func restore() {
        do {
            Library(context: context).restore(note)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
