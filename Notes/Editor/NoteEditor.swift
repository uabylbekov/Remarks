import SwiftUI
import ImageIO
import SwiftData
import NotesCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Lets a toolbar outside the editor run formatting commands in it. The Mac editor connects itself when it appears.
@MainActor
final class EditorCommands {
    var handler: ((MarkdownCommand) -> Void)?
    /// Puts Markdown on its own line at the caret. Used to insert an attachment.
    var insert: ((String) -> Void)?
    /// Asks the screen around the editor to pick an attachment from this source. Set by that screen.
    var requestAttachment: ((AttachmentSource) -> Void)?

    func perform(_ command: MarkdownCommand) { handler?(command) }
    func insertBlock(_ markdown: String) { insert?(markdown) }
    func attach(from source: AttachmentSource) { requestAttachment?(source) }
}

extension FocusedValues {
    /// The formatting commands of the editor that has focus, for the menu bar.
    @Entry var editorCommands: EditorCommands?
}

/// The note editor: a TextKit 2 text view with live Markdown preview (Spec 03).
/// The stored text is always the real Markdown. Edits are saved through `Note.setBody` after a short pause,
/// and immediately when editing ends or the editor goes away.
struct NoteEditor: View {
    let note: Note
    /// Where to put the caret when the note first appears. Used by previews, to show a note while editing.
    var initialSelection: Int?
    /// Set by a toolbar that wants to format the text. Used on the Mac.
    var commands: EditorCommands?
    @Environment(\.history) private var history

    @State private var notice: String?

    var body: some View {
        // Reading the revision here makes SwiftUI update the text view whenever an appearance setting changes.
        NoteTextView(
            note: note,
            history: history,
            appearanceRevision: AppearanceModel.shared.revision,
            onKeptEdits: { showNotice() },
            initialSelection: initialSelection,
            commands: commands
        )
        .overlay(alignment: .top) {
            if let notice {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: notice)
    }

    /// The note was changed from outside while you were typing. Your text stays, and the other version
    /// is in Version History.
    private func showNotice() {
        let message = String(localized: "Another change was saved to Version History")
        notice = message
        AccessibilityNotification.Announcement(message).post()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == message { notice = nil }
        }
    }
}

/// How long typing must pause before the text is written to the note.
private let saveDelay: Duration = .milliseconds(400)

#if canImport(UIKit)

// MARK: - iOS and iPadOS

/// Adds hardware-keyboard shortcuts for the formatting commands.
private final class MarkdownUITextView: UITextView {
    var onCommand: ((MarkdownCommand) -> Void)?

    private static let shortcuts: [(title: String, input: String, flags: UIKeyModifierFlags, name: String)] = [
        ("Bold", "b", .command, "bold"),
        ("Italic", "i", .command, "italic"),
        ("Inline Code", "e", .command, "inlineCode"),
        ("Link", "k", .command, "link"),
        ("Code Block", "c", [.command, .alternate], "codeBlock"),
    ]

