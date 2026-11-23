import Foundation

/// An inline Markdown construct inside one line of text. Ranges are UTF-16, relative to the scanned string.
public struct InlineSpan: Equatable, Sendable {
    public enum Kind: Sendable {
        case bold, italic, boldItalic, strikethrough, code, link, math
    }

    public let kind: Kind
    /// The whole construct, markers included.
    public let range: NSRange
    /// The visible text between the markers (a link's label).
    public let content: NSRange
    /// The marker ranges the live preview hides when the line is not being edited.
    public let markers: [NSRange]
    /// A link's destination, as typed.
    public let destination: String?
}

/// Finds bold, italic, strikethrough, inline code, and links in a single line.
/// Code wins over everything else (its contents are literal). Styles may nest (bold inside italic)
/// but never partially overlap.
public enum InlineScanner {
    private struct Rule {
        let kind: InlineSpan.Kind
        let regex: NSRegularExpression
        let contentGroup: Int
        let destinationGroup: Int?
        /// A bare address is plain text, so one inside a code span or a written-out link is left alone.
        let skipsInsideLinks: Bool
    }

    private static func rule(
        _ kind: InlineSpan.Kind, _ pattern: String, content: Int, destination: Int? = nil, skipsInsideLinks: Bool = false
    ) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(
            kind: kind, regex: regex, contentGroup: content, destinationGroup: destination,
            skipsInsideLinks: skipsInsideLinks
        )
    }

    /// Explicit links precede autolinks. Code and emphasis use their own delimiter scanners.
    private static let rules: [Rule] = [
        rule(.link, #"(?<!!)\[([^\]\n]+)\]\("#, content: 1),
        // A web address typed as plain text. It stops before the punctuation that ends a sentence.
        rule(.link, #"https?://[^\s<>]*[^\s<>.,;:!?'")\]]"#, content: 0, destination: 0, skipsInsideLinks: true),
    ].compactMap { $0 }

    public static func spans(in text: String) -> [InlineSpan] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var accepted = codeSpans(in: text as NSString)
        let source = text as NSString
        let escapedText = maskingEscapedPunctuation(in: text)

        for rule in rules {
            for match in rule.regex.matches(in: escapedText, range: full) {
                var range = match.range
                let content = match.range(at: rule.contentGroup)
                guard content.location != NSNotFound else { continue }

                var explicitDestination: String?
                if rule.kind == .link, !rule.skipsInsideLinks {
                    guard let destinationRange = linkDestination(startingAt: NSMaxRange(range), in: source) else { continue }
                    explicitDestination = unescapingPunctuation(source.substring(with: destinationRange))
                    range.length = NSMaxRange(destinationRange) + 1 - range.location
                }

                let leading = NSRange(location: range.location, length: content.location - range.location)
                let trailing = NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))
                let markers = [leading, trailing].filter { $0.length > 0 }

                if accepted.contains(where: { partiallyOverlap($0.range, range) }) { continue }
                if accepted.contains(where: { $0.kind == .code && contains($0.range, range) }) { continue }
                // A bare autolink cannot wrap or intersect an inline code span (e.g. `https://x/`code``).
                if rule.skipsInsideLinks, accepted.contains(where: { $0.kind == .code && NSIntersectionRange($0.range, range).length > 0 }) { continue }
                // Code spans inside link markers (e.g. a backticked destination) must not create overlapping markers.
                if accepted.contains(where: { span in markers.contains { NSIntersectionRange(span.range, $0).length > 0 } }) { continue }
                // A match that reaches into the marks of a span it sits in is those marks read again (`***a***` as `**` + `*a`).
                if accepted.contains(where: { contains($0.range, range) && $0.markers.contains { NSIntersectionRange($0, range).length > 0 } }) { continue }
                if rule.skipsInsideLinks, accepted.contains(where: { $0.kind == .link && contains($0.range, range) }) { continue }

                let destination = explicitDestination ?? rule.destinationGroup.flatMap { group -> String? in
                    let urlRange = match.range(at: group)
                    return urlRange.location == NSNotFound ? nil : (text as NSString).substring(with: urlRange)
                }
                accepted.append(InlineSpan(
                    kind: rule.kind,
                    range: range,
                    content: content,
                    markers: markers,
                    destination: destination
                ))
            }
        }
        if text.contains("$") { accepted += mathSpans(in: source, excluding: accepted) }
        accepted += emphasisSpans(in: source, excluding: accepted)
        return accepted.sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
    }

    /// Match whole backtick runs: a run only closes a span with the same delimiter length.
    private static func codeSpans(in source: NSString) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        var offset = 0
        while offset < source.length {
            guard source.character(at: offset) == 96, !isEscaped(offset, in: source) else { offset += 1; continue }
            let start = offset
            while offset < source.length, source.character(at: offset) == 96 { offset += 1 }
            let count = offset - start
            var end = offset
            var found = false
            while end < source.length, ![10, 13].contains(source.character(at: end)) {
                if source.character(at: end) != 96 { end += 1; continue }
                let close = end
                while end < source.length, source.character(at: end) == 96 { end += 1 }
                guard end - close == count else { continue }
                spans.append(InlineSpan(kind: .code, range: NSRange(location: start, length: end - start),
                                        content: NSRange(location: offset, length: close - offset),
                                        markers: [NSRange(location: start, length: count), NSRange(location: close, length: count)],
                                        destination: nil))
                offset = end
                found = true
                break
            }
            if !found { offset = start + count }
        }
        return spans
    }

    private static func mathSpans(in source: NSString, excluding spans: [InlineSpan]) -> [InlineSpan] {
        func whitespace(_ offset: Int) -> Bool {
            guard offset >= 0, offset < source.length else { return true }
            return UnicodeScalar(source.character(at: offset)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var result: [InlineSpan] = []
        var position = 0
        while position < source.length {
            let start = position
            guard source.character(at: start) == 36, !isEscaped(start, in: source),
                  start + 1 < source.length, source.character(at: start + 1) != 36,
                  (start == 0 || source.character(at: start - 1) != 36), !whitespace(start + 1),
                  !spans.contains(where: { NSLocationInRange(start, $0.range) }) else { position += 1; continue }
            position += 1
            while position < source.length {
                let unit = source.character(at: position)
                if [10, 13, 0x2028, 0x2029].contains(unit) { break }
                if unit == 36, !isEscaped(position, in: source) { break }
                position += 1
            }
            guard position < source.length, source.character(at: position) == 36 else { continue }
            let close = position
            position += 1
            let next = position < source.length ? source.character(at: position) : 0
            let range = NSRange(location: start, length: position - start)
            guard close > start + 1, !whitespace(close - 1), next != 36, !(48...57).contains(next),
                  !spans.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
            result.append(InlineSpan(kind: .math, range: range,
                                    content: NSRange(location: start + 1, length: close - start - 1),
                                    markers: [NSRange(location: start, length: 1), NSRange(location: close, length: 1)],
                                    destination: nil))
        }
        return result
    }

    private struct Delimiter {
        let location: Int
        let length: Int
        let unit: UInt16
        let opens: Bool
        let closes: Bool
        var remaining: Int
        var consumed: Int { length - remaining }
    }

    private static func emphasisSpans(in source: NSString, excluding spans: [InlineSpan]) -> [InlineSpan] {
        /// Reads the full Unicode scalar at a UTF-16 offset, decoding surrogate pairs cleanly.
        func scalar(at offset: Int) -> UnicodeScalar? {
            guard offset >= 0, offset < source.length else { return nil }
            let unit = source.character(at: offset)
            if (0xD800...0xDBFF).contains(unit), offset + 1 < source.length {
                let low = source.character(at: offset + 1)
                if (0xDC00...0xDFFF).contains(low) {
                    return UnicodeScalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                }
            }
            if (0xDC00...0xDFFF).contains(unit), offset > 0 {
                let high = source.character(at: offset - 1)
                if (0xD800...0xDBFF).contains(high) {
                    return UnicodeScalar(0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00))
                }
            }
            return UnicodeScalar(unit)
        }
        func whitespace(_ offset: Int) -> Bool {
            guard offset >= 0, offset < source.length else { return true }
            return scalar(at: offset).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        func punctuation(_ offset: Int) -> Bool {
            guard offset >= 0, offset < source.length else { return false }
            return scalar(at: offset).map {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            } ?? false
        }
        func containsNewline(from start: Int, to end: Int) -> Bool {
            var index = start
            while index < end {
                let unit = source.character(at: index)
                if unit == 10 || unit == 13 || unit == 0x2029 { return true }
                index += 1
            }
            return false
        }
        func protected(_ offset: Int) -> Bool {
            spans.contains { span in
                ((span.kind == .code || span.kind == .math) && NSLocationInRange(offset, span.range))
                    || span.markers.contains { NSLocationInRange(offset, $0) }
            }
        }
        var delimiters: [Delimiter] = []
        var offset = 0
        while offset < source.length {
            let unit = source.character(at: offset)
            guard [42, 95, 126].contains(unit), !isEscaped(offset, in: source), !protected(offset) else { offset += 1; continue }
            let start = offset
            while offset < source.length, source.character(at: offset) == unit,
                  !isEscaped(offset, in: source), !protected(offset) { offset += 1 }
            let count = offset - start
            if start > 0, source.character(at: start - 1) == unit, isEscaped(start - 1, in: source) { continue }
            if unit == 126, count != 2 { continue }
            let leftWhite = whitespace(start - 1), rightWhite = whitespace(offset)
            let leftPunctuation = punctuation(start - 1), rightPunctuation = punctuation(offset)
            let leftFlanking = !rightWhite && (!rightPunctuation || leftWhite || leftPunctuation)
            let rightFlanking = !leftWhite && (!leftPunctuation || rightWhite || rightPunctuation)
            delimiters.append(Delimiter(location: start, length: count, unit: unit,
                opens: unit == 95 ? leftFlanking && (!rightFlanking || leftPunctuation) : leftFlanking,
                closes: unit == 95 ? rightFlanking && (!leftFlanking || rightPunctuation) : rightFlanking,
                remaining: count))
        }

        var result: [InlineSpan] = []
        for closeIndex in delimiters.indices where delimiters[closeIndex].closes {
            var searchLimit = closeIndex
            while delimiters[closeIndex].remaining > 0, searchLimit > 0 {
                let close = delimiters[closeIndex]
                guard let openIndex = delimiters[..<searchLimit].lastIndex(where: { open in
                    guard open.opens, open.unit == close.unit, open.remaining > 0 else { return false }
                    if containsNewline(from: open.location + open.length, to: close.location) { return false }
                    if close.unit != 126, open.closes || close.opens,
                       (open.length + close.length).isMultiple(of: 3),
                       !(open.length.isMultiple(of: 3) && close.length.isMultiple(of: 3)) { return false }
                    return true
                }) else { break }
                let open = delimiters[openIndex]
                let available = min(open.remaining, close.remaining)
                let count = close.unit == 126 ? 2 : (available == 3 ? 3 : min(2, available))
                guard available >= count else { searchLimit = openIndex; continue }
                let start = open.location + open.remaining - count
                let end = close.location + close.consumed + count
                let content = NSRange(location: start + count, length: end - start - 2 * count)
                let range = NSRange(location: start, length: end - start)
                if content.length > 0, !spans.contains(where: { partiallyOverlap($0.range, range) }),
                   !result.contains(where: { partiallyOverlap($0.range, range) }) {
                    result.append(InlineSpan(kind: close.unit == 126 ? .strikethrough : (count == 3 ? .boldItalic : count == 2 ? .bold : .italic),
                        range: range, content: content,
                        markers: [NSRange(location: start, length: count), NSRange(location: end - count, length: count)],
                        destination: nil))
                    delimiters[openIndex].remaining -= count
                    delimiters[closeIndex].remaining -= count
                } else {
                    searchLimit = openIndex
                }
            }
        }
        return result
    }

    private static func isEscaped(_ offset: Int, in source: NSString) -> Bool {
        var position = offset
        while position > 0, source.character(at: position - 1) == 92 { position -= 1 }
        return !(offset - position).isMultiple(of: 2)
    }

    /// Preserve UTF-16 offsets while preventing escaped punctuation from acting as delimiters.
    private static func maskingEscapedPunctuation(in text: String) -> String {
        var units = Array(text.utf16)
        var index = 0
        while index + 1 < units.count {
            if units[index] == 92, isPunctuation(units[index + 1]) {
                units[index + 1] = 0xFFFC
                index += 2
            } else {
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isPunctuation(_ unit: UInt16) -> Bool {
        (33...47).contains(unit) || (58...64).contains(unit)
            || (91...96).contains(unit) || (123...126).contains(unit)
    }

    private static func unescapingPunctuation(_ text: String) -> String {
        let units = Array(text.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            if units[index] == 92, index + 1 < units.count, isPunctuation(units[index + 1]) {
                index += 1
            }
            result.append(units[index])
            index += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// The opening parenthesis is already matched. Scan until its balanced, unescaped closer.
    private static func linkDestination(startingAt start: Int, in source: NSString) -> NSRange? {
        var depth = 0
        var position = start
        while position < source.length {
            let unit = source.character(at: position)
            if unit == 10 || unit == 13 { return nil }
            if unit == 92, position + 1 < source.length, isPunctuation(source.character(at: position + 1)) {
                position += 2
                continue
            }
            if unit == 40 { depth += 1 }
            if unit == 41 {
                if depth == 0 { return NSRange(location: start, length: position - start) }
                depth -= 1
            }
            position += 1
        }
        return nil
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func partiallyOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0 && !contains(a, b) && !contains(b, a)
    }
}
