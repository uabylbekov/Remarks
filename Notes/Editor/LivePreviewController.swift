import SwiftUI
import NotesCore

// MARK: - Layout fragments

/// Where a code line sits inside its block, used to round only the outer corners.
enum CodeBlockPosition: Int {
    case middle = 0, first = 1, last = 2, only = 3
}

/// Draws the rounded background behind code block lines.
final class CodeBlockFragment: NSTextLayoutFragment {
    private static let cornerRadius: CGFloat = 10

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    private var position: CodeBlockPosition {
        let value = (textElement as? NSTextParagraph)?
            .attributedString.attribute(LivePreviewController.blockPositionKey, at: 0, effectiveRange: nil) as? Int
        return value.flatMap(CodeBlockPosition.init(rawValue:)) ?? .middle
    }

    // The background is wider than the text, so the rendering surface must include it or it is clipped.
    override var renderingSurfaceBounds: CGRect {
        // The fragment's frame starts at the text's indent, but the background starts at the container edge.
        super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = CGRect(x: point.x - layoutFragmentFrame.minX, y: point.y, width: containerWidth, height: layoutFragmentFrame.height)
        let top = (position == .first || position == .only) ? Self.cornerRadius : 0
        let bottom = (position == .last || position == .only) ? Self.cornerRadius : 0

        context.saveGState()
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(Self.path(for: rect, topRadius: top, bottomRadius: bottom))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
        drawLanguageLabel(at: point, in: context)
    }

    /// The language name in the block's header, drawn on the first line only (see `LivePreviewController`).
    private func drawLanguageLabel(at point: CGPoint, in context: CGContext) {
        guard let language = (textElement as? NSTextParagraph)?
            .attributedString.attribute(LivePreviewController.languageKey, at: 0, effectiveRange: nil) as? String,
              !language.isEmpty else { return }
        let label = NSAttributedString(string: language, attributes: [
            .font: EditorFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: EditorTheme.dimColor,
        ])
        // Line up with the code below: the block's inset plus the text container's own side padding.
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let origin = CGPoint(x: point.x - layoutFragmentFrame.minX + LivePreviewController.codeInset + padding, y: point.y + 8)
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        label.draw(at: origin)
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        label.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }

