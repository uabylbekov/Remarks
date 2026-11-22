import SwiftUI
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import NotesCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// Whether the Markdown marks (`#`, `**`, link addresses) are shown. Off, they are hidden once they take effect.
    var showsMarkdown = UserDefaults.standard.bool(forKey: "showsMarkdown") {
        didSet { UserDefaults.standard.set(showsMarkdown, forKey: "showsMarkdown") }
    }
    /// Pictures and files pasted into the editor. The screen turns them into attachments and clears the list.
    var pastedFiles: [PastedFile] = []

    func perform(_ command: MarkdownCommand) { handler?(command) }
    func pasted(_ files: [PastedFile]) { pastedFiles += files }
    func insertBlock(_ markdown: String) { insert?(markdown) }
    func attach(from source: AttachmentSource) { attachmentRequest = source }
}

extension FocusedValues {
    /// The formatting commands of the editor that has focus, for the menu bar.
    @Entry var editorCommands: EditorCommands?
}

/// The note editor: a TextKit 2 text view with live Markdown preview (Spec 03).
/// The stored text is always the real Markdown. Model updates are immediate; disk saves are debounced
/// and flushed when editing ends or the editor goes away.
struct NoteEditor: View {
    let note: Note
    /// Where to put the caret when the note first appears. Used by previews, to show a note while editing.
    var initialSelection: Int?
    /// Set by a toolbar that wants to format the text. Used on the Mac.
    var commands: EditorCommands?
    /// Called when an attachment is tapped or clicked. The screen around the editor shows it.
    var onOpenAttachment: ((NotesCore.Attachment) -> Void)?

    var onSaveError: ((String) -> Void)?
    @State private var saveError: String?

    var body: some View {
        // Reading the revision here makes SwiftUI update the text view whenever an appearance setting changes.
        NoteTextView(
            note: note,
            appearanceRevision: AppearanceModel.shared.revision,
            onSaveError: { message in
                // Dismantling an editor can flush a save while SwiftUI is updating views.
                Task { @MainActor in
                    if let onSaveError { onSaveError(message) } else { saveError = message }
                }
            },
            initialSelection: initialSelection,
            commands: commands,
            onOpenAttachment: onOpenAttachment
        )
        #if os(iOS)
        // Let the text view run under the bars; UITextView insets its own content by the safe area, so text scrolls
        // beneath them instead of being clipped at their edges.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        #endif
        .alert("Unable to Save Note", item: $saveError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: $0) }
    }
}

#if canImport(UIKit)

// MARK: - iOS and iPadOS

/// Adds hardware-keyboard shortcuts for the formatting commands.
private final class MarkdownUITextView: UITextView {
    var onCommand: ((MarkdownCommand) -> Void)?
    /// Called with a pasted picture. Returns false when nothing took it, so the text view pastes normally.
    var onPaste: (([PastedFile]) -> Bool)?
    /// Called after every layout, so the editor can notice a change of width (rotation, a resized window).
    var onLayout: (() -> Void)?
    /// Called when the text view gains or loses the keyboard.
    var onFocusChange: (() -> Void)?
    /// UIKit sends nothing to the delegate for Backspace at the very start of the text, so the editor gets it here.
    /// Returns true when it handled the key.
    var onBackspaceAtStart: (() -> Bool)?

