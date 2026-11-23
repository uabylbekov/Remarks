import SwiftUI
import SwiftData
import QuickLook
import RemarksCore

/// Owns screen chrome and presentations for exactly one note. The editor surface owns native text input only.
struct EditorContainer: View {
    let note: Note
    var rendersMarkdown = true
    var onDelete: () -> Void = {}
    @Environment(\.modelContext) private var context
    @State private var tagTarget: Note?
    @State private var exportRequest: NoteExportRequest?
    @State private var deleteForeverNoteID: UUID?
    @State private var previewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var commands = EditorCommands()

    private var isLiveNote: Bool {
        !note.isDeleted && note.modelContext != nil
    }

    var body: some View {
        let isTrashed = isLiveNote && note.deletedAt != nil
        EditorViewport {
            NoteEditor(note: note, commands: commands, onOpenAttachment: openAttachment, onSaveError: reportSaveError, rendersMarkdown: rendersMarkdown)
        }
        // A note in Recently Deleted says so in the navigation bar, which the editor already reaches under.
        .navigationSubtitle(isTrashed ? Text("In Recently Deleted") : Text(verbatim: ""))
        .toolbar {
            #if os(macOS)
            // Just left of the note's `…` menu, inside the editor's own toolbar area, with the search field after it.
            FormattingToolbarContent(commands: commands, isEnabled: !isTrashed)
            #endif
            if isTrashed {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Circled, to tell it from the formatting toolbar's own "More" menu beside it on the Mac.
                Menu("Note", systemImage: "ellipsis.circle") {
                    NoteActionsMenu(
                        note: note,
                        onNewTag: { tagTarget = note },
                        onExport: { exportRequest = NoteExportRequest(note: note, format: $0) },
                        onDeleteForever: {
                            guard isLiveNote else { return }
                            deleteForeverNoteID = note.id
                        },
                        onError: { errorMessage = $0 }
                    )
                }
            }
        }
        .focusedSceneValue(\.editorCommands, commands)
        .attachmentPickers(for: note, commands: commands)
        .newTagPrompt(for: $tagTarget)
        .noteExport(for: $exportRequest)
        .deleteForeverConfirmation(for: $deleteForeverNoteID) { _ in onDelete() }
        .quickLookPreview($previewURL)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
        .alert("Unable to Complete Action", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: $0) }
    }

    private func openAttachment(_ attachment: RemarksCore.Attachment) {
        guard let data = attachment.data else { return }
        let id = attachment.id
        let fileName = attachment.fileName
        previewTask?.cancel()
        previewTask = Task {
            let url = await AttachmentFiles.temporaryURLAsync(id: id, fileName: fileName, data: data)
            guard !Task.isCancelled else { return }
            previewURL = url
        }
    }

    private func reportSaveError(_ message: String) {
        // A final save can be reported while SwiftUI dismantles the native editor.
        Task { @MainActor in errorMessage = message }
    }

    private func restore() {
        guard isLiveNote else { return }
        do {
            Library(context: context).restore(note)
            try context.save()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