    override var keyCommands: [UIKeyCommand]? {
        let own = Self.shortcuts.map { shortcut in
            let command = UIKeyCommand(
                title: shortcut.title,
                action: #selector(handleShortcut(_:)),
                input: shortcut.input,
                modifierFlags: shortcut.flags,
                propertyList: shortcut.name
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + own
    }

    @objc private func handleShortcut(_ sender: UIKeyCommand) {
        switch sender.propertyList as? String {
        case "bold": onCommand?(.bold)
        case "italic": onCommand?(.italic)
        case "inlineCode": onCommand?(.inlineCode)
        case "link": onCommand?(.link)
        case "codeBlock": onCommand?(.codeBlock)
        default: break
        }
    }
}

private struct NoteTextView: UIViewRepresentable {
    let note: Note
    let history: HistoryRecorder?
    let appearanceRevision: Int
    let onKeptEdits: () -> Void
    var initialSelection: Int?
    var commands: EditorCommands?

    func makeCoordinator() -> Coordinator { Coordinator(note: note, history: history, commands: commands) }

    func makeUIView(context: Context) -> UITextView {
        // `usingTextLayoutManager: true` selects TextKit 2.
        let textView = MarkdownUITextView(usingTextLayoutManager: true)
        textView.font = EditorTheme.proseFont
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.keyboardDismissMode = .interactive
        // Smart punctuation would turn typed quotes and dashes into characters that break Markdown and code.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.delegate = context.coordinator
        context.coordinator.attach(to: textView)
        if let initialSelection {
            textView.selectedRange = NSRange(location: min(initialSelection, textView.textStorage.length), length: 0)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(note: note)
        context.coordinator.onKeptEdits = onKeptEdits
        context.coordinator.applyAppearance(revision: appearanceRevision)
        context.coordinator.refreshAttachmentsIfChanged()
        commands?.handler = { [weak coordinator = context.coordinator] in coordinator?.perform($0) }
        commands?.insert = { [weak coordinator = context.coordinator] in coordinator?.insertBlock($0) }
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var note: Note
        private weak var textView: MarkdownUITextView?
        private var preview: LivePreviewController?
        private var saveTask: Task<Void, Never>?

        private let history: HistoryRecorder?
        private let commands: EditorCommands?
        private lazy var catalog = AttachmentCatalog(note: { [unowned self] in self.note })
        private var attachmentSignature = 0

        init(note: Note, history: HistoryRecorder?, commands: EditorCommands?) {
            self.history = history
            self.note = note
            self.commands = commands
        }

        func attach(to textView: MarkdownUITextView) {
            self.textView = textView
            textView.onCommand = { [weak self] in self?.perform($0) }
            textView.inputAccessoryView = MarkdownAccessoryView(
                onCommand: { [weak self] in self?.perform($0) },
                onAttach: { [weak self] in self?.commands?.attach(from: $0) },
                onDismiss: { [weak textView] in textView?.resignFirstResponder() }
            )
            if let layoutManager = textView.textLayoutManager,
               let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
                preview = LivePreviewController(contentStorage: contentStorage, layoutManager: layoutManager)
                preview?.attachmentProvider = { [weak self] in self?.catalog.display(for: $0) }
            }

            // A tap on a checkbox toggles it. The recognizer only begins when the tap lands on a box,
            // and the text view's own tap recognizers wait for it, so the caret does not jump to that line.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            textView.addGestureRecognizer(tap)
            for recognizer in textView.gestureRecognizers ?? [] where recognizer !== tap && recognizer is UITapGestureRecognizer {
                recognizer.require(toFail: tap)
            }
            load()
        }

        // MARK: Checkboxes

        private func checklistLine(for gesture: UIGestureRecognizer) -> Int? {
            guard let textView, let preview else { return nil }
            let location = gesture.location(in: textView)
            let inset = textView.textContainerInset
            return preview.checklistLine(at: CGPoint(x: location.x - inset.left, y: location.y - inset.top))
        }

        private func attachmentID(for gesture: UIGestureRecognizer) -> UUID? {
            guard let textView, let preview else { return nil }
            let location = gesture.location(in: textView)
            let inset = textView.textContainerInset
            return preview.attachmentID(at: CGPoint(x: location.x - inset.left, y: location.y - inset.top))
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            checklistLine(for: gestureRecognizer) != nil || attachmentID(for: gestureRecognizer) != nil
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            if let id = attachmentID(for: gesture), let attachment = catalog.attachment(with: id) {
                AttachmentOpener.open(attachment, from: textView)
                return
            }
            guard let line = checklistLine(for: gesture),
                  let edit = MarkdownEditing.toggleChecklist(in: textView.text, atLine: line, keepingSelection: textView.selectedRange)
            else { return }
            apply(edit)
        }

        // MARK: Attachments

        func insertBlock(_ markdown: String) {
            guard let textView else { return }
            apply(MarkdownEditing.insertBlock(markdown, in: textView.text, selection: textView.selectedRange))
        }

        /// Pictures can arrive after their note (sync). Draw again when the set of attachments or their data changes.
        func refreshAttachmentsIfChanged() {
            let signature = catalog.signature
            guard signature != attachmentSignature else { return }
            attachmentSignature = signature
            preview?.refreshAttachments()
        }

        private var appearanceRevision = AppearanceModel.shared.revision
        /// The text last loaded into, or saved from, the editor. See `EditorSync`.
        private var baseBody = ""
        var onKeptEdits: (() -> Void)?

        /// Re-styles the open note after a font, size, or theme change (Spec 11, S2).
        func applyAppearance(revision: Int) {
            guard revision != appearanceRevision, let textView else { return }
            appearanceRevision = revision
            textView.font = EditorTheme.proseFont
            preview?.reload()
        }

        /// SwiftUI re-evaluates this when the note or its body changes (including changes that arrive by sync).
        func update(note newNote: Note) {
            guard let textView else { return }
            if newNote.id != note.id {
                flushSave()
                note = newNote
                load()
            } else {
                followStoredNote(editorText: textView.text)
            }
        }

        /// The stored note may have changed under the editor (iCloud, Siri, Shortcuts). Never replace text the
        /// user has typed, and never lose either side (Spec 06).
        private func followStoredNote(editorText: String) {
            switch EditorSync.decide(editorText: editorText, baseBody: baseBody, incomingBody: note.body) {
            case .keepEditorText:
                break
            case .adoptIncoming:
                // Keep the text that is about to be replaced (Spec 02, S2).
                history?.record(noteID: note.id, body: editorText, reason: .beforeSyncUpdate, force: true)
                load()
            case .keepTypedTextAndSaveIncoming:
                history?.record(noteID: note.id, body: note.body, reason: .otherVersion, force: true)
                baseBody = note.body
                onKeptEdits?()
            }
        }

        private func load() {
            guard let textView else { return }
            textView.text = note.body
            baseBody = note.body
            preview?.reload()
            if note.body.isEmpty {
                // A new note is ready to type into.
                DispatchQueue.main.async { textView.becomeFirstResponder() }
            }
        }

        // MARK: Saving

        /// Writes the editor's text to the note, but only if the user changed it. Saving unchanged text could
        /// undo an outside change the editor has not shown yet. Text the editor never saw is kept as a version first.
        private func saveIfTyped(_ text: String) {
            guard text != baseBody else { return }
            if EditorSync.unseenTextBeingOverwritten(editorText: text, baseBody: baseBody, storedBody: note.body) {
                history?.record(noteID: note.id, body: note.body, reason: .otherVersion, force: true)
            }
            note.setBody(text)
            baseBody = note.body
            history?.record(noteID: note.id, body: note.body, reason: .edit)
        }

        func flushSave() {
            saveTask?.cancel()
            guard let textView else { return }
            saveIfTyped(textView.text)
        }

        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: saveDelay)
                guard !Task.isCancelled else { return }
                flushSave()
            }
        }

