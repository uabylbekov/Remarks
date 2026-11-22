import SwiftUI
import NotesCore

/// A fenced block: three backticks, a language, lines of code, three backticks. It is drawn as a rounded card with syntax
/// colors (see `CodeBlockFragment`). Its lines are never read as Markdown.
struct CodeBlockElement: MarkdownElement {
    /// Blocks longer than this are shown without syntax colors, so typing in a huge block stays smooth.
    static let highlightLimit = 60_000

    var readsInline: Bool { false }

    /// Layout depends only on what a line is (an opening fence, a closing fence, or code), never on where the caret is,
    /// what the neighboring lines hold, or whether it is the last line. Those change while typing, and anything that
    /// depended on them would move the text under the caret. Caret position changes colors only.
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .code(let block) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let isOpen = line.range.location == block.open.location
        let isClose = block.close.map { line.range.location == $0.location } ?? false
        let isFence = isOpen || isClose

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = LivePreviewController.codeInset
        style.headIndent = LivePreviewController.codeInset
        style.tailIndent = -LivePreviewController.codeInset
        style.paragraphSpacingBefore = isOpen ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
        style.paragraphSpacing = isOpen
            ? LivePreviewController.fenceGap
            : (isClose ? LivePreviewController.cardPadding + LivePreviewController.cardMargin : 0)

        paragraph.addAttribute(.font, value: EditorTheme.codeFont, range: full)
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        paragraph.addAttribute(LivePreviewController.blockMarkerKey, value: 1, range: full)

        if isFence {
            let small = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            style.minimumLineHeight = ceil(small.ascender - small.descender + small.leading)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
            let hidden = Self.hiddenMarker(in: paragraph.string as NSString, isOpen: isOpen, hasLanguage: !block.language.isEmpty)
            InlineStyler.collapse(paragraph, range: hidden)
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: full)
            applySyntaxColors(to: paragraph, range: line.range, tokens: services.syntaxTokens(for: block))
        }
        return true
    }

    static func hiddenMarker(in text: NSString, isOpen: Bool, hasLanguage: Bool) -> NSRange {
        var contentsEnd = text.length
        while contentsEnd > 0, [10, 13].contains(text.character(at: contentsEnd - 1)) { contentsEnd -= 1 }
        var markerEnd = 0
        while markerEnd < contentsEnd, [32, 9, 96, 126].contains(text.character(at: markerEnd)) { markerEnd += 1 }
        return NSRange(location: 0, length: isOpen && hasLanguage ? markerEnd : contentsEnd)
    }

    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange] {
        guard case .code(let code) = block.kind else { return [] }
        let isOpen = line.location == code.open.location
        guard isOpen || line.location == code.close?.location else { return [] }
        let local = Self.hiddenMarker(in: source.substring(with: line) as NSString, isOpen: isOpen, hasLanguage: !code.language.isEmpty)
        return local.length > 0 ? [NSRange(location: line.location, length: local.length)] : []
    }

    /// Colors come from the display layer, so the stored text is never touched and typing never triggers a rewrite.
    private func applySyntaxColors(to paragraph: NSMutableAttributedString, range: NSRange, tokens: [SyntaxToken]) {
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
}

// MARK: - Drawing

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
