import SwiftUI
import NotesCore

/// List markers (bullets and ordered numbers) stay editable, with a hanging indent for wrapped content.
struct BulletElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        let marker: NSRange
        switch line.block.kind {
        case .bullet(let range), .numbered(let range): marker = range
        default: return false
        }
        let overlap = NSIntersectionRange(marker, line.range)
        if overlap.length > 0 {
            let mark = NSRange(location: overlap.location - line.range.location, length: overlap.length)
            InlineStyler.dimMarker(paragraph, range: mark)
            let source = paragraph.string as NSString
            var prefixEnd = NSMaxRange(mark)
            while prefixEnd < source.length, [32, 9].contains(source.character(at: prefixEnd)) { prefixEnd += 1 }
            InlineStyler.applyHangingIndent(paragraph, through: prefixEnd)
        }
        _ = InlineStyler.style(paragraph, selection: line.selection)
        return true
    }
}