    private var previousViewportSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
        if bounds.size != previousViewportSize {
            previousViewportSize = bounds.size
            revealCaret()
        }
    }

    /// Keep the caret clear of both viewport edges after keyboard, rotation, or preview-layout changes.
    func revealCaret() {
        guard isFirstResponder, selectedRange.length == 0, let selection = selectedTextRange else { return }
        let caret = caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        scrollRectToVisible(caret.insetBy(dx: 0, dy: -max(textContainerInset.top, textContainerInset.bottom)), animated: false)
    }

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0), markedTextRange == nil, onBackspaceAtStart?() == true { return }
        super.deleteBackward()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        onFocusChange?()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onFocusChange?()
        return result
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPaste != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Text wins when the clipboard holds both, as when copying from a web page.
        if !UIPasteboard.general.hasStrings, let file = Self.pastedPicture(), onPaste?([file]) == true { return }
        super.paste(sender)
    }

    private static func pastedPicture() -> PastedFile? {
        let board = UIPasteboard.general
        for type in [UTType.png, .jpeg, .heic, .gif] {
            if let data = board.data(forPasteboardType: type.identifier) {
                return PastedFile(data: data, fileName: "Pasted Image.\(type.preferredFilenameExtension ?? "png")", type: type)
            }
        }
        guard let image = board.image, let data = image.pngData() else { return nil }
        return PastedFile(data: data, fileName: "Pasted Image.png", type: .png)
    }

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
    let appearanceRevision: Int
    @Environment(\.openURL) private var openURL
    let onSaveError: (String) -> Void
    var initialSelection: Int?
    var commands: EditorCommands?
    var onOpenAttachment: ((NotesCore.Attachment) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(note: note, commands: commands) }

    func makeUIView(context: Context) -> UITextView {
        // `usingTextLayoutManager: true` selects TextKit 2.
        let textView = MarkdownUITextView(usingTextLayoutManager: true)
        textView.font = EditorTheme.proseFont
        textView.backgroundColor = EditorTheme.editorBackground
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.keyboardDismissMode = .interactive
        // Smart punctuation would turn typed quotes and dashes into characters that break Markdown and code.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.delegate = context.coordinator
        context.coordinator.session.onSaveError = onSaveError
        context.coordinator.attach(to: textView)
        if let initialSelection {
            textView.selectedRange = NSRange(location: min(initialSelection, textView.textStorage.length), length: 0)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        let session = context.coordinator.session
        session.onSaveError = onSaveError
        session.update(note: note)
        session.onOpenAttachment = onOpenAttachment
        session.applyAppearance(revision: appearanceRevision)
        session.refreshAttachmentsIfChanged()
        if session.setShowsMarkdown(commands?.showsMarkdown ?? false) {
            textView.layoutIfNeeded()
            (textView as? MarkdownUITextView)?.revealCaret()
        }
        commands?.handler = { [weak coordinator = context.coordinator] in coordinator?.perform($0) }
        commands?.insert = { [weak coordinator = context.coordinator] in coordinator?.insertBlock($0) }
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.session.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let session: EditorSession
        /// Opens a link that was tapped or clicked, the way the rest of the app does.
        var openURL: OpenURLAction?
        private weak var textView: MarkdownUITextView?
        private var tableOverlay: TableOverlay?

        init(note: Note, commands: EditorCommands?) {
            session = EditorSession(note: note, commands: commands)
        }

        func attach(to textView: MarkdownUITextView) {
            self.textView = textView
            textView.onCommand = { [weak self] in self?.perform($0) }
            tableOverlay = TableOverlay(
                container: textView,
                origin: { [weak textView] in
                    let inset = textView?.textContainerInset ?? .zero
                    return CGPoint(x: inset.left, y: inset.top)
                }
            )
            textView.onFocusChange = { [weak self] in self?.tableOverlay?.scheduleUpdate() }
            textView.onBackspaceAtStart = { [weak self] in
                guard let self, let action = self.session.preview?.backspace(at: 0) else { return false }
                switch action {
                case .normal: return false
                case .ignore: return true
                case .edit(let edit): self.apply(edit); return true
                }
            }
            textView.onLayout = { [weak self] in
                self?.session.preview?.containerWidthMayHaveChanged()
                self?.tableOverlay?.layoutDidChange()
            }
            textView.onPaste = { [weak self] files in self?.session.paste(files) ?? false }
            textView.inputAccessoryView = MarkdownAccessoryView(
                onCommand: { [weak self] in self?.perform($0) },
                onAttach: { [weak self] in self?.session.commands?.attach(from: $0) },
                onDismiss: { [weak textView] in textView?.resignFirstResponder() }
            )

            // A tap on a checkbox toggles it. The recognizer only begins when the tap lands on a box,
            // and the text view's own tap recognizers wait for it, so the caret does not jump to that line.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            textView.addGestureRecognizer(tap)
            for recognizer in textView.gestureRecognizers ?? [] where recognizer !== tap && recognizer is UITapGestureRecognizer {
                recognizer.require(toFail: tap)
            }

            session.attach(
                host: .init(
                    text: { [weak textView] in textView?.text ?? "" },
                    setText: { [weak textView] in textView?.text = $0 },
                    selection: { [weak textView] in textView?.selectedRange ?? NSRange(location: 0, length: 0) },
                    isComposing: { [weak textView] in textView?.markedTextRange != nil },
                    applyEdit: { [weak self] in self?.replaceText($0) ?? false },
                    undoManager: { [weak textView] in textView?.undoManager },
                    applyFont: { [weak textView] in
                        textView?.font = EditorTheme.proseFont
                        textView?.backgroundColor = EditorTheme.editorBackground
                    },
                    applyBodyStyle: { [weak self] in self?.applyBodyStyle() },
                    focus: { [weak textView] in Task { @MainActor in textView?.becomeFirstResponder() } }
                ),
                textLayoutManager: textView.textLayoutManager
            )
            tableOverlay?.connect(
                to: session.preview,
                apply: { [weak self] in self?.apply($0) },
                placeCaret: { [weak self, weak textView] range in
                    textView?.selectedRange = range
                    self?.session.preview?.selectionChanged(to: range)
                    textView?.becomeFirstResponder()
                }
            )
        }

        // MARK: Taps

        /// Where a gesture is, in the text container's coordinates.
        private func containerPoint(for gesture: UIGestureRecognizer) -> CGPoint? {
            guard let textView else { return nil }
            let location = gesture.location(in: textView)
            let inset = textView.textContainerInset
            return CGPoint(x: location.x - inset.left, y: location.y - inset.top)
        }

        private func checklistLine(for gesture: UIGestureRecognizer) -> Int? {
            containerPoint(for: gesture).flatMap { session.preview?.checklistLine(at: $0) }
        }

        private func attachmentID(for gesture: UIGestureRecognizer) -> UUID? {
            containerPoint(for: gesture).flatMap { session.preview?.attachmentID(at: $0) }
        }

        private func linkURL(for gesture: UIGestureRecognizer) -> URL? {
            containerPoint(for: gesture).flatMap { session.preview?.linkURL(at: $0) }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            checklistLine(for: gestureRecognizer) != nil || attachmentID(for: gestureRecognizer) != nil
                || linkURL(for: gestureRecognizer) != nil
                || containerPoint(for: gestureRecognizer).flatMap { session.preview?.elementBoundary(at: $0) } != nil
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            if let point = containerPoint(for: gesture), let range = session.preview?.elementBoundary(at: point) {
                textView.selectedRange = range
                session.preview?.selectionChanged(to: range)
                textView.becomeFirstResponder()
                return
            }
            if let url = linkURL(for: gesture) {
                openURL?(url)
                return
            }
            if let id = attachmentID(for: gesture), let attachment = session.catalog.attachment(with: id) {
                if let point = containerPoint(for: gesture), let range = session.preview?.attachmentSelection(at: point), textView.selectedRange != range {
                    textView.selectedRange = range
                    textView.becomeFirstResponder()
                } else {
                    session.onOpenAttachment?(attachment)
                }
                return
            }
            guard let line = checklistLine(for: gesture),
                  let edit = MarkdownEditing.toggleChecklist(in: textView.text, atLine: line, keepingSelection: textView.selectedRange)
            else { return }
            apply(edit)
        }

        // MARK: Formatting

        /// Gives ordinary text the line spacing setting, including what is typed next on an empty line.
        private func applyBodyStyle() {
            guard let textView else { return }
            let style = EditorTheme.bodyParagraphStyle
            textView.textStorage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: textView.textStorage.length))
            textView.typingAttributes[.paragraphStyle] = style
        }

        func insertBlock(_ markdown: String) {
            guard let textView else { return }
            apply(MarkdownEditing.insertBlock(markdown, in: textView.text, selection: textView.selectedRange))
        }

        func perform(_ command: MarkdownCommand) {
            guard let textView else { return }
            guard session.apply(MarkdownEditing.edit(command, in: textView.text, selection: textView.selectedRange)) else { return }
            textView.becomeFirstResponder()
        }

        private func apply(_ edit: TextEdit) { session.apply(edit) }

        /// Use native text input for undo registration, rather than replacing the whole document.
        private func replaceText(_ edit: TextEdit) -> Bool {
            guard let textView,
                  let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return false }
            if textView.text(in: range) != edit.replacement {
                let undoManager = textView.undoManager
                undoManager?.beginUndoGrouping()
                textView.replace(range, withText: edit.replacement)
                undoManager?.endUndoGrouping()
            }
            textView.selectedRange = edit.selection
            return true
        }

        // MARK: UITextViewDelegate

        /// Return continues a list or checklist, and ends it on an empty item. Code blocks and text being
        /// composed (Japanese, Chinese, and so on) keep the default behavior.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !session.isApplyingEdit else { return true }
            if text == " ", let id = session.preview?.attachmentID(in: range),
               let attachment = session.catalog.attachment(with: id) {
                session.onOpenAttachment?(attachment)
                return false
            }
            if text == "\t", textView.markedTextRange == nil, session.preview?.showsMarkdown != true,
               let edit = MarkdownEditing.indentList(in: textView.text, selection: textView.selectedRange, outdent: false) {
                apply(edit)
                return false
            }
            // At the end of a table, typing goes on the line after the table.
            if range.length == 0, textView.markedTextRange == nil, let edit = session.preview?.redirectedInsert(text, at: range) {
                apply(edit)
                return false
            }
            // Backspace deletes the character before the caret.
            if text.isEmpty, range.length > 0, textView.selectedRange.length == 0, textView.markedTextRange == nil,
               let action = NSMaxRange(range) == textView.selectedRange.location
                ? session.preview?.backspace(at: NSMaxRange(range))
                : session.preview?.deleteForward(at: range.location) {
                switch action {
                case .normal: break
                case .ignore: return false
                case .edit(let edit):
                    apply(edit)
                    return false
                }
            }
            guard text == "\n", range.length == 0, textView.markedTextRange == nil,
                  session.preview?.isInCodeBlock(range.location) != true,
                  let edit = MarkdownEditing.returnKeyEdit(in: textView.text, selection: range)
            else { return true }
            apply(edit)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            session.textDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !session.isApplyingEdit, textView.markedTextRange == nil else { return }
            // The caret never rests inside Markdown that is drawn as a checkbox or a table.
            if let adjusted = session.preview?.adjustedSelection(to: textView.selectedRange) {
                textView.selectedRange = adjusted
                session.preview?.selectionChanged(to: textView.selectedRange)
                return
            }
            session.preview?.selectionChanged(to: textView.selectedRange)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            session.flushSave()
        }
    }
}

