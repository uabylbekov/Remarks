import SwiftUI
import NotesCore

/// An indented quote in a softer text color, with an editable Markdown prefix.
struct QuoteElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .quote(let marker) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let overlap = NSIntersectionRange(marker, line.range)
        if overlap.length > 0 {
            let mark = NSRange(location: overlap.location - line.range.location, length: overlap.length)
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: mark)
            InlineStyler.applyHangingIndent(paragraph, through: NSMaxRange(mark))
            let rest = NSRange(location: NSMaxRange(mark), length: max(0, full.length - NSMaxRange(mark)))
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: rest)
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: full)
        }
        _ = InlineStyler.style(paragraph, selection: line.selection)
        return true
    }

}
