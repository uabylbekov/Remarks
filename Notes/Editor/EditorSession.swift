import SwiftData
import SwiftUI
import NotesCore

/// What the iOS and Mac editors do the same way: load and save the note, follow changes made outside the editor
/// (iCloud, Siri, Shortcuts), and drive the live preview. Each platform's coordinator owns its
/// text view and gives the session what it needs through `Host`.
@MainActor
final class EditorSession: NSObject {
    /// What only the platform's text view can do.
    struct Host {
        let text: () -> String
        let setText: (String) -> Void
        let selection: () -> NSRange
        let isComposing: () -> Bool
        let applyEdit: (TextEdit) -> Bool
        let undoManager: () -> UndoManager?
        let applyFont: () -> Void
        let applyBodyStyle: () -> Void
        /// Puts the caret in the editor, for a new empty note.
        let focus: () -> Void
    }

    /// How long typing must pause before pending edits are persisted.
    private static let saveDelay: Duration = .milliseconds(400)

    private(set) var note: Note
    let commands: EditorCommands?
    private let rendersMarkdown: Bool
    private var host: Host?
    private(set) var preview: LivePreviewController?
    private(set) lazy var catalog = AttachmentCatalog(note: { [unowned self] in self.note })
    private var attachmentSignature = 0
    private var appearanceRevision = AppearanceModel.shared.revision
    /// The text last loaded into, or saved from, the editor. See `EditorSync`.
    private var baseBody = ""
    private var saveTask: Task<Void, Never>?
    private var hasPendingEdits = false
    private(set) var isApplyingEdit = false
    private weak var observedUndoManager: UndoManager?

    var onSaveError: ((String) -> Void)?
    var onOpenAttachment: ((NotesCore.Attachment) -> Void)?

    init(note: Note, commands: EditorCommands?, rendersMarkdown: Bool = true) {
        self.note = note
        self.commands = commands
        self.rendersMarkdown = rendersMarkdown
        super.init()
    }

    /// Connects the text view and shows the note. Call last, after the platform has set the view up.
    func attach(host: Host, textLayoutManager: NSTextLayoutManager?) {
        self.host = host
        if rendersMarkdown, let layoutManager = textLayoutManager,
           let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
            preview = LivePreviewController(contentStorage: contentStorage, layoutManager: layoutManager)
            preview?.attachmentProvider = { [weak self] in self?.catalog.display(for: $0) }
        }
        load()
    }

    /// Pictures and files pasted into the editor go to the screen around it. Returns false when there is none.
    func paste(_ files: [PastedFile]) -> Bool {
        guard let commands else { return false }
        commands.pasted(files)
        return true
    }

    // MARK: Following the note

    /// SwiftUI calls this when the note or its body changes (including changes that arrive by sync).
    func update(note newNote: Note) {
        guard let host else { return }
        if newNote.id != note.id {
            flushSave()
            note = newNote
            load()
        } else {
            followStoredNote(editorText: host.text())
        }
    }

    /// The stored note may have changed under the editor (iCloud, Siri, Shortcuts). Never replace text the
    /// user has typed, and never lose either side (Spec 06).
    private func followStoredNote(editorText: String) {
        switch EditorSync.decide(editorText: editorText, baseBody: baseBody, incomingBody: note.body) {
        case .keepEditorText:
            break
        case .adoptIncoming:
            load()
        case .keepTypedTextAndSaveIncoming:
            baseBody = note.body
        }
    }

    private func load() {
        guard let host else { return }
        host.setText(note.body)
        baseBody = note.body
        host.applyBodyStyle()
        preview?.reload()
        #if os(iOS)
        // On macOS, loading a note must preserve focus in the sidebar or note list.
        // An empty body alone does not mean the user asked to start editing.
        if note.body.isEmpty { host.focus() }
        #endif
    }

    /// Re-styles the open note after a font, size, or theme change (Spec 11, S2).
    func applyAppearance(revision: Int) {
        guard revision != appearanceRevision, let host else { return }
        appearanceRevision = revision
        host.applyFont()
        host.applyBodyStyle()
        preview?.reload()
    }

    /// Pictures can arrive after their note (sync). Draw again when the set of attachments or their data changes.
    func refreshAttachmentsIfChanged() {
        let signature = catalog.signature
        guard signature != attachmentSignature else { return }
        attachmentSignature = signature
        preview?.refreshAttachments()
    }

    // MARK: Editing

    /// All generated edits share validation and commit handling. Native typing and undo/redo
    /// reach the same commit path through the text view delegate.
    @discardableResult
    func apply(_ edit: TextEdit) -> Bool {
        guard !isApplyingEdit, let host, !host.isComposing(),
              let transaction = edit.transaction(in: host.text(), selectionBefore: host.selection()) else { return false }
        observeUndoManager()
        isApplyingEdit = true
        let applied = host.applyEdit(transaction.edit)
        isApplyingEdit = false
        guard applied else { return false }
        preview?.selectionChanged(to: host.selection())
        if transaction.changesText { scheduleSave() }
        return true
    }

    private func observeUndoManager() {
        guard let manager = host?.undoManager(), manager !== observedUndoManager else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: observedUndoManager)
        center.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: observedUndoManager)
        observedUndoManager = manager
        center.addObserver(self, selector: #selector(undoRedoDidComplete(_:)),
                           name: .NSUndoManagerDidUndoChange, object: manager)
        center.addObserver(self, selector: #selector(undoRedoDidComplete(_:)),
                           name: .NSUndoManagerDidRedoChange, object: manager)
    }

    @objc private func undoRedoDidComplete(_ notification: Notification) {
        // Native undo may finish without a synchronous text-view delegate callback.
        textDidChange()
    }

    func textDidChange() {
        guard !isApplyingEdit, let host, !host.isComposing() else { return }
        observeUndoManager()
        scheduleSave()
    }

    // MARK: Saving

    /// Writes the editor's text to the note, but only if the user changed it. Saving unchanged text could
    /// undo an outside change the editor has not shown yet.
    private func saveIfTyped(_ text: String) {
        guard text != baseBody else { return }
        note.setBody(text)
        baseBody = note.body
        hasPendingEdits = true
    }

    func flushSave() {
        saveTask?.cancel()
        guard let host, !host.isComposing() else { return }
        saveIfTyped(host.text())
        guard hasPendingEdits else { return }
        do {
            try note.modelContext?.save()
            hasPendingEdits = false
        } catch {
            // Keep pending edits so ending editing can retry the save.
            onSaveError?(error.localizedDescription)
        }
    }

    func scheduleSave() {
        // The observable note drives list previews immediately; disk writes remain debounced.
        if let host { saveIfTyped(host.text()) }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }
}
