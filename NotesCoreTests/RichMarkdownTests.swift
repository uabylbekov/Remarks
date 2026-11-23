import Testing
import Foundation
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import NotesCore
@testable import Notes

struct RichMarkdownTests {
    @Test func recognizesEquationsAndClosedDiagrams() {
        let text = "Inline $x^2$ here.\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\nflowchart LR\n A --> B\n```\n"
        let items = RichMarkdown.scan(text)
        #expect(items.map(\.kind) == [.inlineMath, .displayMath, .mermaid])
        #expect(items[0].content == "x^2")
        #expect(items[1].content.trimmingCharacters(in: .whitespacesAndNewlines) == #"\frac{a}{b}"#)
        #expect(items[2].content.contains("A --> B"))
        for item in items { #expect(NSMaxRange(item.range) <= text.utf16.count) }
    }

    @Test func preservesCurrencyEscapesCodeAndIncompleteSource() {
        let source = #"Cost $5 and $10; \$x$ and `$code$` and [link $a$](https://example.com)"#
            + "\n```swift\nlet x = \"$y$\"\n```\n$$\nunclosed\n"
        #expect(RichMarkdown.scan(source).isEmpty)
        #expect(RichMarkdown.scan("```mermaid\nflowchart LR\n A --> B").isEmpty)
    }

    @Test func unicodeRangesAndSingleCharacterMath() {
        let source = "📝 $x$ and $\\alpha$."
        let items = RichMarkdown.scan(source)
        #expect(items.count == 2)
        #expect((source as NSString).substring(with: items[0].range) == "$x$")
        #expect(items[1].content == #"\alpha"#)
        #expect(RichMarkdown.scan("$$x^2$$\n").first?.kind == .displayMath)
    }

    @Test(arguments: [MarkdownCommand.math, .diagram])
    func commandsSelectEditableSourceAndUndo(command: MarkdownCommand) throws {
        let text = "Before 📝"
        let selection = NSRange(location: text.utf16.count, length: 0)
        let edit = MarkdownEditing.edit(command, in: text, selection: selection)
        let transaction = try #require(edit.transaction(in: text, selectionBefore: selection))
        #expect(edit.selection.length > 0)
        #expect(RichMarkdown.scan(transaction.result).count == 1)
    }
}

@MainActor
struct RichPreviewTests {
    @Test(arguments: [RichMarkdown.Kind.inlineMath, .displayMath, .mermaid])
    func bundledRenderersProduceSnapshots(kind: RichMarkdown.Kind) async throws {
        let renderer = RichPreviewRenderer()
        let source = kind == .mermaid ? "flowchart LR\n A[Start] --> B[End]" : #"\frac{a}{b} + x^2"#
        let preview = try await renderer.render(.init(source: source, kind: kind.rawValue,
                                                     width: 360, fontSize: 18, dark: false))
        #expect(preview.size.width > 10 && preview.size.width <= 360)
        #expect(preview.size.height > 10 && preview.size.height < 1000)
        #expect(preview.image.size.width > 10)
        if kind == .inlineMath {
            #expect(preview.baseline > 0 && preview.baseline < preview.size.height)
        } else {
            #expect(preview.baseline == preview.size.height)
        }
    }

    @Test(arguments: ["Before $x^2$ after\n", "Before $x_i + y_j$ after\n", "$$\n\\frac{a}{b}\n$$\nAfter", "```mermaid\nflowchart LR\n A --> B\n```\nAfter"])
    func previewRevealsSourceAndKeepsStorageUnchanged(source: String) async throws {
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        content.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: EditorTheme.bodyAttributes))
        let controller = LivePreviewController(contentStorage: content, layoutManager: manager)
        defer { controller.detach() }
        controller.selectionChanged(to: NSRange(location: source.utf16.count, length: 0))
        let item = try #require(RichMarkdown.scan(source).first)
        let line = (source as NSString).lineRange(for: NSRange(location: item.range.location, length: 0))
        let anchor = item.range.location - line.location
        var rendered: NSAttributedString?
        for _ in 0..<120 {
            rendered = controller.textContentStorage(content, textParagraphWith: line)?.attributedString
            if rendered?.attribute(.attachment, at: anchor, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rendered?.attribute(.attachment, at: anchor, effectiveRange: nil) != nil)
        #expect(rendered?.length == line.length)
        #expect(content.textStorage?.string == source)
        controller.selectionChanged(to: NSRange(location: item.range.location + 1, length: 0))
        let editing = controller.textContentStorage(content, textParagraphWith: line)?.attributedString
        #expect(editing?.attribute(.attachment, at: anchor, effectiveRange: nil) == nil)
        #expect(editing?.string ?? (source as NSString).substring(with: line) == (source as NSString).substring(with: line))
        #expect(content.textStorage?.string == source)
    }

