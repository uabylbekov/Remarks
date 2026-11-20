import SwiftUI
import SwiftData
import NotesCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The note editor: a TextKit 2 text view with live Markdown preview (Spec 03).
/// The stored text is always the real Markdown. Edits are saved through `Note.setBody` after a short pause,
/// and immediately when editing ends or the editor goes away.
struct NoteEditor: View {
    let note: Note
    /// Where to put the caret when the note first appears. Used by previews, to show a note while editing.
    var initialSelection: Int?
    @Environment(\.history) private var history

    @State private var notice: String?

    var body: some View {
        // Reading the revision here makes SwiftUI update the text view whenever an appearance setting changes.
        NoteTextView(
            note: note,
            history: history,
            appearanceRevision: AppearanceModel.shared.revision,
            onKeptEdits: { showNotice() },
            initialSelection: initialSelection
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

    func makeCoordinator() -> Coordinator { Coordinator(note: note, history: history) }

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
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var note: Note
        private weak var textView: MarkdownUITextView?
        private var preview: LivePreviewController?
        private var highlighter: SyntaxHighlighter?
        private var saveTask: Task<Void, Never>?

        private let history: HistoryRecorder?

        init(note: Note, history: HistoryRecorder?) {
            self.history = history
            self.note = note
        }

        func attach(to textView: MarkdownUITextView) {
            self.textView = textView
            textView.onCommand = { [weak self] in self?.perform($0) }
            textView.inputAccessoryView = MarkdownAccessoryView(
                onCommand: { [weak self] in self?.perform($0) },
                onDismiss: { [weak textView] in textView?.resignFirstResponder() }
            )
            if let layoutManager = textView.textLayoutManager,
               let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
                preview = LivePreviewController(contentStorage: contentStorage, layoutManager: layoutManager)
            }
            highlighter = SyntaxHighlighter(storage: textView.textStorage)

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

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            checklistLine(for: gestureRecognizer) != nil
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView, let line = checklistLine(for: gesture),
                  let edit = MarkdownEditing.toggleChecklist(in: textView.text, atLine: line, keepingSelection: textView.selectedRange)
            else { return }
            apply(edit)
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
            highlighter?.apply()
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
            highlighter?.apply()
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

        private func perform(_ command: MarkdownCommand) {
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
            preview?.textChanged()
            highlighter?.schedule()
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

private struct NoteTextView: NSViewRepresentable {
    let note: Note
    let history: HistoryRecorder?
    let appearanceRevision: Int
    let onKeptEdits: () -> Void
    var initialSelection: Int?

    func makeCoordinator() -> Coordinator { Coordinator(note: note, history: history) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
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
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushSave()
        coordinator.removeShortcuts()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var note: Note
        private weak var textView: NSTextView?
        private var preview: LivePreviewController?
        private var highlighter: SyntaxHighlighter?
        private var saveTask: Task<Void, Never>?
        private var keyMonitor: Any?
        private var mouseMonitor: Any?

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
            }
            if let storage = textView.textStorage {
                highlighter = SyntaxHighlighter(storage: storage)
            }
            installShortcuts()
            installCheckboxClicks()
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
            highlighter?.apply()
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
            highlighter?.apply()
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

        // MARK: Formatting shortcuts

        /// ⌘B bold, ⌘I italic, ⌘E inline code, ⌘K link, ⌥⌘C code block. Only while this editor has focus.
        private func installShortcuts() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let textView = self.textView, textView.window?.firstResponder === textView else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let command: MarkdownCommand?
                switch (event.charactersIgnoringModifiers, flags) {
                case ("b", .command): command = .bold
                case ("i", .command): command = .italic
                case ("e", .command): command = .inlineCode
                case ("k", .command): command = .link
                case ("c", [.command, .option]): command = .codeBlock
                default: command = nil
                }
                guard let command else { return event }
                self.perform(command)
                return nil
            }
        }

        func removeShortcuts() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            keyMonitor = nil
            mouseMonitor = nil
        }

        /// A click on a checkbox toggles it, and the click is consumed so the caret does not move to that line.
        private func installCheckboxClicks() {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let textView = self.textView, event.window === textView.window else { return event }
                let location = textView.convert(event.locationInWindow, from: nil)
                guard textView.bounds.contains(location) else { return event }
                let origin = textView.textContainerOrigin
                let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                guard let line = self.preview?.checklistLine(at: point),
                      let edit = MarkdownEditing.toggleChecklist(in: textView.string, atLine: line, keepingSelection: textView.selectedRange())
                else { return event }
                self.apply(edit)
                return nil
            }
        }

        private func perform(_ command: MarkdownCommand) {
            guard let textView else { return }
            apply(MarkdownEditing.edit(command, in: textView.string, selection: textView.selectedRange()))
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
            preview?.textChanged()
            highlighter?.schedule()
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