#else

// MARK: - macOS

/// A text view that passes clicks on a checklist box to the editor before it moves the caret.
final class MarkdownNSTextView: NSTextView {
    var onCheckboxClick: ((CGPoint) -> Bool)?
    /// Called with pasted pictures and files. Returns false when nothing took them, so the text view pastes normally.
    var onPaste: (([PastedFile]) -> Bool)?
    /// Called after every layout, so the editor can notice a change of width (a resized window).
    var onLayout: (() -> Void)?
    /// Called when the text view gains or loses the keyboard.
    var onFocusChange: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        onFocusChange?()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onFocusChange?()
        return result
    }

    override func paste(_ sender: Any?) {
        // Text wins when the clipboard holds both, as when copying from a web page.
        if NSPasteboard.general.string(forType: .string) == nil, let files = Self.pastedFiles(), !files.isEmpty,
           onPaste?(files) == true { return }
        super.paste(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPaste != nil, NSPasteboard.general.string(forType: .string) == nil,
           Self.pastedFiles()?.isEmpty == false { return true }
        return super.validateUserInterfaceItem(item)
    }

    private static func pastedFiles() -> [PastedFile]? {
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.compactMap { url -> PastedFile? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            return PastedFile(data: data, fileName: url.lastPathComponent, type: type)
        }
        if !files.isEmpty { return files }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = board.data(forType: type) else { continue }
            if type == .png { return [PastedFile(data: data, fileName: "Pasted Image.png", type: .png)] }
            // A screenshot or a copied picture often arrives as TIFF. PNG is smaller and understood everywhere.
            if let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                return [PastedFile(data: png, fileName: "Pasted Image.png", type: .png)]
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if onCheckboxClick?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }
}

