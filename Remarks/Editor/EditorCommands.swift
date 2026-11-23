import SwiftUI
import RemarksCore

/// Lets a toolbar outside the editor run formatting commands in it, and lets the editor ask the screen around it for
/// things only SwiftUI can show (a picker for an attachment). The Mac editor connects itself when it appears.
@MainActor
@Observable
final class EditorCommands {
    // Plain hooks the editor sets for itself. Nothing watches them.
    @ObservationIgnored var handler: ((MarkdownCommand) -> Void)?
    /// Puts Markdown on its own line at the caret. Used to insert an attachment.
    @ObservationIgnored var insert: ((String) -> Void)?

    // State the screen around the editor watches (`AttachmentPickers`), instead of closures it has to install.
    /// Set when the user asks to add an attachment from a source. The screen shows the picker and clears it.
    var attachmentRequest: AttachmentSource?
    /// Pictures and files pasted into the editor. The screen turns them into attachments and clears the list.
    var pastedFiles: [PastedFile] = []
    /// Local file URLs pasted from Finder. Read asynchronously off the main thread before inserting.
    var pastedFileURLs: [URL] = []

    /// Document-level commands must not target an old source selection while a nested table field owns input.
    var isEditingTableCell = false
    /// Notes in Recently Deleted are read-only until restored.
    var isReadOnly = false
    /// Formatting commands currently active at the caret or selection, used to highlight toolbar / keyboard bar buttons.
    var activeCommands: Set<MarkdownCommand> = []

    func perform(_ command: MarkdownCommand) {
        guard !isEditingTableCell, !isReadOnly else { return }
        handler?(command)
    }
    func pasted(_ files: [PastedFile]) {
        guard !isReadOnly else { return }
        pastedFiles += files
    }
    func pasted(fileURLs: [URL]) {
        guard !isReadOnly else { return }
        pastedFileURLs += fileURLs
    }
    func insertBlock(_ markdown: String) {
        guard !isEditingTableCell, !isReadOnly else { return }
        insert?(markdown)
    }
    func attach(from source: AttachmentSource) {
        guard !isEditingTableCell, !isReadOnly else { return }
        attachmentRequest = source
    }
}

extension FocusedValues {
    /// The formatting commands of the editor that has focus, for the menu bar.
    @Entry var editorCommands: EditorCommands?
}
