import SwiftUI
import NotesCore

/// Ordinary text. Only its inline marks (bold, italic, code, links) are styled.
struct ParagraphElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        InlineStyler.style(paragraph, selection: line.selection)
    }
}
