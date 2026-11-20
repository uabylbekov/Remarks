import SwiftUI
import NotesCore

// MARK: - Layout fragments

/// Draws the rounded background behind code block lines.
///
/// Where a line sits in its block (first row, last row) is asked of the controller at draw time instead of being stored
/// in the text, so it can never go stale when lines are added or removed, and it never affects layout.
final class CodeBlockFragment: NSTextLayoutFragment {
    private static let cornerRadius: CGFloat = 10
    /// Neighboring lines overlap by this much, so no hairline seam shows between them at fractional pixel positions.
    private static let overlap: CGFloat = 0.75

    weak var controller: LivePreviewController?

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The card's top and bottom edges for this line, relative to the top of the fragment.
    private func verticalExtent(of row: LivePreviewController.BlockRow) -> (top: CGFloat, bottom: CGFloat) {
        let top = row.isFirst ? LivePreviewController.cardMargin : 0
        guard row.isLast else { return (top, layoutFragmentFrame.height) }

        // The text engine lays the empty line after a trailing newline out inside this fragment. It belongs to the
        // card only when the block is still open, because that is the next line of code. After a closing fence it is
        // an ordinary line below the card.
        let lines = textLineFragments
        let realLines = lines.filter { $0.characterRange.length > 0 }
        let reference = (row.isUnclosed ? lines.last : realLines.last)
        let lastBottom = reference.map { $0.typographicBounds.maxY } ?? layoutFragmentFrame.height
        return (top, lastBottom + LivePreviewController.cardPadding)
    }

    // The background is wider than the text and can extend past it, so the rendering surface must include it.
    override var renderingSurfaceBounds: CGRect {
        let row = controller?.blockRow(for: textElement) ?? .init(isFirst: true, isLast: true, isUnclosed: false)
        let extent = verticalExtent(of: row)
        // The fragment's frame starts at the text's indent, but the background starts at the container edge.
        return super.renderingSurfaceBounds.union(
            CGRect(
                x: -layoutFragmentFrame.minX,
                y: min(0, extent.top) - Self.overlap,
                width: containerWidth,
                height: max(layoutFragmentFrame.height, extent.bottom) + 2 * Self.overlap
            )
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let row = controller?.blockRow(for: textElement) ?? .init(isFirst: true, isLast: true, isUnclosed: false)
        let extent = verticalExtent(of: row)
        let top = row.isFirst ? Self.cornerRadius : 0
        let bottom = row.isLast ? Self.cornerRadius : 0
        // Square edges that meet another line reach a little into it.
        let extendUp = top > 0 ? 0 : Self.overlap
        let extendDown = bottom > 0 ? 0 : Self.overlap
        let rect = CGRect(
            x: point.x - layoutFragmentFrame.minX,
            y: point.y + extent.top - extendUp,
            width: containerWidth,
            height: extent.bottom - extent.top + extendUp + extendDown
        )

        context.saveGState()
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(Self.path(for: rect, topRadius: top, bottomRadius: bottom))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// A rectangle with independent top and bottom corner radii. Y grows downward in both UIKit and AppKit text views.
    static func path(for rect: CGRect, topRadius top: CGFloat, bottomRadius bottom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        }
        path.closeSubpath()
        return path
    }
}

/// Draws the rounded card behind a table row. Whether the row is the first or last of its table is asked of the
/// controller at draw time, like `CodeBlockFragment`, so it can never go stale.
final class TableFragment: NSTextLayoutFragment {
    weak var controller: LivePreviewController?

    private static let cornerRadius: CGFloat = 10
    private static let overlap: CGFloat = 0.75

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The card's bottom edge. The empty line after a trailing newline belongs below the table, not inside it.
    private var bottomEdge: CGFloat {
        let real = textLineFragments.filter { $0.characterRange.length > 0 }
        return (real.last?.typographicBounds.maxY ?? layoutFragmentFrame.height) + LivePreviewController.tableRowPadding + 2
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: -Self.overlap, width: containerWidth, height: max(layoutFragmentFrame.height, bottomEdge) + 2 * Self.overlap)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let row = controller?.tableRow(for: textElement) ?? (isFirst: true, isLast: true)
        let top = row.isFirst ? Self.cornerRadius : 0
        let bottom = row.isLast ? Self.cornerRadius : 0
        let extendUp = row.isFirst ? 0 : Self.overlap
        let extendDown = row.isLast ? 0 : Self.overlap
        let height = row.isLast ? bottomEdge : layoutFragmentFrame.height
        let rect = CGRect(
            x: point.x - layoutFragmentFrame.minX,
            y: point.y - extendUp,
            width: containerWidth,
            height: height + extendUp + extendDown
        )