private struct NoteTextView: NSViewRepresentable {
    let note: Note
    let appearanceRevision: Int
    @Environment(\.openURL) private var openURL
    let onSaveError: (String) -> Void
    var initialSelection: Int?
    var commands: EditorCommands?
    var onOpenAttachment: ((NotesCore.Attachment) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(note: note, commands: commands) }

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
        textView.backgroundColor = EditorTheme.editorBackground
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        // Smart punctuation would turn typed quotes and dashes into characters that break Markdown and code.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        context.coordinator.session.onSaveError = onSaveError
        context.coordinator.attach(to: textView)
        if let initialSelection {
            textView.setSelectedRange(NSRange(location: min(initialSelection, textView.string.utf16.count), length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.openURL = openURL
        let session = context.coordinator.session
        session.onSaveError = onSaveError
        session.update(note: note)
        session.onOpenAttachment = onOpenAttachment
        session.applyAppearance(revision: appearanceRevision)
        session.refreshAttachmentsIfChanged()
        session.setShowsMarkdown(commands?.showsMarkdown ?? false)
        commands?.handler = { [weak coordinator = context.coordinator] in coordinator?.perform($0) }
        commands?.insert = { [weak coordinator = context.coordinator] in coordinator?.insertBlock($0) }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.session.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: EditorSession
        /// Opens a link that was tapped or clicked, the way the rest of the app does.
        var openURL: OpenURLAction?
        private weak var textView: MarkdownNSTextView?
        private var tableOverlay: TableOverlay?

        init(note: Note, commands: EditorCommands?) {
            session = EditorSession(note: note, commands: commands)
        }

        func attach(to textView: MarkdownNSTextView) {
            self.textView = textView
            tableOverlay = TableOverlay(
                container: textView,
                origin: { [weak textView] in textView?.textContainerOrigin ?? .zero }
            )
            textView.onFocusChange = { [weak self] in self?.tableOverlay?.scheduleUpdate() }
            textView.onLayout = { [weak self] in
                self?.session.preview?.containerWidthMayHaveChanged()
                self?.tableOverlay?.layoutDidChange()
            }
            textView.onPaste = { [weak self] files in self?.session.paste(files) ?? false }
            textView.onCheckboxClick = { [weak self] point in self?.handleClick(at: point) ?? false }

            session.attach(
                host: .init(
                    text: { [weak textView] in textView?.string ?? "" },
                    setText: { [weak textView] in textView?.string = $0 },
                    selection: { [weak textView] in textView?.selectedRange() ?? NSRange(location: 0, length: 0) },
                    isComposing: { [weak textView] in textView?.hasMarkedText() ?? false },
                    applyEdit: { [weak self] in self?.replaceText($0) ?? false },
                    undoManager: { [weak textView] in textView?.undoManager },
                    applyFont: { [weak textView] in
                        textView?.font = EditorTheme.proseFont
                        textView?.backgroundColor = EditorTheme.editorBackground
                    },
                    applyBodyStyle: { [weak self] in self?.applyBodyStyle() },
                    focus: { [weak textView] in Task { @MainActor in textView?.window?.makeFirstResponder(textView) } }
                ),
                textLayoutManager: textView.textLayoutManager
            )
            tableOverlay?.connect(
                to: session.preview,
                apply: { [weak self] in self?.apply($0) },
                placeCaret: { [weak textView] range in
                    textView?.setSelectedRange(range)
                    textView?.window?.makeFirstResponder(textView)
                }
            )
        }

        /// Gives ordinary text the line spacing setting, including what is typed next on an empty line.
        private func applyBodyStyle() {
            guard let textView else { return }
            let style = EditorTheme.bodyParagraphStyle
            textView.defaultParagraphStyle = style
            textView.textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
            textView.typingAttributes[.paragraphStyle] = style
        }

        // MARK: Clicks

        /// A click on a checkbox toggles it, and a click on a link or an attachment opens it. Returns true when the click was
        /// one of those, so the caret does not move to that line.
        private func handleClick(at location: CGPoint) -> Bool {
            guard let textView else { return false }
            let origin = textView.textContainerOrigin
            let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
            if let range = session.preview?.elementBoundary(at: point) {
                textView.setSelectedRange(range)
                session.preview?.selectionChanged(to: range)
                textView.window?.makeFirstResponder(textView)
                return true
            }
            if let url = session.preview?.linkURL(at: point) {
                openURL?(url)
                return true
            }
            if let id = session.preview?.attachmentID(at: point), let attachment = session.catalog.attachment(with: id) {
                if let range = session.preview?.attachmentSelection(at: point), textView.selectedRange() != range {
                    textView.setSelectedRange(range)
                    textView.window?.makeFirstResponder(textView)
                } else {
                    session.onOpenAttachment?(attachment)
                }
                return true
            }
            guard let line = session.preview?.checklistLine(at: point),
                  let edit = MarkdownEditing.toggleChecklist(in: textView.string, atLine: line, keepingSelection: textView.selectedRange())
            else { return false }
            apply(edit)
            return true
        }

        // MARK: Formatting

        func perform(_ command: MarkdownCommand) {
            guard let textView else { return }
            guard session.apply(MarkdownEditing.edit(command, in: textView.string, selection: textView.selectedRange())) else { return }
            textView.window?.makeFirstResponder(textView)
        }

        func insertBlock(_ markdown: String) {
            guard let textView else { return }
            apply(MarkdownEditing.insertBlock(markdown, in: textView.string, selection: textView.selectedRange()))
        }

        private func apply(_ edit: TextEdit) { session.apply(edit) }

        private func replaceText(_ edit: TextEdit) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            if (textView.string as NSString).substring(with: edit.range) != edit.replacement {
                textView.breakUndoCoalescing()
                guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.didChangeText()
                textView.breakUndoCoalescing()
            }
            textView.setSelectedRange(edit.selection)
            return true
        }

        // MARK: NSTextViewDelegate

        /// Return continues a list or checklist, and ends it on an empty item. Code blocks and text being
        /// composed keep the default behavior.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if !textView.hasMarkedText(), session.preview?.showsMarkdown != true,
               commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)),
               let edit = MarkdownEditing.indentList(in: textView.string, selection: textView.selectedRange(),
                                                      outdent: commandSelector == #selector(NSResponder.insertBacktab(_:))) {
                apply(edit)
                return true
            }
            // At the end of a table, Return starts a line after the table.
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
               let edit = session.preview?.redirectedInsert("\n", at: textView.selectedRange()) {
                apply(edit)
                return true
            }
            let isBackward = commandSelector == #selector(NSResponder.deleteBackward(_:))
            if isBackward || commandSelector == #selector(NSResponder.deleteForward(_:)), !textView.hasMarkedText(),
               textView.selectedRange().length == 0,
               let action = isBackward
                ? session.preview?.backspace(at: textView.selectedRange().location)
                : session.preview?.deleteForward(at: textView.selectedRange().location) {
                switch action {
                case .normal: break
                case .ignore: return true
                case .edit(let edit):
                    apply(edit)
                    return true
                }
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            guard session.preview?.isInCodeBlock(selection.location) != true,
                  let edit = MarkdownEditing.returnKeyEdit(in: textView.string, selection: selection)
            else { return false }
            apply(edit)
            return true
        }

