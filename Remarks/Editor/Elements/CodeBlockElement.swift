import SwiftUI
import RemarksCore

/// A fenced block: three backticks, a language, lines of code, three backticks. It uses monospace text and syntax
/// colors on the editor's background. Its lines are never read as Markdown.
struct CodeBlockElement: MarkdownElement {
    /// Blocks longer than this are shown without syntax colors, so typing in a huge block stays smooth.
    static let highlightLimit = 60_000

    /// Layout depends only on what a line is (an opening fence, a closing fence, or code), never on where the caret is,
    /// what the neighboring lines hold, or whether it is the last line. Those change while typing, and anything that
    /// depended on them would move the text under the caret. Visible syntax remains stable during selection changes.
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
        // Native fragment margins separate code from the surrounding prose.
        style.paragraphSpacing = isOpen ? LivePreviewController.fenceGap : 0

        paragraph.addAttribute(.font, value: EditorTheme.codeFont, range: full)
        paragraph.addAttribute(LivePreviewController.blockMarkerKey, value: 1, range: full)

        if isFence {
            let small = EditorTheme.fenceFont
            style.minimumLineHeight = ceil(small.ascender - small.descender + small.leading)
            paragraph.addAttributes([.font: small, .foregroundColor: EditorTheme.dimColor], range: full)
            if isOpen, !block.language.isEmpty {
                let text = paragraph.string as NSString
                let language = text.range(of: block.language, options: .caseInsensitive)
                if language.location != NSNotFound {
                    paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: language)
                }
            }
        } else {
            // Keep the language row compact while respecting code line spacing.
            style.lineSpacing = EditorTheme.codeLineSpacing
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.codeTextColor, range: full)
            Self.applySyntaxColors(to: paragraph, range: line.range, tokens: services.syntaxTokens(for: block))
        }
        // Attributed strings retain paragraph styles; finish configuring it before publishing an immutable copy.
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: full)
        return true
    }

    /// Colors and font traits come from the display layer, so the stored text is never touched and typing never triggers a rewrite.
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
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.scope), range: local)
            if let font = EditorTheme.font(for: token.scope) {
                paragraph.addAttribute(.font, value: font, range: local)
            }
        }
    }
}

// MARK: - Layout

/// Reserves native spacing around code without custom drawing.
final class CodeBlockFragment: NSTextLayoutFragment {
    weak var controller: LivePreviewController?

    private var row: LivePreviewController.BlockRow {
        controller?.blockRow(for: textElement) ?? .init(isFirst: true, isLast: true)
    }

    /// TextKit reserves these margins before computing line and caret geometry.
    /// Paragraph spacing alone is insufficient: the first paragraph can omit spacing before it.
    override var topMargin: CGFloat {
        row.isFirst ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
    }

    override var bottomMargin: CGFloat {
        row.isLast ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
    }

}