        context.saveGState()
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(CodeBlockFragment.path(for: rect, topRadius: top, bottomRadius: bottom))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// Draws a checkbox in the space of a checklist item's hidden `- [ ] ` mark.
final class ChecklistFragment: NSTextLayoutFragment {
    private func number(for key: NSAttributedString.Key) -> CGFloat {
        let value = (textElement as? NSTextParagraph)?.attributedString.attribute(key, at: 0, effectiveRange: nil) as? NSNumber
        return CGFloat(value?.doubleValue ?? 0)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)

        let isChecked = number(for: LivePreviewController.checklistKey) == 2
        let hiddenWidth = number(for: LivePreviewController.checklistWidthKey)
        let indent = number(for: LivePreviewController.checklistIndentKey)
        let lineHeight = textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5

        // Leave a visible gap between the box and the text that follows.
        let side = max(10, min(lineHeight * 0.62, hiddenWidth - 6))
        let box = CGRect(
            x: point.x - layoutFragmentFrame.minX + padding + indent,
            y: point.y + (lineHeight - side) / 2,
            width: side,
            height: side
        )

        context.saveGState()
        let outline = CGPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        if isChecked {
            context.setFillColor(EditorTheme.accentColor.cgColor)
            context.addPath(outline)
            context.fillPath()
            context.setStrokeColor(EditorColor.white.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + side * 0.25, y: box.minY + side * 0.53))
            context.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.71))
            context.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.30))
            context.strokePath()
        } else {
            context.setStrokeColor(EditorColor.systemGray.cgColor)
            context.setLineWidth(1.5)
            context.addPath(outline)
            context.strokePath()
        }
        context.restoreGState()
    }
}

// MARK: - Live preview

#if canImport(UIKit)
typealias StorageEditActions = NSTextStorage.EditActions
#else
typealias StorageEditActions = NSTextStorageEditActions
#endif

/// Live preview for a TextKit 2 text view.
/// All styling happens in the content storage delegate, so the stored Markdown text is never modified:
/// selection, copy, undo, and sync always see the real characters.
@MainActor
final class LivePreviewController: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate, NSTextStorageDelegate {
    /// Marks a paragraph as part of a code block, so the layout manager gives it a `CodeBlockFragment`.
    static let blockMarkerKey = NSAttributedString.Key("notes.codeBlock")
    static let checklistKey = NSAttributedString.Key("notes.checklist")          // 1 unchecked, 2 checked
    static let checklistWidthKey = NSAttributedString.Key("notes.checklistWidth")
    static let checklistIndentKey = NSAttributedString.Key("notes.checklistIndent")
    /// Space above and below the text of every table row, inside the card.
    static let tableRowPadding: CGFloat = 4
    static let tableKey = NSAttributedString.Key("notes.table")
    /// On the line of an attachment: the attachment id (a string) and the height reserved for it.
    static let attachmentKey = NSAttributedString.Key("notes.attachment")
    static let attachmentHeightKey = NSAttributedString.Key("notes.attachmentHeight")