        // MARK: Formatting

        func perform(_ command: MarkdownCommand) {
            guard let textView else { return }
            apply(MarkdownEditing.edit(command, in: textView.text, selection: textView.selectedRange))
        }

        /// `replace(_:withText:)` goes through the text input system, so undo and redo keep working.
        private func apply(_ edit: TextEdit) {
            guard let textView,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            textView.replace(range, withText: edit.replacement)
            textView.selectedRange = edit.selection
        }

        // MARK: UITextViewDelegate

        /// Return continues a list or checklist, and ends it on an empty item. Code blocks and text being
        /// composed (Japanese, Chinese, and so on) keep the default behavior.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", range.length == 0, textView.markedTextRange == nil,
                  preview?.isInCodeBlock(range.location) != true,
                  let edit = MarkdownEditing.returnKeyEdit(in: textView.text, selection: range)
            else { return true }
            apply(edit)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            scheduleSave()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            preview?.selectionChanged(to: textView.selectedRange.location)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            flushSave()
        }
    }
}

#else

// MARK: - macOS

/// A text view that passes clicks on a checklist box to the editor before it moves the caret.
final class MarkdownNSTextView: NSTextView {
    var onCheckboxClick: ((CGPoint) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if onCheckboxClick?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }
}

private struct NoteTextView: NSViewRepresentable {
    let note: Note
    let history: HistoryRecorder?
    let appearanceRevision: Int
    let onKeptEdits: () -> Void
    var initialSelection: Int?
    var commands: EditorCommands?

    func makeCoordinator() -> Coordinator { Coordinator(note: note, history: history) }

