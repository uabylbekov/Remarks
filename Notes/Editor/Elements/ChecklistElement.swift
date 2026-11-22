import SwiftUI
import NotesCore

/// `- [ ] task` and `- [x] done`: a box in place of the mark, drawn by `ChecklistFragment`. The mark is hidden but keeps
/// its room, which is the room for the box, and it is the same whether or not the caret is on the line. Backspace at the
/// start of the text takes the checkbox away.
struct ChecklistElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .checklist(let markPosition, let isChecked) = line.block.kind else { return false }
        let source = paragraph.string as NSString
        let full = NSRange(location: 0, length: paragraph.length)
        let markRange = NSRange(location: markPosition.location - line.range.location, length: markPosition.length)
        let indentRange = NSRange(location: 0, length: markRange.location)

        // The mark is the room for the box, so a bigger font here means a bigger box.
        let base = (paragraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
        let small = EditorFont.systemFont(ofSize: base.pointSize * 0.95)
        paragraph.addAttribute(.font, value: small, range: markRange)

        // Hide the mark, then draw a box in its room. The caret never rests inside it (see `adjustedSelection`), so the
        // Markdown behind the box is never shown.
        paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: markRange)

        let hiddenWidth = NSAttributedString(string: source.substring(with: markRange), attributes: [.font: small]).size().width
        let indentWidth = NSAttributedString(string: source.substring(with: indentRange), attributes: [.font: base]).size().width
        paragraph.addAttribute(LivePreviewController.checklistKey, value: isChecked ? 2 : 1, range: full)
        paragraph.addAttribute(LivePreviewController.checklistWidthKey, value: Double(hiddenWidth), range: full)
        paragraph.addAttribute(LivePreviewController.checklistIndentKey, value: Double(indentWidth), range: full)

        if isChecked {
            let content = NSRange(location: NSMaxRange(markRange), length: max(0, full.length - NSMaxRange(markRange)))
            paragraph.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: content)
        }
        _ = InlineStyler.style(paragraph, hidesMarkers: !services.showsMarkdown, shrinksMarkers: true)
        return true
    }

    /// The whole front of the line, indent included: the caret never rests there.
    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange) -> [NSRange] {
        guard case .checklist(let mark, _) = block.kind else { return [] }
        return [NSRange(location: line.location, length: NSMaxRange(mark) - line.location)]
    }

    func prefixMark(of block: MarkdownDocument.Block) -> NSRange? {
        if case .checklist(let mark, _) = block.kind { mark } else { nil }
    }
}
