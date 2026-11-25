import SwiftData
import SwiftUI
import RemarksCore

/// What the iOS and Mac editors do the same way: load and save the note, follow changes made outside the editor
/// (iCloud, Siri, Shortcuts), and drive the live preview. Each platform's coordinator owns its
/// text view and gives the session what it needs through `Host`.
@MainActor
final class EditorSession {
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
        let setEditable: (Bool) -> Void
        /// Puts the caret in the editor, for a new empty note.
        let focus: () -> Void
    }

    /// How long typing must pause before pending edits are persisted.
    private static let saveDelay: Duration = .milliseconds(400)

    private(set) var note: Note
    let commands: EditorCommands?
    private var rendersMarkdown: Bool
    private var pendingRendersMarkdown: Bool?
    private var host: Host?
    private weak var textLayoutManager: NSTextLayoutManager?
    private(set) var preview: LivePreviewController?
    private(set) lazy var catalog = AttachmentCatalog(note: { [unowned self] in self.note })
    private var attachmentSignature = 0
    private var appearanceRevision = AppearanceModel.shared.revision
    private var colorScheme: ColorScheme?
    private var pendingAppearance: (revision: Int, colorScheme: ColorScheme)?
    /// The text last loaded into, or saved from, the editor. See `EditorSync`.
    private var baseBody = ""
    private var saveTask: Task<Void, Never>?
    private var undoObserverTasks: [Task<Void, Never>] = []
    private var hasPendingEdits = false
    private(set) var isApplyingEdit = false
    private var isAdjustingSelection = false
    private weak var observedUndoManager: UndoManager?

    /// Trashed notes (Recently Deleted) and notes requiring a newer app version are read-only.
    var isEditable: Bool {
        !note.isDeleted && note.modelContext != nil && note.deletedAt == nil && note.isReadable
    }

    var onSaveError: ((String) -> Void)?
    var onOpenAttachment: ((RemarksCore.Attachment) -> Void)?
    var onPreviewChanged: ((LivePreviewController?) -> Void)?

    init(note: Note, commands: EditorCommands?, rendersMarkdown: Bool = true) {
        self.note = note
        self.commands = commands
        self.rendersMarkdown = rendersMarkdown
    }

    deinit {
        saveTask?.cancel()
        for task in undoObserverTasks { task.cancel() }
    }

    /// Connects the text view and shows the note. Call last, after the platform has set the view up.
    func attach(host: Host, textLayoutManager: NSTextLayoutManager?) {
        self.host = host
        self.textLayoutManager = textLayoutManager
        catalog.onImageDecoded = { [weak self] id in
            self?.preview?.invalidateAttachment(id)
        }
        configurePreviewIfNeeded()
        load()
    }

    /// Flushes any pending edits and tears down observers, preview delegates, and caches.
    func detach() {
        flushSave()
        saveTask?.cancel()
        saveTask = nil
        cancelUndoObservers()
        preview?.detach()
        preview = nil
        onPreviewChanged?(nil)
        commands?.activeCommands = []
        catalog.reset()
        host = nil
        pendingAppearance = nil
        pendingRendersMarkdown = nil
        textLayoutManager = nil
    }

    /// Dynamically toggles live Markdown rendering without recreating the text view.
    func setRendersMarkdown(_ enabled: Bool) {
        guard host?.isComposing() != true else {
            pendingRendersMarkdown = enabled
            return
        }
        pendingRendersMarkdown = nil
        guard enabled != rendersMarkdown else { return }
        rendersMarkdown = enabled
        if enabled {
            configurePreviewIfNeeded()
            onPreviewChanged?(preview)
            catalog.refreshSnapshot()
            attachmentSignature = catalog.signature
            preview?.reload()
            if let host { preview?.didProgrammaticallyChangeSelection(to: host.selection()) }
            updateActiveCommands()
        } else {
            preview?.detach()
            preview = nil
            onPreviewChanged?(nil)
            host?.applyFont()
            host?.applyBodyStyle()
            updateActiveCommands()
        }
    }

    private func configurePreviewIfNeeded() {
        guard rendersMarkdown, preview == nil,
              let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }
        let controller = LivePreviewController(contentStorage: contentStorage, layoutManager: layoutManager)
        controller.colorScheme = colorScheme ?? .light
        controller.attachmentProvider = { [weak self] in self?.catalog.display(for: $0) }
        controller.isComposing = { [weak self] in self?.host?.isComposing() ?? false }
        preview = controller
    }

    /// Pictures and files pasted into the editor go to the screen around it. Returns false when there is none.
    func paste(_ files: [PastedFile]) -> Bool {
        guard isEditable, let commands else { return false }
        commands.pasted(files)
        return true
    }

    /// Local file URLs pasted from Finder are read asynchronously by `AttachmentPickers`.
    func paste(fileURLs: [URL]) -> Bool {
        guard isEditable, !fileURLs.isEmpty, let commands else { return false }
        commands.pasted(fileURLs: fileURLs)
        return true
    }

    // MARK: Following the note

    /// SwiftUI calls this when the note or its body changes (including changes that arrive by sync).
    func update(note newNote: Note) {
        guard let host, !newNote.isDeleted, newNote.modelContext != nil else { return }
        if note.isDeleted || note.modelContext == nil || newNote.persistentModelID != note.persistentModelID {
            flushSave()
            note = newNote
            load()
        } else {
            syncEditability()
            if note.isReadable, !host.isComposing() { followStoredNote(editorText: host.text()) }
        }
    }

    private func syncEditability() {
        let editable = isEditable
        host?.setEditable(editable)
        commands?.isReadOnly = !editable
        if !editable, commands?.activeCommands.isEmpty == false {
            commands?.activeCommands = []
        }
    }

    /// The stored note may have changed under the editor (iCloud, Siri, Shortcuts). Never replace text the
    /// user has typed, and never lose either side (Spec 06).
    private func followStoredNote(editorText: String) {
        guard !note.isDeleted, note.modelContext != nil, note.isReadable else { return }
        switch EditorSync.decide(editorText: editorText, baseBody: baseBody, incomingBody: note.body) {
        case .keepEditorText:
            // If both sides converged to the same text (e.g. after undo or external sync), advance baseBody
            // so subsequent undo/edit decisions compare against the current stored snapshot.
            if note.body == editorText { baseBody = note.body }
        case .adoptIncoming:
            load()
        case .keepTypedTextAndSaveIncoming:
            preserveUnseenIncomingIfNeeded(editorText: editorText)
            baseBody = note.body
            hasPendingEdits = true
            scheduleSave()
        }
    }

    private func preserveUnseenIncomingIfNeeded(editorText: String) {
        guard EditorSync.unseenTextBeingOverwritten(editorText: editorText, baseBody: baseBody, storedBody: note.body),
              let context = note.modelContext else { return }
        _ = Library(context: context).createRecoveryCopy(of: note)
    }

    private func load() {
        guard let host, !note.isDeleted else { return }
        let body = note.body
        if let preview {
            preview.performProgrammaticUpdate { host.setText(body) }
        } else {
            host.setText(body)
        }
        host.undoManager()?.removeAllActions()
        baseBody = body
        hasPendingEdits = false
        syncEditability()
        catalog.refreshSnapshot()
        attachmentSignature = catalog.signature
        host.applyBodyStyle()
        preview?.reload()
        preview?.didProgrammaticallyChangeSelection(to: host.selection())
        updateActiveCommands()
        #if os(iOS)
        // On macOS, loading a note must preserve focus in the sidebar or note list.
        // An empty body alone does not mean the user asked to start editing.
        if body.isEmpty && isEditable { host.focus() }
        #endif
    }

    /// Re-styles the open note after a font, size, or theme change (Spec 11, S2).
    func applyAppearance(revision: Int, colorScheme: ColorScheme) {
        guard let host else { return }
        guard !host.isComposing() else {
            pendingAppearance = (revision, colorScheme)
            return
        }
        pendingAppearance = nil
        guard revision != appearanceRevision || colorScheme != self.colorScheme else { return }
        appearanceRevision = revision
        self.colorScheme = colorScheme
        preview?.colorScheme = colorScheme
        host.applyFont()
        host.applyBodyStyle()
        preview?.reload()
    }

    /// Pictures can arrive after their note (sync). Draw again when the set of attachments or their data changes.
    func refreshAttachmentsIfChanged() {
        guard !note.isDeleted, note.modelContext != nil else { return }
        let signature = catalog.signature
        guard signature != attachmentSignature else { return }
        attachmentSignature = signature
        catalog.refreshSnapshot()
        preview?.refreshAttachments()
    }

    // MARK: Editing

    /// Runs a formatting command against the current selection. Returns whether an edit was applied.
    @discardableResult
    func perform(_ command: MarkdownCommand) -> Bool {
        guard isEditable, commands?.isEditingTableCell != true, let host else { return false }
        return apply(MarkdownEditing.edit(command, in: host.text(), selection: host.selection()))
    }

    /// Inserts a standalone Markdown block (e.g. an attachment or table), refreshing attachment metadata first.
    func insertBlock(_ markdown: String) {
        guard isEditable, commands?.isEditingTableCell != true, let host else { return }
        refreshAttachmentsIfChanged()
        apply(MarkdownEditing.insertBlock(markdown, in: host.text(), selection: host.selection()))
    }

    /// Handles a native selection change with re-entrancy protection while snapping the caret out of hidden marks.
    func handleSelectionChange(setSelection: (NSRange) -> Void) {
        guard !isApplyingEdit, !isAdjustingSelection, let host, !host.isComposing() else { return }
        finishDeferredUpdates()
        preview?.flushPendingRedrawIfNeeded()
        if let adjusted = preview?.adjustedSelection(to: host.selection()) {
            isAdjustingSelection = true
            setSelection(adjusted)
            isAdjustingSelection = false
        }
        preview?.selectionChanged(to: host.selection())
        updateActiveCommands()
    }

    /// All generated edits share validation and commit handling. Native typing and undo/redo
    /// reach the same commit path through the text view delegate.
    @discardableResult
    func apply(_ edit: TextEdit) -> Bool {
        guard isEditable, !isApplyingEdit, let host, !host.isComposing(),
              let transaction = edit.transaction(in: host.text(), selectionBefore: host.selection()) else { return false }
        observeUndoManager()
        isApplyingEdit = true
        let applied = host.applyEdit(transaction.edit)
        isApplyingEdit = false
        guard applied else { return false }
        preview?.didProgrammaticallyChangeSelection(to: host.selection())
        updateActiveCommands()
        if transaction.changesText { scheduleSave() }
        return true
    }

    private func updateActiveCommands() {
        guard let commands else { return }
        let next: Set<MarkdownCommand> = isEditable ? (preview?.activeFormattingCommands() ?? []) : []
        if commands.activeCommands != next {
            commands.activeCommands = next
        }
    }

    private func cancelUndoObservers() {
        for task in undoObserverTasks { task.cancel() }
        undoObserverTasks.removeAll()
        observedUndoManager = nil
    }

    private func observeUndoManager() {
        guard let manager = host?.undoManager(), manager !== observedUndoManager else { return }
        cancelUndoObservers()
        observedUndoManager = manager
        for name: Notification.Name in [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            let task = Task { @MainActor [weak self, weak manager] in
                guard let manager else { return }
                for await _ in NotificationCenter.default.notifications(named: name, object: manager) {
                    guard !Task.isCancelled else { return }
                    // Native undo may finish without a synchronous text-view delegate callback.
                    self?.textDidChange()
                }
            }
            undoObserverTasks.append(task)
        }
    }

    func textDidChange() {
        guard !isApplyingEdit, let host, !host.isComposing() else { return }
        finishDeferredUpdates()
        preview?.flushPendingRedrawIfNeeded()
        observeUndoManager()
        updateActiveCommands()
        scheduleSave()
    }

    /// Native composition is a transaction: sync and visual updates wait until marked text is committed.
    private func finishDeferredUpdates() {
        guard let host, !host.isComposing() else { return }
        if let enabled = pendingRendersMarkdown { setRendersMarkdown(enabled) }
        if let pending = pendingAppearance {
            applyAppearance(revision: pending.revision, colorScheme: pending.colorScheme)
        }
        followStoredNote(editorText: host.text())
    }

    // MARK: Saving

    /// Writes the editor's text to the note, but only if the user changed it. Saving unchanged text could
    /// undo an outside change the editor has not shown yet.
    private func saveIfTyped(_ text: String) {
        guard isEditable, !note.isDeleted, note.modelContext != nil, text != baseBody else { return }
        preserveUnseenIncomingIfNeeded(editorText: text)
        note.setBody(text)
        baseBody = note.body
        hasPendingEdits = true
    }

    /// Commit already-finished typing before the scene can be suspended; marked text stays native until committed.
    func scenePhaseChanged(to phase: ScenePhase) {
        if phase != .active { flushSave() }
    }

    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let host, !note.isDeleted, note.modelContext != nil, note.isReadable else { return }
        // Don't read uncommitted IME marked text into the model, but still persist any prior committed edits.
        if !host.isComposing() {
            saveIfTyped(host.text())
        }
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }
}