    func makeNSView(context: Context) -> NSScrollView {
        // The same setup `NSTextView.scrollableTextView()` does, but with our own subclass.
        let textView = MarkdownNSTextView(usingTextLayoutManager: true)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.font = EditorTheme.proseFont
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        // Smart punctuation would turn typed quotes and dashes into characters that break Markdown and code.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        context.coordinator.attach(to: textView)
        if let initialSelection {
            textView.setSelectedRange(NSRange(location: min(initialSelection, textView.string.utf16.count), length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(note: note)
        context.coordinator.onKeptEdits = onKeptEdits
        context.coordinator.applyAppearance(revision: appearanceRevision)
        context.coordinator.refreshAttachmentsIfChanged()
        commands?.handler = { [weak coordinator = context.coordinator] in coordinator?.perform($0) }
        commands?.insert = { [weak coordinator = context.coordinator] in coordinator?.insertBlock($0) }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var note: Note
        private weak var textView: NSTextView?
        private var preview: LivePreviewController?
        private lazy var catalog = AttachmentCatalog(note: { [unowned self] in self.note })
        private var attachmentSignature = 0
        private var saveTask: Task<Void, Never>?

        private let history: HistoryRecorder?

        init(note: Note, history: HistoryRecorder?) {
            self.history = history
            self.note = note
        }

        func attach(to textView: NSTextView) {
            self.textView = textView
            if let layoutManager = textView.textLayoutManager,
               let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
                preview = LivePreviewController(contentStorage: contentStorage, layoutManager: layoutManager)
                preview?.attachmentProvider = { [weak self] in self?.catalog.display(for: $0) }
            }
            (textView as? MarkdownNSTextView)?.onCheckboxClick = { [weak self] point in self?.handleClick(at: point) ?? false }
            load()
        }

        private var appearanceRevision = AppearanceModel.shared.revision
        /// The text last loaded into, or saved from, the editor. See `EditorSync`.
        private var baseBody = ""
        var onKeptEdits: (() -> Void)?

        /// Re-styles the open note after a font, size, or theme change (Spec 11, S2).
        func applyAppearance(revision: Int) {
            guard revision != appearanceRevision, let textView else { return }
            appearanceRevision = revision
            textView.font = EditorTheme.proseFont
            preview?.reload()
        }

        func update(note newNote: Note) {
            guard let textView else { return }
            if newNote.id != note.id {
                flushSave()
                note = newNote
                load()
            } else {
                followStoredNote(editorText: textView.string)
            }
        }

        /// The stored note may have changed under the editor (iCloud, Siri, Shortcuts). Never replace text the
        /// user has typed, and never lose either side (Spec 06).
        private func followStoredNote(editorText: String) {
            switch EditorSync.decide(editorText: editorText, baseBody: baseBody, incomingBody: note.body) {
            case .keepEditorText:
                break
            case .adoptIncoming:
                // Keep the text that is about to be replaced (Spec 02, S2).
                history?.record(noteID: note.id, body: editorText, reason: .beforeSyncUpdate, force: true)
                load()
            case .keepTypedTextAndSaveIncoming:
                history?.record(noteID: note.id, body: note.body, reason: .otherVersion, force: true)
                baseBody = note.body
                onKeptEdits?()
            }
        }

        private func load() {
            guard let textView else { return }
            textView.string = note.body
            baseBody = note.body
            preview?.reload()
            if note.body.isEmpty {
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        }

        // MARK: Saving

        /// Writes the editor's text to the note, but only if the user changed it. Saving unchanged text could
        /// undo an outside change the editor has not shown yet. Text the editor never saw is kept as a version first.
        private func saveIfTyped(_ text: String) {
            guard text != baseBody else { return }
            if EditorSync.unseenTextBeingOverwritten(editorText: text, baseBody: baseBody, storedBody: note.body) {
                history?.record(noteID: note.id, body: note.body, reason: .otherVersion, force: true)
            }
            note.setBody(text)
            baseBody = note.body
            history?.record(noteID: note.id, body: note.body, reason: .edit)
        }

        func flushSave() {
            saveTask?.cancel()
            guard let textView else { return }
            saveIfTyped(textView.string)
        }

        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: saveDelay)
                guard !Task.isCancelled else { return }
                flushSave()
            }
        }

        // MARK: Formatting

        /// A click on a checkbox toggles it, and a click on an attachment opens it. Returns true when the click was
        /// one of those, so the caret does not move to that line.
        private func handleClick(at location: CGPoint) -> Bool {
            guard let textView else { return false }
            let origin = textView.textContainerOrigin
            let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
            if let id = preview?.attachmentID(at: point), let attachment = catalog.attachment(with: id) {
                AttachmentOpener.open(attachment, from: textView)
                return true
            }
            guard let line = preview?.checklistLine(at: point),
                  let edit = MarkdownEditing.toggleChecklist(in: textView.string, atLine: line, keepingSelection: textView.selectedRange())
            else { return false }
            apply(edit)
            return true
        }

        func perform(_ command: MarkdownCommand) {
            guard let textView else { return }
            apply(MarkdownEditing.edit(command, in: textView.string, selection: textView.selectedRange()))
        }

        // MARK: Attachments

        func insertBlock(_ markdown: String) {
            guard let textView else { return }
            apply(MarkdownEditing.insertBlock(markdown, in: textView.string, selection: textView.selectedRange()))
        }

        /// Pictures can arrive after their note (sync). Draw again when the set of attachments or their data changes.
        func refreshAttachmentsIfChanged() {
            let signature = catalog.signature
            guard signature != attachmentSignature else { return }
            attachmentSignature = signature
            preview?.refreshAttachments()
        }

        private func apply(_ edit: TextEdit) {
            guard let textView else { return }
            // `shouldChangeText` registers the change with the undo manager.
            if textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.didChangeText()
            }
            textView.setSelectedRange(edit.selection)
        }