    @Test func latexMarkersDoNotStyleSurroundingProse() throws {
        let value = "$x_i$ outside _italic_"
        let paragraph = NSMutableAttributedString(string: value, attributes: EditorTheme.bodyAttributes)
        _ = InlineStyler.style(paragraph, selection: nil)
        let outside = (value as NSString).range(of: "outside")
        let font = try #require(paragraph.attribute(.font, at: outside.location, effectiveRange: nil) as? EditorFont)
        #expect(font == EditorTheme.proseFont)
        let underscore = (value as NSString).range(of: "_")
        let sourceFont = try #require(paragraph.attribute(.font, at: underscore.location, effectiveRange: nil) as? EditorFont)
        #expect(sourceFont.pointSize > 1)
        let italic = (value as NSString).range(of: "italic")
        let italicFont = try #require(paragraph.attribute(.font, at: italic.location, effectiveRange: nil) as? EditorFont)
        #expect(italicFont == EditorTheme.traited(EditorTheme.proseFont, italic: true))
    }

    @Test func oneRendererCanResizeAndSwitchFormats() async throws {
        let renderer = RichPreviewRenderer()
        for width in [360, 180] {
            for kind in ["displayMath", "mermaid"] {
                let source = kind == "mermaid" ? "flowchart LR\n A --> B" : #"\sum_{i=1}^{100} i = 5050"#
                let preview = try await renderer.render(.init(source: source, kind: kind, width: width, fontSize: 18, dark: true))
                #expect(preview.size.width <= CGFloat(width))
                #expect(preview.size.height > 10)
            }
        }
    }

