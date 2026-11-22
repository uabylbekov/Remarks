import SwiftUI
import NotesCore

/// `> quoted text`: a bar down the side, softer text, and the `>` hidden. The `>` keeps its room, which is where the bar is
/// drawn (see `DecorationFragment`). Backspace at the start of the text takes the `>` away.
struct QuoteElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .quote(let marker) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let mark = NSRange(location: marker.location - line.range.location, length: marker.length)

        paragraph.addAttribute(.foregroundColor, value: services.showsMarkdown ? EditorTheme.dimColor : EditorColor.clear, range: mark)
        let rest = NSRange(location: mark.length, length: max(0, full.length - mark.length))
        paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: rest)
        paragraph.addAttribute(LivePreviewController.decorationKey, value: "quote", range: full)
        _ = InlineStyler.style(paragraph, hidesMarkers: !services.showsMarkdown, shrinksMarkers: true)
        return true
    }

    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange) -> [NSRange] {
        prefixMark(of: block).map { [$0] } ?? []
    }

    func prefixMark(of block: MarkdownDocument.Block) -> NSRange? {
        if case .quote(let marker) = block.kind { marker } else { nil }
    }
}