        // MARK: NSTextViewDelegate

        /// Return continues a list or checklist, and ends it on an empty item. Code blocks and text being
        /// composed keep the default behavior.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            guard preview?.isInCodeBlock(selection.location) != true,
                  let edit = MarkdownEditing.returnKeyEdit(in: textView.string, selection: selection)
            else { return false }
            apply(edit)
            return true
        }

        func textDidChange(_ notification: Notification) {
            scheduleSave()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            preview?.selectionChanged(to: textView.selectedRange().location)
        }

        func textDidEndEditing(_ notification: Notification) {
            flushSave()
        }
    }
}

#endif

#Preview("Editor") {
    let container = previewContainer()
    let note = Note(body: """
    # Project notes

    Some prose with **bold**, _italic_, ~~strike~~, `inline code`, and a [link](https://example.com).

    ```swift
    // Fetch a note
    func note(id: Int) async throws -> Note {
        let (data, _) = try await URLSession.shared.data(from: url)

        return try JSONDecoder().decode(Note.self, from: data)
    }
    ```

    ## Next
    - [ ] try the keyboard bar
    - [x] write the spec
    - plain bullet

    > a quote
    """)
    container.mainContext.insert(note)
    return NoteEditor(note: note).modelContainer(container)
}

#Preview("Reading a code block") {
    codeBlockPreview(editing: false)
}

#Preview("Editing in a code block") {
    codeBlockPreview(editing: true)
}

/// The same note twice, so the card can be compared with the cursor outside and inside it.
@MainActor
private func codeBlockPreview(editing: Bool) -> some View {
    let container = previewContainer()
    let body = """
    # Project notes

    ```swift
    // Fetch a note
    func note(id: Int) async throws -> Note {
        let (data, _) = try await URLSession.shared.data(from: url)

        return try JSONDecoder().decode(Note.self, from: data)
    }
    ```

    After the code.
    """
    let note = Note(body: body)
    container.mainContext.insert(note)
    // Inside the block, so its fences show.
    let caret = (body as NSString).range(of: "func note").location
    return NoteEditor(note: note, initialSelection: editing ? caret : nil).modelContainer(container)
}

/// An empty in-memory store for the previews above.
@MainActor
private func previewContainer() -> ModelContainer {
    do {
        return try NotesStore.makeContainer(inMemory: true)
    } catch {
        fatalError("in-memory container failed: \(error)")
    }
}

/// A code block with blank lines at its start, middle (two in a row), and end, to check spacing in both states.
@MainActor
private func blankLinesPreview(editing: Bool) -> some View {
    let container = previewContainer()
    let body = "Before\n\n```swift\n\nlet a = 1\n\n\nlet b = 2\n\n```\n\nAfter"
    let note = Note(body: body)
    container.mainContext.insert(note)
    let caret = (body as NSString).range(of: "let a").location
    return NoteEditor(note: note, initialSelection: editing ? caret : nil).modelContainer(container)
}