    private static let headingRegex = try? NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    private static let checklistRegex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+][ \t]+\[([ xX]?)\](?:[ \t]+|$))"#)
    static let codeInset: CGFloat = 12
    /// Space inside the card above the opening fence row and below the closing fence row.
    static let cardPadding: CGFloat = 4
    /// Space outside the card, above and below it. Always the same, whatever the neighboring lines hold, so typing
    /// next to a block never moves anything.
    static let cardMargin: CGFloat = 6
    /// Space between the opening fence row (which shows the language when idle) and the first line of code.
    static let fenceGap: CGFloat = 6
    /// Blocks longer than this are shown without syntax colors, so typing in a huge block stays smooth.
    private static let highlightLimit = 60_000

    /// Where one line sits in its block. Asked at draw time (see `CodeBlockFragment`).
    struct BlockRow {
        let isFirst: Bool
        let isLast: Bool
        let isUnclosed: Bool
    }

    /// Where the editor gets the picture or file details for an `attachment://` line.
    var attachmentProvider: ((UUID) -> AttachmentDisplay?)?

    private weak var contentStorage: NSTextContentStorage?
    private weak var layoutManager: NSTextLayoutManager?
    private(set) var blocks: [CodeBlock] = []
    private var caret = 0
    /// Increases with every change to the text. Tokens are cached against it.
    private var version = 0
    private var tokenCache: [Int: [SyntaxToken]] = [:]

    init(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        self.contentStorage = contentStorage
        self.layoutManager = layoutManager
        super.init()
        contentStorage.delegate = self
        layoutManager.delegate = self
        blocks = CodeBlockScanner.scan(contentStorage.textStorage?.string ?? "")

        // Refresh the block list as the text changes, before the text engine lays the edited lines out. Doing it any
        // later styles them from a stale list, and then every line has to be styled again.
        contentStorage.textStorage?.delegate = self
    }

    // MARK: Updates from the text view

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: StorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let storage = textStorage
        version &+= 1
        tokenCache.removeAll()

        let updated = CodeBlockScanner.scan(storage.string)
        let changeStart = Self.firstStructuralChange(from: blocks, to: updated)
        blocks = updated

        // Typing inside a block, or anywhere else, only restyles the lines the text engine already refreshes. Only when
        // a fence appears or disappears do the lines after it change what they are.
        guard let changeStart else { return }
        Task { @MainActor [weak self] in
            guard let self, let length = self.contentStorage?.textStorage?.length, changeStart < length else { return }
            self.invalidate([NSRange(location: changeStart, length: length - changeStart)])
        }
    }

    /// Where the first block that is new, gone, or different (another language, opened or closed) begins.
    private static func firstStructuralChange(from old: [CodeBlock], to new: [CodeBlock]) -> Int? {
        for (before, after) in zip(old, new)
        where before.language != after.language || (before.close == nil) != (after.close == nil) {
            return min(before.open.location, after.open.location)
        }
        if old.count > new.count { return old[new.count].open.location }
        if new.count > old.count { return new[old.count].open.location }
        return nil
    }

    /// Call after text is replaced programmatically (a different note, or a sync update), or when settings change.
    func reload() {
        guard let storage = contentStorage?.textStorage else { return }
        version &+= 1
        tokenCache.removeAll()
        blocks = CodeBlockScanner.scan(storage.string)
        caret = min(caret, storage.length)
        invalidate([NSRange(location: 0, length: storage.length)])
    }

    func selectionChanged(to location: Int) {
        guard let storage = contentStorage?.textStorage else { return }
        let previous = caret
        caret = min(location, storage.length)
        guard previous != caret else { return }

        let oldLine = lineRange(at: previous, in: storage)
        let newLine = lineRange(at: caret, in: storage)
        let oldBlock = activeBlock(at: previous, in: storage)
        let newBlock = activeBlock(at: caret, in: storage)
        // Moving along the same line of the same block changes nothing that is shown.
        if oldLine == newLine && oldBlock == newBlock { return }

        var ranges = [oldLine, newLine]
        if oldBlock != newBlock {
            ranges += [oldBlock, newBlock].compactMap { $0?.whole }
        }
        invalidate(ranges)
    }

    /// True when `location` is inside a fenced block. Return and list continuation must leave code alone.
    func isInCodeBlock(_ location: Int) -> Bool {
        guard let storage = contentStorage?.textStorage else { return false }
        return activeBlock(at: location, in: storage) != nil
    }

    private func lineRange(at location: Int, in storage: NSTextStorage) -> NSRange {
        let source = storage.string as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        return source.lineRange(for: NSRange(location: min(location, source.length - 1), length: 0))
    }

    /// Re-runs the paragraph delegate for these ranges without changing any characters.
    private func invalidate(_ ranges: [NSRange]) {
        guard let contentStorage, let storage = contentStorage.textStorage else { return }
        contentStorage.performEditingTransaction {
            for range in ranges where range.length > 0 && NSMaxRange(range) <= storage.length {
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
    }

    // MARK: Active region

    /// The block the caret is in, if any. A caret on the empty line after a closed block's last newline is below the
    /// block. After an open block's newline it is on the block's next line of code.
    private func activeBlock(at location: Int, in storage: NSTextStorage) -> CodeBlock? {
        let length = storage.length
        let text = storage.string as NSString
        return blocks.first { block in
            let end = NSMaxRange(block.whole)
            if location >= block.whole.location && location < end { return true }
            guard location == end, end == length else { return false }
            return block.close == nil || text.character(at: length - 1) != 10
        }
    }

    /// The caret is on this line. A caret at the very end of the text belongs to the last line, but not when that line
    /// ends with a newline: then the caret is on the empty line after it.
    private func isLineActive(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        let lineEnd = NSMaxRange(range)
        guard caret >= range.location else { return false }
        if caret < lineEnd { return true }
        guard caret == lineEnd, lineEnd == storage.length, lineEnd > 0 else { return false }
        return (storage.string as NSString).character(at: lineEnd - 1) != 10
    }

    /// Where the line that starts a layout element sits in its block, or nil if it is not in a block.
    func blockRow(for element: NSTextElement?) -> BlockRow? {
        guard let location = element?.elementRange?.location, let contentStorage,
              let storage = contentStorage.textStorage else { return nil }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard let block = blocks.first(where: { NSLocationInRange(offset, $0.whole) }) else { return nil }

        let lastLine: Int
        if let close = block.close {
            lastLine = close.location
        } else if block.body.length > 0 {
            lastLine = (storage.string as NSString).lineRange(for: NSRange(location: NSMaxRange(block.body) - 1, length: 0)).location
        } else {
            lastLine = block.open.location
        }
        return BlockRow(isFirst: offset == block.open.location, isLast: offset == lastLine, isUnclosed: block.close == nil)
    }

    // MARK: NSTextContentStorageDelegate

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, range.length > 0 else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let full = NSRange(location: 0, length: paragraph.length)

        if let block = blocks.first(where: { NSLocationInRange(range.location, $0.whole) }) {
            styleCodeParagraph(paragraph, range: range, block: block, storage: storage)
            return NSTextParagraph(attributedString: paragraph)
        }

        let isActive = isLineActive(range, in: storage)

        if MarkdownEditing.isTableRow(paragraph.string) {
            styleTableRow(paragraph, range: range, storage: storage)
            return NSTextParagraph(attributedString: paragraph)
        }

        if let line = AttachmentLine.parse(paragraph.string) {
            styleAttachment(paragraph, line: line, isActive: isActive)
            return NSTextParagraph(attributedString: paragraph)
        }

        var changed = false

        if let match = Self.headingRegex?.firstMatch(in: paragraph.string, range: full) {
            paragraph.addAttribute(.font, value: EditorTheme.headingFont(level: match.range(at: 1).length), range: full)
            if !isActive { collapse(paragraph, range: match.range) }
            changed = true
        }

        if let match = Self.checklistRegex?.firstMatch(in: paragraph.string, range: full) {
            styleChecklist(paragraph, match: match, isActive: isActive)
            changed = true
        }

        if styleInline(paragraph, hideMarkers: !isActive) { changed = true }

        return changed ? NSTextParagraph(attributedString: paragraph) : nil
    }

    // MARK: Code blocks

    /// Layout depends only on what a line is (an opening fence, a closing fence, or code), never on where the caret is,
    /// what the neighboring lines hold, or whether it is the last line. Those change while typing, and anything that
    /// depended on them would move the text under the caret. Caret position changes colors only.
    private func styleCodeParagraph(_ paragraph: NSMutableAttributedString, range: NSRange, block: CodeBlock, storage: NSTextStorage) {
        let full = NSRange(location: 0, length: paragraph.length)
        let isOpen = range.location == block.open.location
        let isClose = block.close.map { range.location == $0.location } ?? false
        let isFence = isOpen || isClose
        let isActive = activeBlock(at: caret, in: storage) == block

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = Self.codeInset
        style.headIndent = Self.codeInset
        style.tailIndent = -Self.codeInset
        style.paragraphSpacingBefore = isOpen ? Self.cardMargin + Self.cardPadding : 0
        style.paragraphSpacing = isOpen ? Self.fenceGap : (isClose ? Self.cardPadding + Self.cardMargin : 0)

        paragraph.addAttribute(.font, value: EditorTheme.codeFont, range: full)
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        paragraph.addAttribute(Self.blockMarkerKey, value: 1, range: full)

        if isFence {
            // The same small text in both states. While idle, the backticks are invisible but still take their
            // room, so the language stays exactly where it is and only the backticks appear when editing.
            let small = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
            if !isActive {
                let text = paragraph.string as NSString
                var markerEnd = 0
                while markerEnd < text.length, [32, 9, 96, 126].contains(text.character(at: markerEnd)) { markerEnd += 1 }
                // An opening fence keeps its language visible. A closing fence is hidden entirely.
                let hidden = isOpen && !block.language.isEmpty ? NSRange(location: 0, length: markerEnd) : full
                paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: hidden)
            }
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: full)
            applySyntaxColors(to: paragraph, range: range, block: block, storage: storage)
        }
    }

    /// Colors come from the display layer, so the stored text is never touched and typing never triggers a rewrite.
    private func applySyntaxColors(to paragraph: NSMutableAttributedString, range: NSRange, block: CodeBlock, storage: NSTextStorage) {
        let tokens = syntaxTokens(for: block, in: storage)
        // Tokens are sorted by position, so find the first one that can reach this line and stop at the first past it.
        var low = 0, high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(tokens[middle].range) > range.location { high = middle } else { low = middle + 1 }
        }
        for token in tokens[low...] {
            if token.range.location >= NSMaxRange(range) { break }
            let overlap = NSIntersectionRange(token.range, range)
            guard overlap.length > 0 else { continue }
            paragraph.addAttribute(
                .foregroundColor,
                value: EditorTheme.color(for: token.scope),
                range: NSRange(location: overlap.location - range.location, length: overlap.length)
            )
        }
    }

    private func syntaxTokens(for block: CodeBlock, in storage: NSTextStorage) -> [SyntaxToken] {
        if let cached = tokenCache[block.open.location] { return cached }
        var tokens: [SyntaxToken] = []
        if block.body.length > 0, block.body.length <= Self.highlightLimit,
           let engine = SyntaxGrammars.engine(forLanguage: block.language) {
            tokens = engine.tokens(in: storage.string, range: block.body).sorted { $0.range.location < $1.range.location }
        }
        tokenCache[block.open.location] = tokens
        return tokens
    }

    // MARK: Tables

    /// A table row is shown in the code font, so the columns line up, on the card color. The header row (the one
    /// above the separator) is bold, and the separator row and the pipes are dim. Nothing here depends on the caret.
    private func styleTableRow(_ paragraph: NSMutableAttributedString, range: NSRange, storage: NSTextStorage) {
        let text = paragraph.string
        let content = NSRange(location: 0, length: (text as NSString).length - (text.hasSuffix("\n") ? 1 : 0))
        guard content.length > 0 else { return }

        let isSeparator = MarkdownEditing.isTableSeparator(text)
        let isHeader = !isSeparator && nextLineIsTableSeparator(after: range, in: storage)
        let font = isHeader ? EditorTheme.traited(EditorTheme.codeFont, bold: true) : EditorTheme.codeFont

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = Self.codeInset
        style.headIndent = Self.codeInset
        style.tailIndent = -Self.codeInset
        style.paragraphSpacingBefore = Self.tableRowPadding
        style.paragraphSpacing = Self.tableRowPadding
        style.lineBreakMode = .byClipping
        paragraph.addAttributes([
            .font: font,
            .foregroundColor: isSeparator ? EditorTheme.dimColor : EditorTheme.codeTextColor,
            .paragraphStyle: style,
            Self.tableKey: 1,
        ], range: NSRange(location: 0, length: paragraph.length))

        // The pipes recede, so the cells read first.
        let source = text as NSString
        for index in 0..<content.length where source.character(at: index) == 124 {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: NSRange(location: index, length: 1))
        }
    }

    /// Where the table row that starts a layout element sits in its table, or nil if it is not in one.
    func tableRow(for element: NSTextElement?) -> (isFirst: Bool, isLast: Bool)? {
        guard let location = element?.elementRange?.location, let contentStorage,
              let storage = contentStorage.textStorage else { return nil }
        let source = storage.string as NSString
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard offset < source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: offset, length: 0))
        guard MarkdownEditing.isTableRow(source.substring(with: line)) else { return nil }

        var isFirst = true
        if line.location > 0 {
            let previous = source.lineRange(for: NSRange(location: line.location - 1, length: 0))
            isFirst = !MarkdownEditing.isTableRow(source.substring(with: previous))
        }
        var isLast = true
        if NSMaxRange(line) < source.length {
            let next = source.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            isLast = !MarkdownEditing.isTableRow(source.substring(with: next))
        }
        return (isFirst, isLast)
    }

    private func nextLineIsTableSeparator(after range: NSRange, in storage: NSTextStorage) -> Bool {
        let source = storage.string as NSString
        let next = NSMaxRange(range)
        guard next < source.length else { return false }
        return MarkdownEditing.isTableSeparator(source.substring(with: source.lineRange(for: NSRange(location: next, length: 0))))
    }

    // MARK: Attachments

    /// The tallest a picture is drawn, in points.
    private static let maxImageHeight: CGFloat = 280

    func attachmentDisplay(for id: UUID) -> AttachmentDisplay? {
        attachmentProvider?(id)
    }

    /// An attachment line keeps its Markdown but reserves room for the picture or chip, which the layout fragment
    /// draws (see `AttachmentFragment`). The height depends only on the attachment, never on the caret, so moving
    /// through the line shifts nothing. The Markdown itself shows only while the caret is on the line.
    private func styleAttachment(_ paragraph: NSMutableAttributedString, line: AttachmentLine, isActive: Bool) {
        let full = NSRange(location: 0, length: paragraph.length)
        let display = attachmentProvider?(line.id)

        var height = AttachmentFragment.chipHeight
        if line.isImage, let display, display.isImage, display.pixelSize.height > 0 {
            // Pixels are shown at half size, which is how a Retina screen shows them, up to a maximum height.
            height = min(Self.maxImageHeight, max(AttachmentFragment.chipHeight, display.pixelSize.height / 2))
        } else if line.isImage {
            height = 120
        }

        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height + 8
        style.maximumLineHeight = height + 8
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        // One line only, so a long link never makes the line taller.
        style.lineBreakMode = .byClipping
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        paragraph.addAttribute(Self.attachmentKey, value: line.id.uuidString, range: full)
        paragraph.addAttribute(Self.attachmentHeightKey, value: Double(height), range: full)

        if isActive {
            paragraph.addAttributes([.foregroundColor: EditorTheme.dimColor, .backgroundColor: EditorTheme.codeBackground], range: full)
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: full)
        }
    }

    /// The attachment whose picture or chip is under `point` (text container coordinates).
    func attachmentID(at point: CGPoint) -> UUID? {
        guard let layoutManager,
              let fragment = layoutManager.textLayoutFragment(for: point),
              let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let value = paragraph.attributedString.attribute(Self.attachmentKey, at: 0, effectiveRange: nil) as? String
        else { return nil }
        return UUID(uuidString: value)
    }

    /// Draws the lines again, for when pictures arrive by sync or an attachment is added.
    func refreshAttachments() {
        reload()
    }

    // MARK: Checklists

    private func styleChecklist(_ paragraph: NSMutableAttributedString, match: NSTextCheckingResult, isActive: Bool) {
        let source = paragraph.string as NSString
        let full = NSRange(location: 0, length: paragraph.length)
        let markRange = match.range(at: 2)
        let state = source.substring(with: match.range(at: 3))
        let isChecked = state == "x" || state == "X"

        if isActive {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: markRange)
            return
        }

        // Keep the mark's room but shrink and hide it, then draw a box there (see `ChecklistFragment`).
        let base = (paragraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
        let small = EditorFont.systemFont(ofSize: base.pointSize * 0.7)
        paragraph.addAttributes([.font: small, .foregroundColor: EditorColor.clear], range: markRange)

        let hiddenWidth = NSAttributedString(string: source.substring(with: markRange), attributes: [.font: small]).size().width
        let indentWidth = NSAttributedString(string: source.substring(with: match.range(at: 1)), attributes: [.font: base]).size().width
        paragraph.addAttribute(Self.checklistKey, value: isChecked ? 2 : 1, range: full)
        paragraph.addAttribute(Self.checklistWidthKey, value: Double(hiddenWidth), range: full)
        paragraph.addAttribute(Self.checklistIndentKey, value: Double(indentWidth), range: full)

        if isChecked {
            let content = NSRange(location: NSMaxRange(markRange), length: max(0, full.length - NSMaxRange(markRange)))
            paragraph.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: content)
        }
    }

    /// Finds the checklist line whose box is under `point` (text container coordinates).
    /// Returns a location inside that line, or nil if the point is not on a checkbox.
    func checklistLine(at point: CGPoint) -> Int? {
        guard let layoutManager, let contentStorage,
              let fragment = layoutManager.textLayoutFragment(for: point),
              let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              paragraph.attributedString.attribute(Self.checklistKey, at: 0, effectiveRange: nil) != nil,
              let hiddenWidth = (paragraph.attributedString.attribute(Self.checklistWidthKey, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue,
              let indent = (paragraph.attributedString.attribute(Self.checklistIndentKey, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue,
              let start = fragment.textElement?.elementRange?.location
        else { return nil }

        let padding = layoutManager.textContainer?.lineFragmentPadding ?? 5
        let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? 20
        let frame = fragment.layoutFragmentFrame
        // A forgiving target: the box plus a little around it, on the first line only.
        let target = CGRect(x: frame.minX + padding + indent - 6, y: frame.minY, width: hiddenWidth + 12, height: lineHeight)
        guard target.contains(point) else { return nil }
        return contentStorage.offset(from: contentStorage.documentRange.location, to: start)
    }

    // MARK: Inline styles

    /// Styles bold, italic, strikethrough, code, and links, and hides their marks unless the line is being edited.
    /// - Returns: whether anything was styled.
    private func styleInline(_ paragraph: NSMutableAttributedString, hideMarkers: Bool) -> Bool {
        let spans = InlineScanner.spans(in: paragraph.string)
        for span in spans {
            let base = (paragraph.attribute(.font, at: span.content.location, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
            switch span.kind {
            case .bold:
                paragraph.addAttribute(.font, value: EditorTheme.traited(base, bold: true), range: span.content)
            case .italic:
                paragraph.addAttribute(.font, value: EditorTheme.traited(base, italic: true), range: span.content)
            case .strikethrough:
                paragraph.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            case .code:
                paragraph.addAttributes([
                    .font: EditorTheme.inlineCodeFont(matching: base),
                    .backgroundColor: EditorTheme.codeBackground,
                ], range: span.content)
            case .link:
                paragraph.addAttributes([
                    .foregroundColor: EditorTheme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: span.content)
            }
            for marker in span.markers {
                if hideMarkers {
                    collapse(paragraph, range: marker)
                } else {
                    paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: marker)
                }
            }
        }
        return !spans.isEmpty
    }

    /// Hides text by making it transparent and nearly zero-sized. The character count is unchanged, so
    /// selection, copy, and undo still operate on the real Markdown.
    private func collapse(_ text: NSMutableAttributedString, range: NSRange) {
        // A near-zero font size leaves no visible gap where the marks were.
        text.addAttribute(.font, value: EditorFont.systemFont(ofSize: 0.01), range: range)
        text.addAttribute(.foregroundColor, value: EditorColor.clear, range: range)
        if range.length == text.length {
            // A whole hidden line must not take vertical space either.
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = 0.01
            style.maximumLineHeight = 0.01
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    // MARK: NSTextLayoutManagerDelegate

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            if paragraph.attributedString.attribute(Self.blockMarkerKey, at: 0, effectiveRange: nil) != nil {
                let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
                fragment.controller = self
                return fragment
            }
            if paragraph.attributedString.attribute(Self.tableKey, at: 0, effectiveRange: nil) != nil {
                let fragment = TableFragment(textElement: textElement, range: textElement.elementRange)
                fragment.controller = self
                return fragment
            }
            if paragraph.attributedString.attribute(Self.attachmentKey, at: 0, effectiveRange: nil) != nil {
                let fragment = AttachmentFragment(textElement: textElement, range: textElement.elementRange)
                fragment.controller = self
                return fragment
            }
            if paragraph.attributedString.attribute(Self.checklistKey, at: 0, effectiveRange: nil) != nil {
                return ChecklistFragment(textElement: textElement, range: textElement.elementRange)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
