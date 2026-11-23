import Testing
import SwiftUI
import SwiftData
import NotesCore
@testable import Notes
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct EditorEngineParsingTests {
    @Test func mathOwnsItsLiteralContentsAndCodeOwnsItsMathDelimiters() throws {
        let text = "$$\n# literal\n- item\n| x | y |\n```swift\n$$\n\n```text\n$$\n```\nAfter"
        let document = MarkdownDocument(text)
        let first = try #require(document.blocks.first)
        guard case .math(let math) = first.kind else { Issue.record("Expected a math block"); return }
        #expect((text as NSString).substring(with: math.body).contains("```swift"))
        #expect(document.codeBlocks.count == 1)
        #expect(document.codeBlocks.first?.language == "text")
        #expect(RichMarkdown.scan(text).map(\.kind) == [.displayMath])
    }

    @Test func inlineMathHasOneGrammarForEscapesAndEmphasis() throws {
        let text = #"📝 $x_i + y_j + \$5$ and _italic_ and `$literal$`"#
        let spans = InlineScanner.spans(in: text)
        #expect(spans.filter { $0.kind == .math }.count == 1)
        #expect(spans.filter { $0.kind == .italic }.count == 1)
        let math = try #require(spans.first { $0.kind == .math })
        #expect((text as NSString).substring(with: math.content) == #"x_i + y_j + \$5"#)
        #expect(RichMarkdown.scan(text).first?.range == math.range)
        #expect(RichMarkdown.scan(#"\\$x$"#).count == 1)
        #expect(RichMarkdown.scan(#"\$x$"#).isEmpty)
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"])
    func displayMathSupportsNativeLineEndings(newline: String) throws {
        let text = ["$$", #"\frac{a}{b}"#, "$$", "After"].joined(separator: newline)
        let item = try #require(RichMarkdown.scan(text).first)
        #expect(item.kind == .displayMath)
        #expect(item.content.trimmingCharacters(in: .whitespacesAndNewlines) == #"\frac{a}{b}"#)
    }

    @Test func editingMathBodyRemainsIncremental() {
        let text = String(repeating: "Before\n", count: 30) + "$$\na + b\n$$\n" + String(repeating: "After\n", count: 30)
        let document = MarkdownDocument(text)
        let range = (text as NSString).range(of: "a + b")
        let changed = (text as NSString).replacingCharacters(in: range, with: "c + d")
        let update = document.updating(changed, editedRange: range, changeInLength: 0)
        #expect(update.document == MarkdownDocument(changed))
        #expect(update.reparsedRange.length < text.utf16.count / 2)
    }

    @Test func changingDisplayDelimitersMatchesFullParsing() {
        for text in ["Before\n$$\na\n$$\nAfter", "Before\n$$\na\nAfter\nMore"] {
            for offset in text.indices {
                let range = NSRange(offset..<text.index(after: offset), in: text)
                let changed = (text as NSString).replacingCharacters(in: range, with: "")
                let update = MarkdownDocument(text).updating(changed, editedRange: NSRange(location: range.location, length: 0),
                                                            changeInLength: -range.length)
                #expect(update.document == MarkdownDocument(changed))
            }
        }
    }
}

@MainActor
struct EditorEngineCompositionTests {
    @Test func compositionDefersSyncAppearanceAndSourceMode() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: "Original")
        var text = ""
        var composing = false
        var styles = 0
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        let session = EditorSession(note: note, commands: nil)
        session.attach(host: .init(
            text: { text }, setText: { text = $0 },
            selection: { NSRange(location: text.utf16.count, length: 0) },
            isComposing: { composing }, applyEdit: { _ in false }, undoManager: { nil },
            applyFont: {}, applyBodyStyle: { styles += 1 }, setEditable: { _ in }, focus: {}
        ), textLayoutManager: manager)
        defer { session.detach() }
        session.applyAppearance(revision: 0, colorScheme: .light)
        let before = styles
        composing = true
        note.setBody("Incoming")
        session.update(note: note)
        session.applyAppearance(revision: 1, colorScheme: .dark)
        session.applyAppearance(revision: 0, colorScheme: .light)
        session.setRendersMarkdown(false)
        session.setRendersMarkdown(true)
        #expect(text == "Original")
        #expect(styles == before)
        #expect(session.preview != nil)
        composing = false
        session.handleSelectionChange { _ in }
        #expect(text == "Incoming")
        #expect(session.preview?.colorScheme == .light)
        #expect(session.preview != nil)
    }

    @Test func backgroundingFlushesCommittedTypingButNotMarkedText() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote(body: "Original")
        try store.mainContext.save()
        var text = ""
        var composing = false
        let session = EditorSession(note: note, commands: nil, rendersMarkdown: false)
        session.attach(host: .init(
            text: { text }, setText: { text = $0 }, selection: { NSRange(location: text.utf16.count, length: 0) },
            isComposing: { composing }, applyEdit: { _ in false }, undoManager: { nil },
            applyFont: {}, applyBodyStyle: {}, setEditable: { _ in }, focus: {}
        ), textLayoutManager: nil)
        defer { session.detach() }
        text = "Committed typing"
        session.textDidChange()
        #expect(store.mainContext.hasChanges)
        session.scenePhaseChanged(to: .background)
        #expect(note.body == "Committed typing")
        #expect(!store.mainContext.hasChanges)
        composing = true
        text = "Uncommitted marked text"
        session.scenePhaseChanged(to: .inactive)
        #expect(note.body == "Committed typing")
        #expect(!store.mainContext.hasChanges)
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"])
    func aCaretAfterAMathBlockNewlineLeavesThePreviewVisible(newline: String) async throws {
        let source = "$$x$$" + newline
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        content.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: EditorTheme.bodyAttributes))
        let controller = LivePreviewController(contentStorage: content, layoutManager: manager)
        defer { controller.detach() }
        controller.selectionChanged(to: NSRange(location: source.utf16.count, length: 0))
        #expect(!controller.isInCodeBlock(source.utf16.count))
        let line = NSRange(location: 0, length: source.utf16.count)
        var rendered = false
        for _ in 0..<120 {
            let paragraph = controller.textContentStorage(content, textParagraphWith: line)?.attributedString
            rendered = paragraph?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
            if rendered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rendered)
    }

    @Test func asyncPreviewInvalidationWaitsForMarkedText() throws {
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 400, height: 1000))
        content.textStorage?.setAttributedString(NSAttributedString(string: "# Heading\nAfter", attributes: EditorTheme.bodyAttributes))
        let controller = LivePreviewController(contentStorage: content, layoutManager: manager)
        defer { controller.detach() }
        var composing = true
        var redraws = 0
        controller.isComposing = { composing }
        controller.onTablesChanged = { redraws += 1 }
        controller.reload()
        #expect(redraws == 0)
        #expect(controller.textContentStorage(content, textParagraphWith: NSRange(location: 0, length: 10)) == nil)
        composing = false
        controller.flushPendingRedrawIfNeeded()
        #expect(redraws == 1)
        #expect(content.textStorage?.string == "# Heading\nAfter")
    }
}

