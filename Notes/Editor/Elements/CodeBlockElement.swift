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
        let isBlockActive = services.isActive(block)

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
            // The same small text in both states. While idle, the backticks are invisible but still take their
            // room, so the language stays exactly where it is and only the backticks appear when editing.
            let small = EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
            if !isBlockActive {
                let text = paragraph.string as NSString
                var markerEnd = 0
                while markerEnd < text.length, [32, 9, 96, 126].contains(text.character(at: markerEnd)) { markerEnd += 1 }
                // An opening fence keeps its language visible. A closing fence is hidden entirely.
                let hidden = isOpen && !block.language.isEmpty ? NSRange(location: 0, length: markerEnd) : full
                paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: hidden)
            }
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: full)
            applySyntaxColors(to: paragraph, range: line.range, tokens: services.syntaxTokens(for: block))
        }
        return true
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