        /// At the end of a table, typing goes on the line after the table.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard !session.isApplyingEdit else { return true }
            if text == " ", let id = session.preview?.attachmentID(in: range),
               let attachment = session.catalog.attachment(with: id) {
                session.onOpenAttachment?(attachment)
                return false
            }
            guard let text, range.length == 0, !textView.hasMarkedText(),
                  let edit = session.preview?.redirectedInsert(text, at: range) else { return true }
            apply(edit)
            return false
        }

        func textDidChange(_ notification: Notification) {
            session.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !session.isApplyingEdit, let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            // The caret never rests inside Markdown that is drawn as a checkbox or a table.
            if let adjusted = session.preview?.adjustedSelection(to: textView.selectedRange()) {
                textView.setSelectedRange(adjusted)
                session.preview?.selectionChanged(to: textView.selectedRange())
                return
            }
            session.preview?.selectionChanged(to: textView.selectedRange())
        }

        func textDidEndEditing(_ notification: Notification) {
            session.flushSave()
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

#Preview("Bullets, quote, rule, link, wide table") {
    let container = previewContainer()
    let note = Note(body: """
    # Polish

    - First bullet
    - Second bullet with a [link](https://example.com)
    * Star bullet

    > A quote that
    > runs over two lines

    ---

    | Name | Quantity | Price per unit | Where it is stored | Notes |
    | ---- | -------- | -------------- | ------------------ | ----- |
    | Apples | 3 | 1.20 | Fridge, top shelf | fresh |

    Back to text.
    """)
    container.mainContext.insert(note)
    return NoteEditor(note: note).modelContainer(container)
}