#Preview("Blank lines, reading") { blankLinesPreview(editing: false) }
#Preview("Blank lines, editing") { blankLinesPreview(editing: true) }

/// Typing a block: the fence is open and the caret sits on a new empty last line.
@MainActor
private func typingBlockPreview(body: String) -> some View {
    let container = previewContainer()
    let note = Note(body: body)
    container.mainContext.insert(note)
    return NoteEditor(note: note, initialSelection: (body as NSString).length).modelContainer(container)
}

#Preview("Typing: open fence + Return") { typingBlockPreview(body: "Before\n\n```swift\n") }
#Preview("Typing: code line + Return") { typingBlockPreview(body: "Before\n\n```swift\nlet a = 1\n") }
#Preview("Typing: second line has a character") { typingBlockPreview(body: "Before\n\n```swift\nlet a = 1\nx") }

/// A block written right against its neighboring text, with no blank lines, to check the spacing around the card.
@MainActor
private func tightBlockPreview(editing: Bool) -> some View {
    let container = previewContainer()
    let body = "First line of text\n```swift\nlet a = 1\n```\nLast line of text"
    let note = Note(body: body)
    container.mainContext.insert(note)
    let caret = (body as NSString).range(of: "let a").location
    return NoteEditor(note: note, initialSelection: editing ? caret : nil).modelContainer(container)
}

#Preview("Tight block, reading") { tightBlockPreview(editing: false) }
#Preview("Tight block, editing") { tightBlockPreview(editing: true) }

// Typing comparisons: each pair differs by one typed character, with the caret at the end.
#Preview("Shift A1: below a block, empty line") { typingBlockPreview(body: "First\n```swift\nlet a = 1\n```\n") }
#Preview("Shift A2: below a block, typed x") { typingBlockPreview(body: "First\n```swift\nlet a = 1\n```\nx") }
#Preview("Shift B1: unclosed, last line") { typingBlockPreview(body: "First\n```swift\nlet a = 1") }
#Preview("Shift B2: unclosed, after Return") { typingBlockPreview(body: "First\n```swift\nlet a = 1\n") }

#Preview("Attachments") {
    let container = previewContainer()
    let context = container.mainContext
    let note = Library(context: context).createNote()

    // A generated picture and a file, added the same way the app adds them.
    let store = AttachmentStore(context: context)
    let pictureData = previewPicture(width: 800, height: 500)
    let picture = try? store.add(data: pictureData, fileName: "Beach.png", typeIdentifier: "public.png", to: note)
    let file = try? store.add(data: Data(count: 2_400_000), fileName: "Quarterly plan.pdf", typeIdentifier: "com.adobe.pdf", to: note)

    note.setBody("""
    # Trip notes

    Photos from the first day:
    \(picture.map { AttachmentStore.markdown(for: $0) } ?? "")
    The plan is attached:
    \(file.map { AttachmentStore.markdown(for: $0) } ?? "")
    [Gone.pdf](attachment://\(UUID().uuidString))

    Back to normal text.
    """)
    return NoteEditor(note: note).modelContainer(container)
}

/// A teal-to-indigo gradient as PNG data, for the preview above.
private func previewPicture(width: Int, height: Int) -> Data {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }
    let colors = [CGColor(red: 0.2, green: 0.7, blue: 0.7, alpha: 1), CGColor(red: 0.3, green: 0.2, blue: 0.8, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    }
    let output = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

#Preview("Table, and a caret below an attachment") {
    let container = previewContainer()
    let context = container.mainContext
    let note = Library(context: context).createNote()
    let file = try? AttachmentStore(context: context).add(data: Data(count: 5_000), fileName: "CV.pdf", typeIdentifier: "com.adobe.pdf", to: note)

    let body = """
    # Groceries

    | Item   | Qty | Note      |
    | ------ | --- | --------- |
    | Apples | 3   | **fresh** |
    | Milk   | 1   |           |

    \(file.map { AttachmentStore.markdown(for: $0) } ?? "")

    """
    note.setBody(body)
    // The caret is on the empty line after the attachment, so the attachment line must show as a chip.
    return NoteEditor(note: note, initialSelection: (body as NSString).length).modelContainer(container)
}
