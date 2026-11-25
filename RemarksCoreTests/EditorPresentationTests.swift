import Testing
import Foundation
import SwiftUI
import SwiftData
import RemarksCore
@testable import Remarks
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Integration contracts between Markdown source, display-only styling, and native viewport layout.
@MainActor
struct EditorPresentationTests {
    @Test(arguments: ["# Heading", "> quote", "**bold** and `code`", "[link](https://example.com)", "- item", "---", "Title\n=====", "```python\nprint(1)\n```", "~~~swift\nlet x = 1\n~~~", "```\n", "> first\n> "])
    func visibleSyntaxUsesNativeEditing(source: String) throws {
        let (content, preview) = fixture(source)
        defer { withExtendedLifetime(preview) {} }
        let text = source as NSString
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let styled = preview.textContentStorage(content, textParagraphWith: range)?.attributedString
            #expect(styled?.string ?? text.substring(with: range) == text.substring(with: range))
            location = NSMaxRange(range)
        }
        for offset in 0...text.length {
            let caret = NSRange(location: offset, length: 0)
            #expect(preview.selectionForPreview(caret) == caret)
            #expect(preview.adjustedSelection(to: caret) == nil)
            #expect(preview.redirectedInsert("x", at: caret) == nil)
            #expect(preview.redirectedInsert("\n", at: caret) == nil)
            if case .normal = preview.backspace(at: offset) {} else { Issue.record("Backspace should use native editing") }
            if case .normal = preview.deleteForward(at: offset) {} else { Issue.record("Delete should use native editing") }
            preview.selectionChanged(to: caret)
        }
    }

    @Test(arguments: [MarkdownCommand.bold, .italic, .strikethrough, .inlineCode])
    func typingStaysInsideInlineFormatting(command: MarkdownCommand) throws {
        let edit = MarkdownEditing.edit(command, in: "", selection: NSRange(location: 0, length: 0))
        let (content, preview) = fixture(edit.replacement)
        let storage = try #require(content.textStorage)
        var caret = edit.selection
        preview.selectionChanged(to: caret)
        for character in "Hello 😀 world" {
            let inserted = String(character)
            storage.replaceCharacters(in: caret, with: inserted)
            caret.location += inserted.utf16.count
            caret = preview.adjustedSelection(to: caret) ?? caret
            preview.selectionChanged(to: caret)
            // Layout can report the same selection again without a new edit.
            #expect(preview.adjustedSelection(to: caret) == nil)
        }
        let span = try #require(InlineScanner.spans(in: storage.string).first)
        #expect((storage.string as NSString).substring(with: span.content) == "Hello 😀 world")
        #expect(caret.location == NSMaxRange(span.content))
        let right = preview.adjustedSelection(to: NSRange(location: caret.location + 1, length: 0))
        #expect(right == nil)
    }

    @Test(arguments: ["**bold**", "*italic*", "~~removed~~", "`code`", "[label](https://example.com)", "**bold *nested***"])
    func inlineSyntaxAppearsOnlyWhileEditing(value: String) throws {
        let source = "Before " + value + " after"
        let (content, preview) = fixture(source)
        let spans = InlineScanner.spans(in: source)
        let span = try #require(spans.first)
        let marker = try #require(span.markers.first)
        func markerFont() throws -> EditorFont {
            let paragraph = try #require(preview.textContentStorage(content, textParagraphWith: NSRange(location: 0, length: source.utf16.count))?.attributedString)
            #expect(paragraph.string == source)
            return try #require(paragraph.attribute(.font, at: marker.location, effectiveRange: nil) as? EditorFont)
        }
        #expect(try markerFont().pointSize < 1)
        preview.selectionChanged(to: NSRange(location: span.content.location + 1, length: 0))
        #expect(try markerFont().pointSize > 1)
        preview.selectionChanged(to: NSRange(location: source.utf16.count, length: 0))
        #expect(try markerFont().pointSize < 1)
        preview.selectionChanged(to: NSRange(location: 0, length: source.utf16.count))
        #expect(try markerFont().pointSize > 1)
        #expect(content.textStorage?.string == source)
    }

    @Test func editingOneInlineSpanKeepsItsNeighborQuiet() throws {
        let source = "**first** and **second**"
        let (content, preview) = fixture(source)
        preview.selectionChanged(to: NSRange(location: 4, length: 0))
        let paragraph = try #require(preview.textContentStorage(content, textParagraphWith: NSRange(location: 0, length: source.utf16.count))?.attributedString)
        let spans = InlineScanner.spans(in: source)
        let first = try #require(paragraph.attribute(.font, at: spans[0].markers[0].location, effectiveRange: nil) as? EditorFont)
        let second = try #require(paragraph.attribute(.font, at: spans[1].markers[0].location, effectiveRange: nil) as? EditorFont)
        #expect(first.pointSize > 1)
        #expect(second.pointSize < 1)
    }

    private func fixture(_ source: String) -> (NSTextContentStorage, LivePreviewController) {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        storage.textStorage?.setAttributedString(NSAttributedString(string: source))
        let preview = LivePreviewController(contentStorage: storage, layoutManager: manager)
        preview.reload()
        // The storage owns its layout manager, and the controller intentionally holds both weakly.
        return (storage, preview)
    }

    /// Backspace at the start of an attachment or a table never joins the line above into it. It is not a dead key either.
    @Test func backspaceAtTheStartOfAnAttachmentOrTableMovesOrRemovesTheLineAbove() throws {
        let image = "![Beach](attachment://\(UUID().uuidString))"
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        func edit(_ source: String, at caret: Int) throws -> TextEdit {
            let (_, preview) = fixture(source)
            defer { withExtendedLifetime(preview) {} }
            guard case .edit(let edit) = preview.backspace(at: caret) else {
                Issue.record("Backspace at \(caret) in \(source.debugDescription) must act"); return TextEdit(range: NSRange(location: 0, length: 0), replacement: "?", selection: NSRange(location: 0, length: 0))
            }
            return edit
        }
        for (name, block) in [("attachment", image), ("table", table)] {
            // Text above: the caret steps to its end and nothing is joined.
            let text = "Intro\n" + block + "\n"
            let step = try edit(text, at: 6)
            #expect(step.range.length == 0 && step.replacement.isEmpty, "\(name): text above is not joined")
            #expect(step.selection == NSRange(location: 5, length: 0), "\(name): caret moves to the end of the text")
            // An empty line above is removed.
            let blank = "Intro\n\n" + block + "\n"
            let removal = try edit(blank, at: 7)
            #expect(removal.range == NSRange(location: 6, length: 1) && removal.replacement.isEmpty, "\(name): empty line is removed")
            #expect(removal.selection == NSRange(location: 6, length: 0))
        }
        // At the very start of the note there is nothing to delete.
        for block in [image, table] {
            let (_, preview) = fixture(block + "\n")
            defer { withExtendedLifetime(preview) {} }
            guard case .ignore = preview.backspace(at: 0) else { Issue.record("Backspace at the start of the note does nothing"); continue }
        }
        // The empty line between two tables is kept, or they would merge into one.
        let two = table + "\n\n" + table
        let secondStart = (table as NSString).length + 2
        let keep = try edit(two, at: secondStart)
        #expect(keep.range.length == 0 && keep.replacement.isEmpty)
        #expect(keep.selection == NSRange(location: (table as NSString).length + 1, length: 0))
    }

    private func components(_ color: EditorColor) -> [CGFloat] {
        #if canImport(UIKit)
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.components ?? []
        #else
        var result: [CGFloat] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB)?.cgColor.components ?? []
        }
        return result
        #endif
    }

    @Test func editingTheFenceLanguageRefreshesHighlighting() throws {
        let (content, preview) = fixture("```unknown\nlet answer = 42\n```")
        let storage = try #require(content.textStorage)
        storage.replaceCharacters(in: NSRange(location: 3, length: 7), with: "swift")
        let block = try #require(preview.blocks.first)
        #expect(block.language == "swift")
        let fence = try #require(preview.textContentStorage(content, textParagraphWith: block.open)?.attributedString)
        #expect(fence.string == "```swift\n")
        let markerColor = try #require(fence.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? EditorColor)
        let languageColor = try #require(fence.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? EditorColor)
        #expect(components(markerColor) == components(EditorTheme.dimColor))
        #expect(components(languageColor) == components(EditorTheme.codeTextColor))
        #expect(preview.syntaxTokens(for: block).contains { $0.scope == .keyword })
    }

    @Test func checkboxesRemainControlsWithEditableInlineSyntax() throws {
        let source = "- [ ] **Task**"
        let (content, preview) = fixture(source)
        let paragraph = try #require(preview.textContentStorage(content, textParagraphWith: NSRange(location: 0, length: source.utf16.count))?.attributedString)
        #expect(paragraph.attribute(LivePreviewController.checklistKey, at: 0, effectiveRange: nil) != nil)
        #expect(paragraph.string.hasSuffix("**Task**"))
        let caret = NSRange(location: 7, length: 0)
        #expect(preview.adjustedSelection(to: caret) == nil)
        #expect(content.textStorage?.string == source)
    }

    @Test func codeKeepsItsSyntaxColorsInTheDisplayParagraph() throws {
        let source = "😀 title\n\n```swift\nimport Foundation\nlet answer = 42\n```\n"
        let (storage, preview) = fixture(source)
        let text = source as NSString
        for (word, scope) in [("import", SyntaxScope.keyword), ("Foundation", .type), ("42", .number)] {
            let token = text.range(of: word)
            let line = text.lineRange(for: token)
            let paragraph = try #require(preview.textContentStorage(storage, textParagraphWith: line)?.attributedString)
            let color = try #require(paragraph.attribute(.foregroundColor, at: token.location - line.location, effectiveRange: nil) as? EditorColor)
            #expect(components(color) == components(EditorTheme.color(for: scope)))
        }
        #expect(storage.textStorage?.string == source)
    }

    @Test func editingBeforeAndInsideCodeRefreshesHighlighting() throws {
        let source = "Title\n```swift\nlet answer = 42\n```\n"
        let (storage, preview) = fixture(source)
        let backing = try #require(storage.textStorage)
        let original = try #require(preview.blocks.first)
        #expect(!preview.syntaxTokens(for: original).isEmpty)
        backing.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀\n")
        let shifted = try #require(preview.blocks.first)
        let tokens = preview.syntaxTokens(for: shifted)
        #expect(tokens.contains { $0.scope == .keyword && (backing.string as NSString).substring(with: $0.range) == "let" })
        let number = (backing.string as NSString).range(of: "42")
        backing.replaceCharacters(in: number, with: "true")
        let updated = try #require(preview.blocks.first)
        #expect(preview.syntaxTokens(for: updated).contains { $0.scope == .constant && (backing.string as NSString).substring(with: $0.range) == "true" })
    }

    @Test func everyFormattingCommandIsDiscoverable() {
        let commands = EditorCommandCatalog.keyboardBar
        #expect(Set(commands) == Set(MarkdownCommand.allCases))
        #expect(commands.count == Set(commands).count)
    }

    @Test func tableFocusCannotEditAnOldDocumentSelection() {
        let commands = EditorCommands()
        var performed = false
        var inserted = false
        commands.handler = { _ in performed = true }
        commands.insert = { _ in inserted = true }
        commands.isEditingTableCell = true
        commands.perform(.bold)
        commands.insertBlock("wrong target")
        commands.attach(from: .file)
        #expect(!performed && !inserted)
        #expect(commands.attachmentRequest == nil)
        commands.isEditingTableCell = false
        commands.perform(.bold)
        #expect(performed)
    }

    @Test(arguments: ["```\n\n```\n", "```swift\nlet value = 1\n```\n", "```swift\n", "Before\n```\n\n```\nAfter"])
    func codeUsesNativeLineGeometry(source: String) throws {
        let (storage, preview) = fixture(source)
        let manager = try #require(storage.textLayoutManagers.first)
        manager.ensureLayout(for: storage.documentRange)
        var count = 0
        manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let code = fragment as? CodeBlockFragment else { return true }
            count += 1
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                #expect(line.typographicBounds.minY >= 0)
                #expect(line.typographicBounds.maxY <= code.layoutFragmentFrame.height)
            }
            return true
        }
        #expect(count > 0)
        #expect(storage.textStorage?.string == source)
        // Retain the display delegate until layout has finished.
        #expect(!preview.blocks.isEmpty)
    }

    @Test func visibleCodeFencePreservesFontMetricsAndSourceOffsets() throws {
        let source = "```swift\nlet value = 1\n```"
        let (storage, preview) = fixture(source)
        let block = try #require(preview.blocks.first)
        let paragraph = try #require(preview.textContentStorage(storage, textParagraphWith: block.open)?.attributedString)
        #expect(paragraph.length == block.open.length)
        #expect((paragraph.string as NSString).substring(with: NSRange(location: 0, length: 3)) == "```")
        let font = try #require(paragraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont)
        #expect(font.pointSize > 1)
        #expect(storage.textStorage?.string == source)
    }

    @Test(arguments: [
        ("- [ ] task continuation", "continuation"),
        ("- [x] done continuation", "continuation"),
        ("- item continuation", "continuation"),
        ("> quote continuation", "continuation"),
    ])
    func continuationParagraphPastBlockMarkerStylesSafely(source: String, tail: String) throws {
        let (storage, preview) = fixture(source)
        defer { withExtendedLifetime(preview) {} }
        let tailRange = (source as NSString).range(of: tail)
        let styled = preview.textContentStorage(storage, textParagraphWith: tailRange)?.attributedString
        #expect(styled?.string == tail)
    }

    @Test func attachmentTempURLSanitizesPathTraversal() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: "")
        let attachment = try AttachmentStore(context: store.mainContext).add(
            data: Data("hello".utf8),
            fileName: "../../outside.txt",
            typeIdentifier: "public.plain-text",
            to: note
        )
        let url = try #require(AttachmentFiles.temporaryURL(for: attachment))
        let expectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
            .standardizedFileURL
        #expect(url.standardizedFileURL.deletingLastPathComponent() == expectedDirectory)
        #expect(url.lastPathComponent == "outside.txt")
    }

    @Test func conflictingIncomingEditPreservesConflictCopy() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let context = store.mainContext
        let library = Library(context: context)
        let folder = try library.createFolder(named: "Work")
        let note = library.createNote(body: "Original", in: folder)
        try context.save()

        var editorText = ""
        let session = EditorSession(note: note, commands: nil, rendersMarkdown: false)
        session.attach(
            host: .init(
                text: { editorText },
                setText: { editorText = $0 },
                selection: { NSRange(location: 0, length: 0) },
                isComposing: { false },
                applyEdit: { _ in true },
                undoManager: { nil },
                applyFont: {},
                applyBodyStyle: {},
                setEditable: { _ in },
                focus: {}
            ),
            textLayoutManager: nil
        )
        // Simulate unsaved local typing + simultaneous external change (iCloud / Siri).
        editorText = "Local typing"
        let incomingAttachment = try AttachmentStore(context: context).add(
            data: Data([1, 2, 3]), fileName: "Incoming.pdf", typeIdentifier: "com.adobe.pdf", to: note
        )
        note.setBody("Incoming from iCloud\n" + AttachmentStore.markdown(for: incomingAttachment))
        session.update(note: note)
        session.detach()

        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 2)
        #expect(notes.contains { $0.id == note.id && $0.body == "Local typing" })
        let recovery = try #require(notes.first { $0.id != note.id })
        #expect(recovery.body.hasPrefix("Incoming from iCloud\n"))
        #expect(recovery.folder?.id == folder.id)
        let recoveredAttachment = try #require(recovery.attachments?.first)
        #expect(recoveredAttachment.id != incomingAttachment.id)
        #expect(recoveredAttachment.data == Data([1, 2, 3]))
        #expect(AttachmentLine.references(in: recovery.body) == [recoveredAttachment.id])
    }

    /// Regression test for empty-note Header and Bold inserting unstyled 12pt black `#` or `**`.
    @Test func emptyNoteHeaderAndBoldRenderWithThemeFontAndDimColor() throws {
        // Heading on an empty note (`# `) with unattributed raw storage must style at heading font + dimColor.
        let headingEdit = MarkdownEditing.edit(.heading, in: "", selection: NSRange(location: 0, length: 0))
        let (headingStorage, headingPreview) = fixture(headingEdit.replacement)
        defer { withExtendedLifetime(headingPreview) {} }
        headingPreview.didProgrammaticallyChangeSelection(to: headingEdit.selection)
        let headingParagraph = try #require(
            headingPreview.textContentStorage(headingStorage, textParagraphWith: NSRange(location: 0, length: headingEdit.replacement.utf16.count))?.attributedString
        )
        let headingFont = try #require(headingParagraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont)
        let headingColor = try #require(headingParagraph.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? EditorColor)
        #expect(headingFont.pointSize == EditorTheme.headingFont(level: 1).pointSize)
        #expect(components(headingColor) == components(EditorTheme.dimColor))
        #expect(headingPreview.activeFormattingCommands().contains(.heading))

        // Bold on an empty note (`****`, caret at 2) with unattributed raw storage must style at prose font + dimColor.
        let boldEdit = MarkdownEditing.edit(.bold, in: "", selection: NSRange(location: 0, length: 0))
        let (boldStorage, boldPreview) = fixture(boldEdit.replacement)
        defer { withExtendedLifetime(boldPreview) {} }
        boldPreview.didProgrammaticallyChangeSelection(to: boldEdit.selection)
        let boldParagraph = try #require(
            boldPreview.textContentStorage(boldStorage, textParagraphWith: NSRange(location: 0, length: boldEdit.replacement.utf16.count))?.attributedString
        )
        let boldFont = try #require(boldParagraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont)
        let boldColor = try #require(boldParagraph.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? EditorColor)
        #expect(boldFont.pointSize == EditorTheme.proseFont.pointSize)
        #expect(components(boldColor) == components(EditorTheme.dimColor))
        #expect(boldPreview.activeFormattingCommands().contains(.bold))

        // Moving caret outside `****` returns it to base prose color (never raw default black).
        boldPreview.selectionChanged(to: NSRange(location: boldEdit.replacement.utf16.count, length: 0))
        let plainParagraph = try #require(
            boldPreview.textContentStorage(boldStorage, textParagraphWith: NSRange(location: 0, length: boldEdit.replacement.utf16.count))?.attributedString
        )
        let plainFont = try #require(plainParagraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont)
        let plainColor = try #require(plainParagraph.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? EditorColor)
        #expect(plainFont.pointSize == EditorTheme.proseFont.pointSize)
        #expect(components(plainColor) == components(EditorTheme.baseColor))
        #expect(!boldPreview.activeFormattingCommands().contains(.bold))
    }

    @Test func trashedNoteSessionIsReadOnlyUntilRestored() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let context = store.mainContext
        let library = Library(context: context)
        let note = library.createNote(body: "Original")
        library.trash(note)
        try context.save()

        var editorText = ""
        var editableStates: [Bool] = []
        let commands = EditorCommands()
        let session = EditorSession(note: note, commands: commands, rendersMarkdown: false)
        session.attach(
            host: .init(
                text: { editorText },
                setText: { editorText = $0 },
                selection: { NSRange(location: 0, length: 0) },
                isComposing: { false },
                applyEdit: { edit in
                    editorText = (editorText as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                    return true
                },
                undoManager: { nil },
                applyFont: {},
                applyBodyStyle: {},
                setEditable: { editableStates.append($0) },
                focus: {}
            ),
            textLayoutManager: nil
        )
        #expect(!session.isEditable)
        #expect(commands.isReadOnly)
        #expect(editableStates.last == false)
        #expect(!session.perform(.bold))
        #expect(editorText == "Original")

        library.restore(note)
        session.update(note: note)
        #expect(session.isEditable)
        #expect(!commands.isReadOnly)
        #expect(editableStates.last == true)
        #expect(session.perform(.heading))
        #expect(editorText == "# Original")
        session.detach()
    }

    @Test func unreadableNoteSessionCannotOverwriteUpgradedBodyOnDetach() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let context = store.mainContext
        let library = Library(context: context)
        let note = library.createNote(body: "Original")
        try context.save()

        var editorText = ""
        var editableStates: [Bool] = []
        let commands = EditorCommands()
        let session = EditorSession(note: note, commands: commands, rendersMarkdown: false)
        session.attach(
            host: .init(
                text: { editorText },
                setText: { editorText = $0 },
                selection: { NSRange(location: 0, length: 0) },
                isComposing: { false },
                applyEdit: { edit in
                    editorText = (editorText as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                    return true
                },
                undoManager: { nil },
                applyFont: {},
                applyBodyStyle: {},
                setEditable: { editableStates.append($0) },
                focus: {}
            ),
            textLayoutManager: nil
        )

        // Simulate unsaved local text followed by a synced update from a newer app version.
        editorText = "Local stale edit"
        note.setBody("Upgraded format")
        note.minimumReaderVersion = NoteFormat.supportedReaderVersion + 1
        session.update(note: note)

        #expect(!session.isEditable)
        #expect(commands.isReadOnly)
        #expect(editableStates.last == false)
        #expect(!session.perform(.bold))
        #expect(editorText == "Local stale edit")

        session.detach()
        #expect(note.body == "Upgraded format")
        let allNotes = try context.fetch(FetchDescriptor<Note>())
        #expect(allNotes.count == 1)
    }

    @Test func deleteForwardAboveTableStepsToTableBoundaryInsteadOfDeleting() throws {
        let source = "Intro\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let (_, preview) = fixture(source)
        defer { withExtendedLifetime(preview) {} }
        guard case .edit(let edit) = preview.deleteForward(at: 5) else {
            Issue.record("Forward delete at end of line above table should step to table start")
            return
        }
        #expect(edit.range.length == 0)
        #expect(edit.replacement.isEmpty)
        #expect(edit.selection == NSRange(location: 6, length: 0))
    }

    @Test func replaceTableClampsOverlappingSelectionSafely() throws {
        let source = "| Long Header A | Long Header B |\n| --- | --- |\n| Value 1 | Value 2 |\nAfter"
        let (_, preview) = fixture(source)
        defer { withExtendedLifetime(preview) {} }
        var applied: TextEdit?
        preview.applyTableEdit = { applied = $0 }
        // Place caret inside the table range before shrinking the table.
        preview.didProgrammaticallyChangeSelection(to: NSRange(location: 40, length: 0))
        let smaller = MarkdownTable(header: ["A"], alignments: [.none], rows: [["1"]])
        preview.replaceTable(at: 0, with: smaller)
        let edit = try #require(applied)
        let resultLength = (source as NSString).length - edit.range.length + (edit.replacement as NSString).length
        #expect(NSMaxRange(edit.selection) <= resultLength)
        #expect(edit.selection.length == 0)
    }

    @Test("Inline code uses the active code font and code theme color without a background box")
    func inlineCodeUsesCodeFontAndCodeThemeColorWithoutBackground() throws {
        let original = AppearanceModel.shared.settings
        defer { AppearanceModel.shared.settings = original }

        let source = "Before `let x = 1` after"
        let codeRange = (source as NSString).range(of: "let x = 1")
        for theme in CodeTheme.builtIn {
            var next = original
            next.codeThemeID = theme.id
            AppearanceModel.shared.settings = next

            let (content, preview) = fixture(source)
            defer { withExtendedLifetime(preview) {} }
            let paragraph = try #require(
                preview.textContentStorage(content, textParagraphWith: NSRange(location: 0, length: source.utf16.count))?.attributedString
            )
            let font = try #require(paragraph.attribute(.font, at: codeRange.location, effectiveRange: nil) as? EditorFont)
            let foreground = try #require(paragraph.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? EditorColor)
            let background = paragraph.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil)

            #expect(font.fontName == EditorTheme.inlineCodeFont(matching: EditorTheme.proseFont).fontName)
            #expect(abs(font.pointSize - EditorTheme.inlineCodeFont(matching: EditorTheme.proseFont).pointSize) < 0.01)
            #expect(components(foreground) == components(EditorTheme.inlineCodeColor))
            #expect(components(foreground) == components(EditorTheme.color(for: .keyword)))
            #expect(background == nil)
        }
    }

    #if canImport(UIKit)
    @Test(arguments: ["```", "```\n", "```\n\n```\n", "```swift\nlet value = 1\n```"])
    func firstCodeCaretIsInsideNativeFragment(source: String) throws {
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        view.font = EditorTheme.proseFont
        view.text = source
        view.textContainerInset = .zero
        let manager = try #require(view.textLayoutManager)
        let storage = try #require(manager.textContentManager as? NSTextContentStorage)
        let preview = LivePreviewController(contentStorage: storage, layoutManager: manager)
        preview.reload()
        manager.ensureLayout(for: storage.documentRange)
        let fragment = try #require(manager.textLayoutFragment(for: storage.documentRange.location) as? CodeBlockFragment)
        let bounds = fragment.layoutFragmentFrame
        let caret = view.caretRect(for: view.beginningOfDocument)
        #expect(caret.minY >= bounds.minY)
        #expect(caret.maxY <= bounds.maxY)
        #expect(view.text == source)
    }

    @Test func keyboardInsetLetsTheLastLineScrollAboveTheKeyboard() throws {
        let textView = UITextView(usingTextLayoutManager: true)
        let controller = NativeEditorViewController(textView: textView)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let source = String(repeating: "A line of text\n", count: 70) + "Last line"
        textView.text = source
        controller.view.layoutIfNeeded()
        let manager = try #require(textView.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        textView.layoutIfNeeded()
        controller.updateKeyboardScrollSpace(overlap: 350)
        #expect(textView.adjustedContentInset.bottom >= 374)
        let lastLine = textView.caretRect(for: textView.endOfDocument)
        textView.scrollRectToVisible(lastLine.insetBy(dx: 0, dy: -12), animated: false)
        #expect(lastLine.maxY <= textView.bounds.maxY - textView.adjustedContentInset.bottom)
        #expect(textView.text == source)
        controller.updateKeyboardScrollSpace(overlap: 0)
        #expect(textView.contentInset.bottom == NativeEditorViewController.endOfNoteSpace)
    }

    @Test func surfaceReachesUnderNavigationAndKeepsTextBelowIt() async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: "Plain container fixture\n" + String(repeating: "line\n", count: 80))
        let host = UIHostingController(rootView: NavigationStack {
            EditorContainer(note: note, rendersMarkdown: false)
        }.modelContainer(store))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func editor(in controller: UIViewController) -> NativeEditorViewController? {
            if let controller = controller as? NativeEditorViewController { return controller }
            return controller.children.lazy.compactMap { editor(in: $0) }.first
        }
        func navigationBar(in view: UIView) -> UINavigationBar? {
            if let bar = view as? UINavigationBar { return bar }
            return view.subviews.lazy.compactMap { navigationBar(in: $0) }.first
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 390, height: 844)] {
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            await Task.yield()
            host.view.layoutIfNeeded()
            let native = try #require(editor(in: host))
            let bar = try #require(navigationBar(in: host.view))
            let textView = native.textView
            let editorFrame = textView.convert(textView.bounds, to: host.view)
            let barFrame = bar.convert(bar.bounds, to: host.view)
            // The scroll view fills the screen, so text can scroll under the bars...
            #expect(editorFrame.minY <= barFrame.minY)
            #expect(editorFrame.maxY == host.view.bounds.maxY)
            // ...and its inset keeps the first line clear of them, at rest.
            #expect(textView.adjustedContentInset.top >= barFrame.maxY)
            #expect(textView.contentOffset.y == -textView.adjustedContentInset.top)
        }
    }
    @Test func bridgeRespectsContainerWhenResized() async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: "# Layout fixture\n" + String(repeating: "line\n", count: 80))
        let host = UIHostingController(rootView: EditorViewport { NoteEditor(note: note, rendersMarkdown: false) }.padding(.top, 64))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func editor(in controller: UIViewController) -> NativeEditorViewController? {
            if let controller = controller as? NativeEditorViewController { return controller }
            return controller.children.lazy.compactMap { editor(in: $0) }.first
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 390, height: 844)] {
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            await Task.yield()
            host.view.layoutIfNeeded()
            let native = try #require(editor(in: host))
            let frame = native.textView.convert(native.textView.bounds, to: host.view)
            #expect(frame.minY >= 64)
            #expect(frame.maxY <= host.view.bounds.maxY)
            #expect(frame.height > 0)
        }
    }

    nonisolated static let longBlock = "```swift\n" + (0..<80).map { "    let value\($0) = \($0)\n" }.joined() + "```\nAfter"
    nonisolated static let longBlockCaret = (longBlock as NSString).range(of: "let value40 = 40").upperBound

    /// Frames of every layout fragment, in order. Equal frames mean equal layout, so nothing can jump or go missing.
    private func fragmentFrames(of view: UITextView) throws -> [CGRect] {
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        var frames: [CGRect] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            frames.append(fragment.layoutFragmentFrame)
            return true
        }
        return frames
    }

    private func previewedView(_ text: String) throws -> (UITextView, LivePreviewController) {
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        view.font = EditorTheme.proseFont
        view.textContainerInset = .zero
        view.text = text
        let manager = try #require(view.textLayoutManager)
        let storage = try #require(manager.textContentManager as? NSTextContentStorage)
        let preview = LivePreviewController(contentStorage: storage, layoutManager: manager)
        preview.reload()
        return (view, preview)
    }

    /// Typing in a code block lays out the same straight away as it does once everything has settled and as the
    /// final text does fresh. A difference is text that jumps or a card that is cut off.
    @Test(arguments: [
        ("```swift\nlet a = 1\n```\nAfter", 18, ["\n"]),
        ("```swift\nlet a = 1\n```\nAfter", 18, ["\n", "x", "\n", "y"]),
        ("Before\n\n```\nx\n```\n\nAfter", 13, ["\n", "\n"]),
        ("```\n\n```", 4, ["a", "\n", "b"]),
        // A long block: the edit restyles a few lines, and the rest of the block must still lay out as before.
        (EditorPresentationTests.longBlock, EditorPresentationTests.longBlockCaret, ["\n", "x", "\n", "y", "\n"]),
    ])
    func editingCodeLaysOutLikeFreshText(source: String, caret: Int, typed: [String]) async throws {
        let (view, preview) = try previewedView(source)
        defer { withExtendedLifetime(preview) {} }
        _ = try fragmentFrames(of: view)
        view.selectedRange = NSRange(location: caret, length: 0)
        for piece in typed {
            view.insertText(piece)
            let immediate = try fragmentFrames(of: view)
            try await Task.sleep(for: .milliseconds(60))
            let settled = try fragmentFrames(of: view)
            let (fresh, freshPreview) = try previewedView(view.text)
            defer { withExtendedLifetime(freshPreview) {} }
            let expected = try fragmentFrames(of: fresh)
            #expect(settled == expected, "settled layout differs from fresh after typing \(piece.debugDescription) in \(source.debugDescription)")
            #expect(immediate == settled, "layout straight after typing \(piece.debugDescription) was stale in \(source.debugDescription)")
        }
    }

    /// Deleting the open note forever must not touch the deleted model while the editor is still on screen.
    @Test func deletingTheOpenNoteForeverTearsDownTheEditor() async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: store.mainContext)
        let note = library.createNote(body: "Doomed note")
        library.trash(note)
        try store.mainContext.save()
        let host = UIHostingController(rootView: NavigationStack { NoteDetailView(id: note.id) }.modelContainer(store))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        // Typing leaves an unsaved edit that the editor flushes while it is dismantled.
        func textView(in view: UIView) -> UITextView? {
            if let view = view as? UITextView { return view }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let typing = try #require(textView(in: host.view))
        typing.insertText(" typed")
        library.deleteForever(note)
        try store.mainContext.save()
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try store.mainContext.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    /// The Recently Deleted list stays on screen while its notes are deleted forever, one at a time and all at once.
    @Test func deletingForeverFromTheTrashListKeepsTheListAlive() async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: store.mainContext)
        let notes = (1...4).map { library.createNote(body: "Trashed \($0)") }
        notes.forEach { library.trash($0) }
        try store.mainContext.save()
        let selected = notes[0].id
        let host = UIHostingController(rootView: NavigationStack {
            NoteListView(scope: .trash, selectedNoteID: .constant(selected))
        }.modelContainer(store))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func settle() async throws {
            for _ in 0..<5 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await settle()
        library.deleteForever(notes[0])
        try store.mainContext.save()
        try await settle()
        _ = try library.emptyTrash()
        try store.mainContext.save()
        try await settle()
        #expect(try store.mainContext.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    /// Deleting trashed notes with folders and tags inside a live Sidebar + NoteList keeps both columns stable.
    @Test func deletingTrashedNotesWithFoldersAndTagsKeepsSidebarAndListAlive() async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: store.mainContext)
        let folder = try library.createFolder(named: "Work")
        let note = library.createNote(body: "# Trashed Note\nSome content", in: folder)
        try library.addTag(named: "urgent", to: note)
        library.trash(note)
        try store.mainContext.save()
        let host = UIHostingController(rootView: NavigationStack {
            VStack {
                SidebarView(selection: .constant(.trash), asksNewFolder: .constant(false))
                NoteListView(scope: .trash, selectedNoteID: .constant(note.id))
            }
        }.modelContainer(store))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func settle() async throws {
            for _ in 0..<5 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await settle()
        library.deleteForever(note)
        try store.mainContext.save()
        try await settle()
        #expect(try store.mainContext.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    @Test(arguments: [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 820, height: 1180)])
    func nativeSurfaceFillsItsAllocatedViewport(size: CGSize) throws {
        let controller = NativeEditorViewController(textView: UITextView(usingTextLayoutManager: true))
        // A parent stands in for the navigation bar and home indicator, whose safe area the controller must turn into insets.
        let parent = UIViewController()
        parent.addChild(controller)
        controller.view.frame = parent.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = parent
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        parent.additionalSafeAreaInsets = UIEdgeInsets(top: 88, left: 0, bottom: 34, right: 0)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        #expect(controller.textView.frame == controller.view.bounds)
        #expect(controller.textView.frame.height > 0)
        // The safe area becomes the scroll view's inset, even when the content is shorter than the view.
        #expect(controller.textView.contentInsetAdjustmentBehavior == .always)
        #expect(controller.textView.adjustedContentInset.top >= 88)
        #expect(controller.textView.adjustedContentInset.bottom >= 34)
    }

    #endif
}

