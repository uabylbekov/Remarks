import SwiftUI
import NotesCore

/// `---`, `***`, `___`: a line across the text. The characters stay and are hidden, except while the caret is on the line:
/// then they show, so `****` (a bold pair just inserted) is not a mystery line. The height is the same either way, so
/// moving the caret never shifts anything. The line itself is drawn by `DecorationFragment`.
struct RuleElement: MarkdownElement {
    var readsInline: Bool { false }

    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        let full = NSRange(location: 0, length: paragraph.length)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 24
        style.maximumLineHeight = 24
        style.lineBreakMode = .byClipping
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        if line.isActive {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: full)
        } else {
            paragraph.addAttributes([.foregroundColor: EditorColor.clear, LivePreviewController.decorationKey: "rule"], range: full)
        }
        return true
    }
}