@MainActor
private final class ControlledPreviewBackend {
    var keys: [RichPreviewRenderer.Key] = []
    private var pending: [Int: CheckedContinuation<RichPreviewRenderer.Preview, Error>] = [:]

    func render(_ key: RichPreviewRenderer.Key) async throws -> RichPreviewRenderer.Preview {
        let index = keys.count
        keys.append(key)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func complete(_ index: Int, with value: RichPreviewRenderer.Preview) {
        pending.removeValue(forKey: index)?.resume(returning: value)
    }

    func cancelAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
struct EditorEngineSchedulerTests {
    private func preview() -> RichPreviewRenderer.Preview {
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.label.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        #else
        let image = NSImage(size: CGSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            return true
        }
        #endif
        return .init(image: image, size: CGSize(width: 8, height: 8))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Scheduled operation did not complete")
    }

    @Test func windowsKeepIndependentWidths() async throws {
        let backend = ControlledPreviewBackend()
        let renderer = RichPreviewRenderer(render: { try await backend.render($0) })
        defer { renderer.cancel(); backend.cancelAll() }
        let item = try #require(RichMarkdown.scan("$$x^2$$").first)
        var firstDone = false, secondDone = false
        _ = renderer.preview(for: item, width: 240, dark: false, requester: UUID()) { firstDone = true }
        _ = renderer.preview(for: item, width: 600, dark: false, requester: UUID()) { secondDone = true }
        try await waitUntil { backend.keys.count == 1 }
        backend.complete(0, with: preview())
        try await waitUntil { backend.keys.count == 2 }
        #expect(firstDone)
        #expect(!secondDone)
        #expect(backend.keys.map(\.width) == [240, 600])
        backend.complete(1, with: preview())
        try await waitUntil { secondDone }
    }

    @Test func identicalEquationsInAHeadingAndBodyKeepTheirOwnFontRequests() async throws {
        let backend = ControlledPreviewBackend()
        let renderer = RichPreviewRenderer(render: { try await backend.render($0) })
        defer { renderer.cancel(); backend.cancelAll() }
        let item = try #require(RichMarkdown.scan("$$x^2$$").first)
        let owner = UUID()
        var headingDone = false, bodyDone = false
        _ = renderer.preview(for: item, width: 400, dark: false, fontSize: 36, requester: owner) { headingDone = true }
        _ = renderer.preview(for: item, width: 400, dark: false, fontSize: 18, requester: owner) { bodyDone = true }
        try await waitUntil { backend.keys.count == 1 }
        #expect(backend.keys.first?.fontSize == 36)
        backend.complete(0, with: preview())
        try await waitUntil { backend.keys.count == 2 }
        #expect(headingDone)
        #expect(!bodyDone)
        #expect(backend.keys.last?.fontSize == 18)
        backend.complete(1, with: preview())
        try await waitUntil { bodyDone }
    }

    @Test func cancelledGenerationCannotPublishOrStopItsReplacement() async throws {
        let backend = ControlledPreviewBackend()
        let renderer = RichPreviewRenderer(render: { try await backend.render($0) })
        defer { renderer.cancel(); backend.cancelAll() }
        let item = try #require(RichMarkdown.scan("$$x^2$$").first)
        var oldDone = false, newDone = false
        _ = renderer.preview(for: item, width: 400, dark: false) { oldDone = true }
        try await waitUntil { backend.keys.count == 1 }
        renderer.cancel()
        _ = renderer.preview(for: item, width: 400, dark: false) { newDone = true }
        try await waitUntil { backend.keys.count == 2 }
        backend.complete(0, with: preview())
        await Task.yield()
        #expect(!oldDone)
        #expect(!newDone)
        let latest = preview()
        backend.complete(1, with: latest)
        try await waitUntil { newDone }
        #expect(renderer.preview(for: item, width: 400, dark: false, completion: {})?.image === latest.image)
    }

    @Test func transientFailureRetriesWithoutPoisoningValidSource() async throws {
        var calls = 0
        var resets = 0
        let value = preview()
        let renderer = RichPreviewRenderer(render: { _ in
            calls += 1
            if calls == 1 { throw RichPreviewWebRenderer.Failure.unavailable }
            return value
        }, reset: { resets += 1 })
        defer { renderer.cancel() }
        let item = try #require(RichMarkdown.scan("$$x^2$$").first)
        var done = false
        _ = renderer.preview(for: item, width: 400, dark: false) { done = true }
        try await waitUntil { done }
        #expect(calls == 2)
        #expect(resets == 1)
        #expect(renderer.preview(for: item, width: 400, dark: false, completion: {})?.image === value.image)
    }

    @Test func invalidSourceIsNotRetriedInALoop() async throws {
        var calls = 0
        let renderer = RichPreviewRenderer(render: { _ in calls += 1; throw RichPreviewWebRenderer.Failure.invalidSource })
        defer { renderer.cancel() }
        let item = try #require(RichMarkdown.scan("$$bad$$").first)
        var done = false
        _ = renderer.preview(for: item, width: 400, dark: false) { done = true }
        try await waitUntil { done }
        for _ in 0..<10 { _ = renderer.preview(for: item, width: 400, dark: false, completion: {}) }
        #expect(calls == 1)
    }

    @Test func resizingPreservesTheMeasuredTextBaseline() {
        let value = RichPreviewRenderer.Preview(image: preview().image, size: CGSize(width: 8, height: 8), baseline: 5)
        let fitted = value.fitting(width: 4)
        #expect(fitted.size == CGSize(width: 4, height: 4))
        #expect(fitted.baseline == 2.5)
        #expect(fitted.memoryCost == value.memoryCost)
    }

    @Test func cacheCountsReplacementsOnceAndEvictsLeastRecentlyUsed() {
        let value = preview()
        let cache = RichPreviewCache(byteLimit: value.memoryCost * 2)
        func key(_ source: String) -> RichPreviewRenderer.Key {
            .init(source: source, kind: "displayMath", width: 400, fontSize: 18, dark: false)
        }
        cache.insert(value, for: key("a"))
        cache.insert(value, for: key("a"))
        #expect(cache.byteCount == value.memoryCost)
        cache.insert(value, for: key("b"))
        _ = cache.value(for: key("a"))
        cache.insert(value, for: key("c"))
        #expect(cache.value(for: key("a")) != nil)
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.value(for: key("c")) != nil)
        #expect(cache.byteCount == value.memoryCost * 2)
    }
}
