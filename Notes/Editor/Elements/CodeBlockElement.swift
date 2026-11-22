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
        // Native fragment margins reserve card padding, including for the first paragraph in a document.
        style.paragraphSpacing = isOpen ? LivePreviewController.fenceGap : 0

        paragraph.addAttribute(.font, value: EditorTheme.codeFont, range: full)
        paragraph.addAttribute(LivePreviewController.blockMarkerKey, value: 1, range: full)

        if isFence {
            let small = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            style.minimumLineHeight = ceil(small.ascender - small.descender + small.leading)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
            let hidden = Self.hiddenMarker(in: paragraph.string as NSString, isOpen: isOpen, hasLanguage: !block.language.isEmpty)
            MarkdownDisplayProjection.hideMarkers(hidden, in: paragraph)
        } else {
            // The fence lines stay compact, so the card's edges do not move with the setting.
            style.lineSpacing = EditorTheme.codeLineSpacing
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: full)
            Self.applySyntaxColors(to: paragraph, range: line.range, tokens: services.syntaxTokens(for: block))
        }
        // Attributed strings retain paragraph styles; finish configuring it before publishing an immutable copy.
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: full)
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
    static func applySyntaxColors(to paragraph: NSMutableAttributedString, range: NSRange, tokens: [SyntaxToken]) {
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
/// in the text. Native fragment margins reserve the same space used by its background and caret.
final class CodeBlockFragment: NSTextLayoutFragment {
    private static let cornerRadius: CGFloat = 10
    weak var controller: LivePreviewController?

    private var row: LivePreviewController.BlockRow {
        controller?.blockRow(for: textElement) ?? .init(isFirst: true, isLast: true, isUnclosed: false)
    }

    /// TextKit reserves these margins before computing line and caret geometry.
    /// Paragraph spacing alone is insufficient: the first paragraph can omit spacing before it.
    override var topMargin: CGFloat {
        row.isFirst ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
    }

    override var bottomMargin: CGFloat {
        row.isLast ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
    }

    /// Background geometry comes from the same native fragment that lays out text and the insertion point.
    var cardBounds: CGRect {
        let frame = layoutFragmentFrame
        let top = row.isFirst ? LivePreviewController.cardMargin : 0
        // A closed final paragraph can contain TextKit’s extra line for the next prose insertion point.
        // It belongs outside the card; use the native real-line bounds instead of painting over it.
        let bottom: CGFloat
        if row.isLast, !row.isUnclosed, let last = textLineFragments.last(where: { $0.characterRange.length > 0 }) {
            bottom = last.typographicBounds.maxY
        } else {
            bottom = frame.height - (row.isLast ? LivePreviewController.cardMargin : 0)
        }
        return CGRect(
            x: -frame.minX,
            y: top,
            width: textLayoutManager?.textContainer?.size.width ?? frame.width,
            height: max(0, bottom - top)
        )
    }

    /// The opening row is both the label's drawing area and its tap target.
    var languageBounds: CGRect? {
        guard row.isFirst, let line = textLineFragments.first else { return nil }
        return CGRect(x: cardBounds.minX, y: line.typographicBounds.minY,
                      width: cardBounds.width, height: line.typographicBounds.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(cardBounds)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let bounds = cardBounds.offsetBy(dx: point.x, dy: point.y)
        let top = row.isFirst ? min(Self.cornerRadius, bounds.height / 2) : 0
        let bottom = row.isLast ? min(Self.cornerRadius, bounds.height / 2) : 0
        context.saveGState()
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(Self.path(for: bounds, topRadius: top, bottomRadius: bottom))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
        if let rect = languageBounds,
           controller?.codeLanguage(for: textElement)?.isEmpty == true {
            let font = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            let hint = NSAttributedString(string: String(localized: "Language") + " ▾",
                                          attributes: [.font: font, .foregroundColor: EditorTheme.dimColor])
            hint.draw(at: CGPoint(x: point.x + LivePreviewController.codeInset,
                                  y: point.y + rect.minY))
        }
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
