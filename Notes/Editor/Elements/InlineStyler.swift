import SwiftUI
import NotesCore

/// Bold, italic, strikethrough, inline code and links. They sit inside the text of other elements, and they nest, so
/// they share one scanner (`InlineScanner`) and one place for their look.
enum InlineStyler {
    /// Styles the spans in a line and hides their marks, or dims them when Markdown is shown. Marks look the same whether
    /// or not the caret is on the line, so moving the caret never moves the text.
    /// - Returns: whether anything was styled.
    static func style(_ paragraph: NSMutableAttributedString, hidesMarkers: Bool, shrinksMarkers: Bool) -> Bool {
        let spans = InlineScanner.spans(in: paragraph.string)
        for span in spans {
            let base = (paragraph.attribute(.font, at: span.content.location, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
            switch span.kind {
            case .bold:
                paragraph.addAttribute(.font, value: EditorTheme.traited(base, bold: true), range: span.content)
            case .italic:
                paragraph.addAttribute(.font, value: EditorTheme.traited(base, italic: true), range: span.content)
            case .boldItalic:
                paragraph.addAttribute(.font, value: EditorTheme.traited(base, bold: true, italic: true), range: span.content)
            case .strikethrough:
                paragraph.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            case .code:
                paragraph.addAttributes([
                    .font: EditorTheme.inlineCodeFont(matching: base),
                    .backgroundColor: EditorTheme.codeBackground,
                ], range: span.content)
            case .link:
                paragraph.addAttributes([
                    .foregroundColor: EditorTheme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: span.content)
                if let destination = span.destination, !destination.isEmpty {
                    paragraph.addAttribute(LivePreviewController.linkURLKey, value: destination, range: span.content)
                }
            }
            for marker in span.markers {
                if hidesMarkers { collapse(paragraph, range: marker) } else { dimMarker(paragraph, range: marker, shrinks: shrinksMarkers) }
            }
        }
        return !spans.isEmpty
    }

    /// Continuation lines start where the first line's content starts, preserving body spacing.
    static func applyHangingIndent(_ paragraph: NSMutableAttributedString, through prefixEnd: Int) {
        guard prefixEnd > 0, prefixEnd <= paragraph.length else { return }
        let prefix = paragraph.attributedSubstring(from: NSRange(location: 0, length: prefixEnd))
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.headIndent = style.firstLineHeadIndent + prefix.size().width
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
    }

    /// Hides a mark: transparent and nearly zero-sized, so it takes no room. The characters stay, so selection, copy, and
    /// undo work on the real Markdown. The caret never rests inside a hidden mark (see `adjustedSelection`).
    static func collapse(_ text: NSMutableAttributedString, range: NSRange) {
        text.addAttribute(.font, value: EditorFont.systemFont(ofSize: 0.01), range: range)
        text.addAttribute(.foregroundColor, value: EditorColor.clear, range: range)
    }

    /// Shows a Markdown mark dimmed and, where `shrinks` allows, smaller than the text around it. The mark keeps its
    /// place in the layout, so the character count, selection, copy, and undo all work on the real Markdown.
    static func dimMarker(_ text: NSMutableAttributedString, range: NSRange, shrinks: Bool) {
        text.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: range)
        // A line made only of marks keeps its font, so typing the first word does not change the line's height.
        let content = (text.string as NSString).length - (text.string.hasSuffix("\n") ? 1 : 0)
        guard shrinks, range.length < content,
              let base = text.attribute(.font, at: range.location, effectiveRange: nil) as? EditorFont else { return }
        text.addAttribute(.font, value: EditorFont.systemFont(ofSize: base.pointSize * 0.7), range: range)
    }
}