    /// A rectangle with independent top and bottom corner radii. Y grows downward in both UIKit and AppKit text views.
    private static func path(for rect: CGRect, topRadius top: CGFloat, bottomRadius bottom: CGFloat) -> CGPath {
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

/// Live preview for a TextKit 2 text view.
/// All styling happens in the content storage delegate, so the stored Markdown text is never modified:
/// selection, copy, undo, and sync always see the real characters.
@MainActor
final class LivePreviewController: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    static let blockPositionKey = NSAttributedString.Key("notes.blockPosition")
    static let checklistKey = NSAttributedString.Key("notes.checklist")          // 1 unchecked, 2 checked
    static let checklistWidthKey = NSAttributedString.Key("notes.checklistWidth")
    static let checklistIndentKey = NSAttributedString.Key("notes.checklistIndent")
    static let languageKey = NSAttributedString.Key("notes.codeLanguage")

    private static let headingRegex = try? NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    private static let checklistRegex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+][ \t]+\[([ xX]?)\](?:[ \t]+|$))"#)
    static let codeInset: CGFloat = 12
    private static let codePadding: CGFloat = 10
    /// Extra room above the first line for the language label.
    private static let headerHeight: CGFloat = 16

    private weak var contentStorage: NSTextContentStorage?
    private weak var layoutManager: NSTextLayoutManager?
    private(set) var blocks: [CodeBlock] = []
    private var caret = 0

    init(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        self.contentStorage = contentStorage
        self.layoutManager = layoutManager
        super.init()
        contentStorage.delegate = self
        layoutManager.delegate = self
        blocks = CodeBlockScanner.scan(contentStorage.textStorage?.string ?? "")
    }

    // MARK: Updates from the text view

    /// Call after the user edits text.
    func textChanged() {
        guard let storage = contentStorage?.textStorage else { return }
        let updated = CodeBlockScanner.scan(storage.string)
        guard updated != blocks else { return }
        blocks = updated
        invalidate([NSRange(location: 0, length: storage.length)])
    }

    /// Call after text is replaced programmatically (a different note, or a sync update).
    func reload() {
        guard let storage = contentStorage?.textStorage else { return }
        blocks = CodeBlockScanner.scan(storage.string)
        caret = min(caret, storage.length)
        invalidate([NSRange(location: 0, length: storage.length)])
    }

    func selectionChanged(to location: Int) {
        guard let storage = contentStorage?.textStorage else { return }
        let previous = caret
        caret = min(location, storage.length)
        guard previous != caret else { return }

        var ranges = [lineRange(at: previous, in: storage), lineRange(at: caret, in: storage)]
        let oldBlock = activeBlock(at: previous, length: storage.length)
        let newBlock = activeBlock(at: caret, length: storage.length)
        if oldBlock != newBlock {
            ranges += [oldBlock, newBlock].compactMap { $0?.whole }
        }
        invalidate(ranges)
    }

    /// True when `location` is inside a fenced block. Return and list continuation must leave code alone.
    func isInCodeBlock(_ location: Int) -> Bool {
        blocks.contains { NSLocationInRange(location, $0.whole) || ($0.close == nil && location == NSMaxRange($0.whole)) }
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

    private func activeBlock(at location: Int, length: Int) -> CodeBlock? {
        blocks.first { block in
            let end = NSMaxRange(block.whole)
            return location >= block.whole.location && (location < end || (location == end && end == length))
        }
    }

    /// The caret is on this line. A caret at the very end of the text belongs to the last line only.
    private func isLineActive(_ range: NSRange, storageLength: Int) -> Bool {
        let lineEnd = NSMaxRange(range)
        return caret >= range.location && (caret < lineEnd || (caret == lineEnd && lineEnd == storageLength))
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

        let isActive = isLineActive(range, storageLength: storage.length)
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

    private func styleCodeParagraph(_ paragraph: NSMutableAttributedString, range: NSRange, block: CodeBlock, storage: NSTextStorage) {
        let full = NSRange(location: 0, length: paragraph.length)
        let isFence = range.location == block.open.location || range.location == block.close?.location
        let isActive = activeBlock(at: caret, length: storage.length) == block

        if isFence && !isActive {
            collapse(paragraph, range: full)
            return
        }

        // Which visible line is first and last decides the rounded corners and the padding.
        let source = storage.string as NSString
        let body = block.body
        let firstBody: Int? = body.length > 0 ? body.location : nil
        let lastBody: Int? = body.length > 0 ? source.lineRange(for: NSRange(location: NSMaxRange(body) - 1, length: 0)).location : nil
        let firstVisible = isActive ? block.open.location : firstBody
        let lastVisible = isActive ? (block.close?.location ?? lastBody ?? block.open.location) : lastBody
        let isFirst = range.location == firstVisible
        let isLast = range.location == lastVisible
        let position: CodeBlockPosition = switch (isFirst, isLast) {
        case (true, true): .only
        case (true, false): .first
        case (false, true): .last
        case (false, false): .middle
        }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = Self.codeInset
        style.headIndent = Self.codeInset
        style.tailIndent = -Self.codeInset
        // While the block is not being edited, its fences are hidden and a small language label heads the card.
        let showsLabel = isFirst && !isActive && !block.language.isEmpty
        style.paragraphSpacingBefore = isFirst ? Self.codePadding + (showsLabel ? Self.headerHeight : 0) : 0
        style.paragraphSpacing = isLast ? Self.codePadding : 0

        paragraph.addAttribute(.font, value: EditorTheme.codeFont, range: full)
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        paragraph.addAttribute(Self.blockPositionKey, value: position.rawValue, range: full)
        if showsLabel { paragraph.addAttribute(Self.languageKey, value: block.language, range: full) }
        if isFence {
            // Visible fences (while editing) are small and quiet, so they read as part of the card's frame.
            let small = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
        }
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
            if paragraph.attributedString.attribute(Self.blockPositionKey, at: 0, effectiveRange: nil) != nil {
                return CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
            }
            if paragraph.attributedString.attribute(Self.checklistKey, at: 0, effectiveRange: nil) != nil {
                return ChecklistFragment(textElement: textElement, range: textElement.elementRange)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// Colors fenced code by the language on each fence line. Debounced so typing is never interrupted.
@MainActor
final class SyntaxHighlighter {
    private let storage: NSTextStorage
    private var task: Task<Void, Never>?

    init(storage: NSTextStorage) {
        self.storage = storage
    }

    func schedule() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    func apply() {
        task?.cancel()
        let plain = storage.string
        let full = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorTheme.baseColor, range: full)
        for block in CodeBlockScanner.scan(plain) where block.body.length > 0 {
            storage.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: block.body)
            guard let engine = SyntaxGrammars.engine(forLanguage: block.language) else { continue }
            for token in engine.tokens(in: plain, range: block.body) {
                storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.scope), range: token.range)
            }
        }
        storage.endEditing()
    }
}
