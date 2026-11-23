import SwiftUI
import RemarksCore

/// Bold, italic, strikethrough, inline code and links. They sit inside the text of other elements, and they nest, so
/// they share one scanner (`InlineScanner`) and one place for their look.
@MainActor
enum InlineStyler {
    private static let emptyMarkerPairs: [(open: String, close: String)] = [
        ("***", "***"),
        ("**", "**"),
        ("__", "__"),
        ("~~", "~~"),
        ("*", "*"),
        ("_", "_"),
        ("`", "`"),
        ("[", "]()"),
    ]

    /// Detects an empty inline marker pair directly surrounding a collapsed caret (e.g. `**|**` inserted by Bold on an
    /// empty line) so it can be dimmed like an active span before the user types inside it.
    static func emptyMarkerRange(in text: String, selection: NSRange?, existingSpans: [InlineSpan]? = nil) -> NSRange? {
        guard let selection, selection.length == 0 else { return nil }
        let source = text as NSString
        let caret = selection.location
        guard caret > 0, caret < source.length else { return nil }
        let spans = existingSpans ?? InlineScanner.spans(in: text)

        for pair in emptyMarkerPairs {
            let openLen = (pair.open as NSString).length
            let closeLen = (pair.close as NSString).length
            guard caret >= openLen, caret + closeLen <= source.length else { continue }
            let openStart = caret - openLen
            guard source.substring(with: NSRange(location: openStart, length: openLen)) == pair.open,
                  source.substring(with: NSRange(location: caret, length: closeLen)) == pair.close else { continue }

            // Skip backslash-escaped opening markers.
            var backslashes = 0
            var probe = openStart - 1
            while probe >= 0, source.character(at: probe) == 92 {
                backslashes += 1
                probe -= 1
            }
            if backslashes % 2 == 1 { continue }

            // Skip if part of a longer run of the same delimiter character (e.g. `****|****` or `` ```|``` ``).
            if pair.open == pair.close, let firstUnit = pair.open.utf16.first {
                let beforeMatches = openStart > 0 && source.character(at: openStart - 1) == firstUnit
                let afterMatches = caret + closeLen < source.length && source.character(at: caret + closeLen) == firstUnit
                if beforeMatches || afterMatches { continue }
            }

            let candidate = NSRange(location: openStart, length: openLen + closeLen)
            if spans.contains(where: { NSIntersectionRange($0.range, candidate).length > 0 }) { continue }
            return candidate
        }
        return nil
    }

    /// Reveal syntax only for spans touched by the selection; keep the rest quiet.
    /// - Returns: whether anything was styled.
    static func style(_ paragraph: NSMutableAttributedString, selection: NSRange?) -> Bool {
        let spans = InlineScanner.spans(in: paragraph.string)
        for span in spans {
            let base = (paragraph.attribute(.font, at: span.content.location, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
            switch span.kind {
            case .math:
                // Source stays fully visible until the controller has a rendered equation to substitute.
                paragraph.addAttributes([.font: EditorTheme.inlineCodeFont(matching: base), .foregroundColor: EditorTheme.baseColor], range: span.range)
                continue
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
                if isEditing(span.range, selection: selection) {
                    dimMarker(paragraph, range: marker)
                } else {
                    collapse(paragraph, range: marker)
                }
            }
        }
        if let emptyRange = emptyMarkerRange(in: paragraph.string, selection: selection, existingSpans: spans) {
            dimMarker(paragraph, range: emptyRange)
            return true
        }
        return !spans.isEmpty
    }

    static func isEditing(_ range: NSRange, selection: NSRange?) -> Bool {
        guard let selection else { return false }
        if selection.length == 0 {
            return selection.location >= range.location && selection.location <= NSMaxRange(range)
        }
        return NSIntersectionRange(range, selection).length > 0
    }

    /// Continuation lines start where the first line's content starts, preserving body spacing.
    static func applyHangingIndent(_ paragraph: NSMutableAttributedString, through prefixEnd: Int) {
        guard prefixEnd > 0, prefixEnd <= paragraph.length else { return }
        let prefix = paragraph.attributedSubstring(from: NSRange(location: 0, length: prefixEnd))
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.headIndent = style.firstLineHeadIndent + prefix.size().width
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: NSRange(location: 0, length: paragraph.length))
    }

    /// Hides a mark: transparent and nearly zero-sized, so it takes no room. The characters stay, so selection, copy, and
    /// undo work on the real Markdown. The caret never rests inside a hidden mark (see `adjustedSelection`).
    static func collapse(_ text: NSMutableAttributedString, range: NSRange) {
        text.addAttribute(.font, value: EditorFont.systemFont(ofSize: 0.01), range: range)
        text.addAttribute(.foregroundColor, value: EditorColor.clear, range: range)
    }

    /// Syntax stays full-sized and editable; only its color is muted.
    static func dimMarker(_ text: NSMutableAttributedString, range: NSRange) {
        if range.length > 0, text.attribute(.font, at: range.location, effectiveRange: nil) == nil {
            text.addAttribute(.font, value: EditorTheme.proseFont, range: range)
        }
        text.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: range)
    }
}
