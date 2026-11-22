import SwiftUI
import NotesCore

/// `- item`, `* item`, `+ item`: the dash is drawn as a dot. The stored dash is not touched, and the dot is one character
/// wide, like the dash, so the text does not move.
struct BulletElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .bullet(let marker) = line.block.kind else { return false }
        let mark = NSRange(location: marker.location - line.range.location, length: marker.length)
        paragraph.replaceCharacters(in: mark, with: "\u{2022}")
        let source = paragraph.string as NSString
        var prefixEnd = NSMaxRange(mark)
        while prefixEnd < source.length, [32, 9].contains(source.character(at: prefixEnd)) { prefixEnd += 1 }
        InlineStyler.applyHangingIndent(paragraph, through: prefixEnd)
        _ = InlineStyler.style(paragraph, hidesMarkers: !services.showsMarkdown, shrinksMarkers: true)
        return true
    }
}
