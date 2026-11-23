import Foundation

extension MarkdownEditing {
    private static let splittableKinds: Set<InlineSpan.Kind> = [.bold, .italic, .boldItalic, .strikethrough, .code]

    /// Return with the caret inside bold, italic, strikethrough or inline code.
    ///
    /// These cannot run across lines, so a plain line break would leave `**hello` on one line and `**` on the next, both
    /// shown as raw text. Instead the break goes where it keeps each line's marks paired:
    /// - at the end of the text, after the closing marks: the formatting ends with the line;
    /// - at the start of the text, before the opening marks: the formatting starts on the next line;
    /// - in the middle: the span is closed, the line broken, and the span opened again, so both halves keep it.
    ///
    /// `next` is what a list item continues the next line with (its mark), and goes right after the line break.
    /// Nil when the caret is not inside such a span, so the caller does what it did before.
    static func inlineReturnEdit(in text: String, selection: NSRange, next: String) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length else { return nil }

        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let lineStart = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        guard selection.location <= contentsEnd else { return nil }
        let line = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let caret = selection.location - lineStart

        let allSpans = InlineScanner.spans(in: line)
        let spans = allSpans.filter {
            splittableKinds.contains($0.kind) && $0.content.location <= caret && caret <= NSMaxRange($0.content)
        }
        let lineText = line as NSString
        guard !spans.isEmpty else {
            // Formatting switched on and nothing typed yet (`**|**`) is not a span. Return cancels it, instead of leaving a
            // lone mark on each line, unless the markers are escaped, adjacent to longer runs, or part of existing spans.
            for marks in ["***", "**", "~~", "*", "_", "`"] {
                let length = (marks as NSString).length
                guard caret >= length, caret + length <= lineText.length,
                      lineText.substring(with: NSRange(location: caret - length, length: length)) == marks,
                      lineText.substring(with: NSRange(location: caret, length: length)) == marks else { continue }
                let unit = (marks as NSString).character(at: 0)
                if caret - length > 0, lineText.character(at: caret - length - 1) == unit { continue }
                if caret + length < lineText.length, lineText.character(at: caret + length) == unit { continue }
                var backslashes = 0
                var probe = caret - length
                while probe > 0, lineText.character(at: probe - 1) == 92 { backslashes += 1; probe -= 1 }
                if !backslashes.isMultiple(of: 2) { continue }
                let pair = NSRange(location: caret - length, length: 2 * length)
                if allSpans.contains(where: { NSIntersectionRange($0.range, pair).length > 0 }) { continue }
                let replacement = "\n" + next
                return TextEdit(range: NSRange(location: selection.location - length, length: 2 * length), replacement: replacement,
                                selection: NSRange(location: selection.location - length + (replacement as NSString).length, length: 0))
            }
            return nil
        }

        let outerToInner = spans.sorted { $0.range.length > $1.range.length }
        let openers = outerToInner.map { lineText.substring(with: NSRange(location: $0.range.location, length: $0.content.location - $0.range.location)) }.joined()
        let closers = outerToInner.reversed().map { lineText.substring(with: NSRange(location: NSMaxRange($0.content), length: NSMaxRange($0.range) - NSMaxRange($0.content))) }.joined()

        // Marks stacked end to end count as one: in `_**hello|**_` the caret is at the end of both texts, because the bold's
        // closing marks are followed directly by the italic's.
        var after = caret
        while let span = spans.first(where: { NSMaxRange($0.content) == after }) { after = NSMaxRange(span.range) }
        if after > caret, spans.allSatisfy({ NSMaxRange($0.range) <= after }) {
            // The closing marks follow the caret already, so the line break goes after them.
            let at = lineStart + after
            let replacement = "\n" + next
            return TextEdit(range: NSRange(location: at, length: 0), replacement: replacement,
                            selection: NSRange(location: at + (replacement as NSString).length, length: 0))
        }
        var before = caret
        while let span = spans.first(where: { $0.content.location == before }) { before = span.range.location }
        if before < caret, spans.allSatisfy({ $0.range.location >= before }) {
            // The opening marks precede the caret, so the line break goes before them, and the caret keeps its place in them.
            let at = lineStart + before
            let replacement = "\n" + next
            return TextEdit(range: NSRange(location: at, length: 0), replacement: replacement,
                            selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
        }
        // Spans that end and begin at different places are left to the plain line break rather than guessed at.
        guard spans.allSatisfy({ $0.content.location < caret && caret < NSMaxRange($0.content) }) else { return nil }
        var splitStart = caret
        var splitEnd = caret
        if let inner = outerToInner.last, outerToInner.contains(where: { $0.kind != .code }) {
            // Emphasis and strikethrough markers must hug non-whitespace characters on both halves.
            while splitStart > inner.content.location, [32, 9].contains(lineText.character(at: splitStart - 1)) {
                splitStart -= 1
            }
            while splitEnd < NSMaxRange(inner.content), [32, 9].contains(lineText.character(at: splitEnd)) {
                splitEnd += 1
            }
            guard splitStart > inner.content.location, splitEnd < NSMaxRange(inner.content) else { return nil }
        }
        let replacement = closers + "\n" + next + openers
        return TextEdit(range: NSRange(location: lineStart + splitStart, length: splitEnd - splitStart), replacement: replacement,
                        selection: NSRange(location: lineStart + splitStart + (replacement as NSString).length, length: 0))
    }
}
