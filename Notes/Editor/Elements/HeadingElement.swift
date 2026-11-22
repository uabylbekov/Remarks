import SwiftUI
import NotesCore

/// `# Title` to `###### Title`: a larger font, with the `#` hidden. Backspace at the start of the text takes the `#` away.
struct HeadingElement: MarkdownElement {
    static let markerWidth: CGFloat = 30
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .heading(let level, let marker) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let overlap = NSIntersectionRange(marker, line.range)
        let mark = NSRange(location: overlap.length > 0 ? overlap.location - line.range.location : 0, length: overlap.length)

        let font = EditorTheme.headingFont(level: level)
        paragraph.addAttribute(.font, value: font, range: full)
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let headingStyle = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        headingStyle.minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        headingStyle.firstLineHeadIndent = Self.markerWidth
        headingStyle.headIndent = Self.markerWidth
        if line.range.location == line.block.range.location {
            paragraph.addAttribute(LivePreviewController.headingLevelKey, value: level, range: full)
        }
        paragraph.addAttribute(.paragraphStyle, value: headingStyle, range: full)
        if mark.length > 0 {
            InlineStyler.hideOrDim(paragraph, range: mark, showsMarkdown: services.showsMarkdown)
            if !services.showsMarkdown, marker.location == line.block.range.location {
                // A native metric anchor keeps an empty heading's baseline equal to a populated one.
                let anchor = NSRange(location: mark.location, length: 1)
                paragraph.replaceCharacters(in: anchor, with: "\u{FFFC}")
                paragraph.addAttributes([
                    .font: font,
                    .attachment: AttachmentDrawing.placeholder(size: CGSize(width: 0.001, height: font.capHeight)),
                ], range: anchor)
            }
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

/// A stable heading-level cue occupies the paragraph's leading indent, outside editable text.
final class HeadingFragment: NSTextLayoutFragment {
    override var renderingSurfaceBounds: CGRect {
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        return super.renderingSurfaceBounds.union(
            CGRect(x: padding - layoutFragmentFrame.minX, y: 0,
                   width: HeadingElement.markerWidth, height: layoutFragmentFrame.height)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString,
              let level = paragraph.attribute(LivePreviewController.headingLevelKey, at: 0, effectiveRange: nil) as? Int,
              let line = textLineFragments.first else { return }
        let font = EditorFont.systemFont(ofSize: 10, weight: .medium)
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let rect = CGRect(x: point.x - layoutFragmentFrame.minX + padding,
                          y: point.y + baseline - font.ascender,
                          width: HeadingElement.markerWidth - 6,
                          height: ceil(font.ascender - font.descender + font.leading))
        AttachmentDrawing.draw(text: "H\(level)", font: font, color: EditorTheme.dimColor, in: rect, context: context)
    }
}
