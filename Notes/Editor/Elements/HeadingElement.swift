import SwiftUI
import NotesCore

/// `# Title` to `###### Title`: a larger font, with the `#` hidden. Backspace at the start of the text takes the `#` away.
struct HeadingElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .heading(let level, let marker) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let overlap = NSIntersectionRange(marker, line.range)
        let mark = NSRange(location: overlap.length > 0 ? overlap.location - line.range.location : 0, length: overlap.length)

        paragraph.addAttribute(.font, value: EditorTheme.headingFont(level: level), range: full)
        if mark.length > 0 {
            InlineStyler.hideOrDim(paragraph, range: mark, showsMarkdown: services.showsMarkdown)
            if marker.location > line.block.range.location, !services.showsMarkdown {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = 0.01
                style.maximumLineHeight = 0.01
                paragraph.addAttribute(.paragraphStyle, value: style, range: full)
            }
        }
        _ = InlineStyler.style(paragraph, hidesMarkers: !services.showsMarkdown, shrinksMarkers: true)
        return true
    }

    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange] {
        prefixMark(of: block, in: source).map { NSIntersectionRange($0, line) }.map { $0.length > 0 ? [$0] : [] } ?? []
    }

    func prefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange? {
        if case .heading(_, let marker) = block.kind { marker } else { nil }
    }
}