    @Test(arguments: ["$$\nE = mc^2\n$$\nAfter", "```mermaid\nflowchart LR\n A --> B\n```\nAfter"])
    func switchingColorSchemeRefreshesAnUnfocusedEditor(source: String) async throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: source)
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        let storage = try #require(content.textStorage)
        let selection = NSRange(location: source.utf16.count, length: 0)
        var styleCount = 0
        let session = EditorSession(note: note, commands: nil)
        session.attach(host: .init(
            text: { storage.string },
            setText: { storage.setAttributedString(NSAttributedString(string: $0)) },
            selection: { selection }, isComposing: { false }, applyEdit: { _ in false },
            undoManager: { nil }, applyFont: {},
            applyBodyStyle: {
                styleCount += 1
                storage.addAttributes(EditorTheme.bodyAttributes, range: NSRange(location: 0, length: storage.length))
            }, setEditable: { _ in }, focus: { Issue.record("Appearance must not focus the editor") }
        ), textLayoutManager: manager)
        defer { session.detach() }
        let preview = try #require(session.preview)
        let line = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        var previousImage: Data?
        for scheme in [ColorScheme.light, .dark, .light] {
            session.applyAppearance(revision: 0, colorScheme: scheme)
            #expect(preview.colorScheme == scheme)
            var image: RichPreviewImage?
            for _ in 0..<120 {
                let paragraph = preview.textContentStorage(content, textParagraphWith: line)?.attributedString
                image = (paragraph?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
                if image != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let rendered = try #require(image)
            #if canImport(UIKit)
            let data = try #require(rendered.pngData())
            #else
            let data = try #require(rendered.tiffRepresentation)
            #endif
            if let previousImage { #expect(data != previousImage) }
            previousImage = data
            let count = styleCount
            session.applyAppearance(revision: 0, colorScheme: scheme)
            #expect(styleCount == count)
            #expect(storage.string == source)
            #expect(note.body == source)
        }
    }

    @Test(arguments: ["$$\n\\sum_{i=1}^{100} i + a + b + c + d + e = 5050\n$$\nAfter", "```mermaid\nflowchart LR\n A[Write note] --> B[Review] --> C[Publish]\n```\nAfter"])
    func resizingKeepsTheRenderedBlockVisible(source: String) async throws {
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 500, height: 1000))
        content.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: EditorTheme.bodyAttributes))
        let controller = LivePreviewController(contentStorage: content, layoutManager: manager)
        defer { controller.detach() }
        controller.selectionChanged(to: NSRange(location: source.utf16.count, length: 0))
        let line = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        func attachment() -> NSTextAttachment? {
            let paragraph = controller.textContentStorage(content, textParagraphWith: line)?.attributedString
            return paragraph?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        }
        for _ in 0..<120 {
            if attachment() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try #require(attachment())
        // Request many intermediate widths before WebKit can finish any new snapshot.
        for width in Array(stride(from: 490, through: 180, by: -2)) + [700, 320, 500] {
            manager.textContainer?.size.width = CGFloat(width)
            controller.containerWidthMayHaveChanged()
            let image = try #require(attachment(), "A resize must not expose source or collapse the rendered block")
            #expect(image.bounds.width <= CGFloat(width) - 2 * controller.linePadding)
            #expect(image.bounds.height > 0)
            #expect(content.textStorage?.string == source)
        }
    }

    @Test func resizeRequestsCoalesceToTheFinalWidth() async throws {
        let renderer = RichPreviewRenderer()
        defer { renderer.cancel() }
        let item = try #require(RichMarkdown.scan("$$x^2$$").first)
        var initial: RichPreviewRenderer.Preview?
        for _ in 0..<120 {
            initial = renderer.preview(for: item, width: 500, dark: false, completion: {})
            if initial != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try #require(initial)
        var completedWidths: [Int] = []
        for width in stride(from: 490, through: 180, by: -2) {
            let preview = renderer.preview(for: item, width: CGFloat(width), dark: false) { completedWidths.append(width) }
            #expect(preview != nil)
        }
        for _ in 0..<120 {
            if completedWidths.contains(180) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(completedWidths == [180])
    }

    @Test func reopeningANoteReusesItsSnapshotImmediately() async throws {
        let source = "```mermaid\nflowchart LR\n A[Cached note] --> B[Reopened note]\n```\nAfter"
        func fixture() -> (NSTextContentStorage, LivePreviewController) {
            let content = NSTextContentStorage()
            let manager = NSTextLayoutManager()
            content.addTextLayoutManager(manager)
            manager.textContainer = NSTextContainer(size: CGSize(width: 420, height: 1000))
            content.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: EditorTheme.bodyAttributes))
            let preview = LivePreviewController(contentStorage: content, layoutManager: manager)
            preview.selectionChanged(to: NSRange(location: source.utf16.count, length: 0))
            return (content, preview)
        }
        let line = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        func image(_ content: NSTextContentStorage, _ controller: LivePreviewController) -> RichPreviewImage? {
            let paragraph = controller.textContentStorage(content, textParagraphWith: line)?.attributedString
            return (paragraph?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        }
        let (firstContent, first) = fixture()
        var original: RichPreviewImage?
        for _ in 0..<120 {
            original = image(firstContent, first)
            if original != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let cached = try #require(original)
        first.detach()
        let (secondContent, second) = fixture()
        defer { second.detach() }
        // No await or focus change: opening another editor gets the completed image on its first layout.
        #expect(image(secondContent, second) === cached)
    }

    @Test func closingOneWindowDoesNotCancelAnotherWindowsPreview() async throws {
        let renderer = RichPreviewRenderer()
        defer { renderer.cancel() }
        let item = try #require(RichMarkdown.scan("$$x^3$$").first)
        let first = UUID(), second = UUID()
        var firstCompleted = false, secondCompleted = false
        _ = renderer.preview(for: item, width: 400, dark: false, requester: first) { firstCompleted = true }
        _ = renderer.preview(for: item, width: 400, dark: false, requester: second) { secondCompleted = true }
        renderer.release(requester: first)
        for _ in 0..<120 {
            if secondCompleted { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(secondCompleted)
        #expect(!firstCompleted)
        #expect(renderer.preview(for: item, width: 400, dark: false, requester: second, completion: {}) != nil)
    }

    @Test func invalidSyntaxDoesNotProduceAPreview() async {
        let renderer = RichPreviewRenderer()
        do {
            _ = try await renderer.render(.init(source: #"\notARealCommand{a}"#, kind: "displayMath",
                                                 width: 360, fontSize: 18, dark: false))
            Issue.record("Invalid equation must remain editable source")
        } catch { }
    }
}