#if os(macOS)
/// The grid drawn for a table must sit over the room the text layout reserves for it, and that room must be as tall as the
/// grid, or the text above or below runs under it.
@MainActor
struct TablePlacementTests {
    private func find<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        (view as? V).map { [$0] } ?? [] + view.subviews.flatMap { find(type, in: $0) }
    }

    private func editor(showing body: String, height: CGFloat = 700, commands: EditorCommands? = nil)
        async throws -> (window: NSWindow, textView: NSTextView, note: Note, store: ModelContainer) {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: body)
        try store.mainContext.save()
        let host = NSHostingView(rootView: NoteEditor(note: note, commands: commands).modelContainer(store).frame(maxWidth: .infinity, maxHeight: .infinity))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(900))
        let content = try #require(window.contentView)
        let textView = try #require(find(NSTextView.self, in: content).first)
        return (window, textView, note, store)
    }

    private func tableHost(in textView: NSTextView) -> NSView? {
        textView.subviews.first { String(describing: type(of: $0)).contains("NSHostingView") }
    }

    /// Where the table's view is, read before any layout is forced, and where the text layout puts the table's first row.
    private func placement(of textView: NSTextView, tableStart: Int) throws -> (view: CGFloat, reserved: CGFloat)? {
        let hostY = textView.subviews.first { String(describing: type(of: $0)).contains("NSHostingView") }?.frame.minY
        let manager = try #require(textView.textLayoutManager)
        let storage = try #require(manager.textContentManager as? NSTextContentStorage)
        manager.ensureLayout(for: manager.documentRange)
        var top: CGFloat?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location) == tableStart {
                top = fragment.layoutFragmentFrame.minY
                return false
            }
            return true
        }
        guard let hostY, let top else { return nil }
        return (hostY, top + textView.textContainerOrigin.y + LivePreviewController.cardMargin)
    }

    @Test func scratchQuoteBar() async throws {
        let body = "Intro\n> hello\n> hello"
        let (window, textView, _, _) = try await editor(showing: body, height: 300)
        defer { window.close() }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (body as NSString).length, length: 0))
        func shot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(500))
            let view = try #require(window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            Attachment.record(data, named: name)
        }
        try await shot("1-start")
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await shot("2-after-return")
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        try await shot("3-after-backspace")
    }

    @Test func tableFollowsTheListAboveItWhileTyping() async throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let body = "Intro\n\n- [ ] a\n- [ ] b\n\n- one\n- two\n\n1. x\n2. y\n\n" + table + "\nOutro\n"
        let (window, textView, _, _) = try await editor(showing: body)
        defer { window.close() }
        window.makeFirstResponder(textView)
        let two = (body as NSString).range(of: "- two")
        textView.setSelectedRange(NSRange(location: NSMaxRange(two), length: 0))
        func check(_ step: String) async throws {
            try await Task.sleep(for: .milliseconds(400))
            let start = (textView.string as NSString).range(of: "| A").location
            let found = try #require(try placement(of: textView, tableStart: start), "\(step): the table has no view")
            #expect(abs(found.view - found.reserved) < 0.5, "\(step): the table is \(found.view - found.reserved) points off its room")
        }
        try await check("at the start")
        for item in 1...4 {
            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            textView.insertText("item \(item)", replacementRange: textView.selectedRange())
            try await check("after Return and typing \(item)")
        }
        for step in 1...4 {
            for _ in 0..<7 { textView.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
            try await check("after deleting \(step)")
        }
    }

    @Test func roomReservedForATableIsAsTallAsItsGridWhateverItsRowCount() async throws {
        func table(rows: Int) -> String {
            "| Column 1 | Column 2 |\n| --- | --- |\n" + String(repeating: "| a | b |\n", count: rows)
        }
        let body = "Shopping\n- Hello\n- hello\n\n" + table(rows: 2) + "\n1. hello\n2. Hello\n> quote\n"
        let (window, textView, _, _) = try await editor(showing: body)
        defer { window.close() }
        for rows in [2, 5, 1, 4, 6] {
            if rows != 2 {
                let source = textView.string as NSString
                let start = source.range(of: "| Column 1").location
                var end = start
                while end < source.length, source.substring(with: source.lineRange(for: NSRange(location: end, length: 0))).hasPrefix("|") {
                    end = NSMaxRange(source.lineRange(for: NSRange(location: end, length: 0)))
                }
                // The last row's line break belongs to the line after the table, as `replaceTable` leaves it.
                let range = NSRange(location: start, length: end - start - 1)
                let replacement = String(table(rows: rows).dropLast())
                if textView.shouldChangeText(in: range, replacementString: replacement) {
                    textView.textStorage?.replaceCharacters(in: range, with: replacement)
                    textView.didChangeText()
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            // The grid is 34 points a row; the row of its header counts as one.
            let grid = try #require(textView.subviews.first { String(describing: type(of: $0)).contains("NSHostingView") }).frame.height
            #expect(grid == CGFloat(rows + 1) * 34, "\(rows) rows")
            let manager = try #require(textView.textLayoutManager)
            let storage = try #require(manager.textContentManager as? NSTextContentStorage)
            manager.ensureLayout(for: manager.documentRange)
            let tableStart = (textView.string as NSString).range(of: "| Column 1").location
            var room: CGFloat = 0
            var counting = false
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
                let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
                let text = (fragment.textElement as? NSTextParagraph)?.attributedString.string ?? ""
                if offset == tableStart { counting = true }
                guard counting else { return true }
                guard offset >= tableStart, !text.isEmpty, text.contains("|") || offset == tableStart else { return false }
                room += fragment.layoutFragmentFrame.height
                return true
            }
            #expect(room >= grid, "\(rows) rows: the room reserved is \(room) points and the grid is \(grid)")
        }
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A picture attached above a table pushes the table below what is on screen, where the text view has no layout for it.
    /// Its view must not stay behind over the text that is there now, and must be right once it scrolls into view.
    @Test func attachingAPictureAboveATableDoesNotLeaveItsViewOverTheText() async throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let body = "Intro\n\n- one\n- two\n\n1. x\n2. y\n\n" + table + "\nOutro\n"
        let commands = EditorCommands()
        // Short enough that the table, once the picture pushes it down, is off the bottom.
        let (window, textView, note, store) = try await editor(showing: body, height: 400, commands: commands)
        defer { window.close() }
        window.makeFirstResponder(textView)
        let one = (body as NSString).range(of: "- one")
        textView.setSelectedRange(NSRange(location: one.location, length: 0))

        // What the picker does: store the picture, then put its Markdown at the caret.
        let attachment = try AttachmentStore(context: store.mainContext).add(
            data: try png(width: 800, height: 1200), fileName: "Parrot.png", typeIdentifier: "public.png", to: note)
        commands.insertBlock(AttachmentStore.markdown(for: attachment))
        try await Task.sleep(for: .milliseconds(400))

        // Read before anything forces a layout, as the app has it.
        let host = try #require(tableHost(in: textView))
        let hidden = host.isHidden, hostY = host.frame.minY
        let start = (textView.string as NSString).range(of: "| A").location
        let reserved = try #require(try placement(of: textView, tableStart: start)).reserved
        #expect(hidden || abs(hostY - reserved) < 0.5, "the table's view is on screen at \(hostY), but its room is at \(reserved)")

        // Scrolled into view, the table is shown and exactly on its room.
        textView.scrollToEndOfDocument(nil)
        try await Task.sleep(for: .milliseconds(600))
        let shown = try #require(tableHost(in: textView))
        let viewY = shown.frame.minY
        let roomY = try #require(try placement(of: textView, tableStart: start)).reserved
        #expect(!shown.isHidden, "the table is back in view and must be shown")
        #expect(abs(viewY - roomY) < 0.5, "the table is \(viewY - roomY) points off its room")
    }
}
#endif

