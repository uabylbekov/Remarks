import SwiftUI
import RemarksCore

/// Heading text keeps its hierarchy while its editable Markdown markers use a softer color.
struct HeadingElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .heading(let level, let marker) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let overlap = NSIntersectionRange(marker, line.range)
        let isUnderline = marker.location > line.block.range.location && overlap.length > 0
        let font = isUnderline ? EditorTheme.proseFont : EditorTheme.headingFont(level: level)
        paragraph.addAttribute(.font, value: font, range: full)
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: full)
        _ = InlineStyler.style(paragraph, selection: line.selection)
        if overlap.length > 0 {
            let mark = NSRange(location: overlap.location - line.range.location, length: overlap.length)
            InlineStyler.dimMarker(paragraph, range: mark)
            if !isUnderline { InlineStyler.applyHangingIndent(paragraph, through: NSMaxRange(mark)) }
        }
        return true
    }
}
