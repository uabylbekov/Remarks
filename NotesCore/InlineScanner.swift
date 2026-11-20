import Foundation

/// An inline Markdown construct inside one line of text. Ranges are UTF-16, relative to the scanned string.
public struct InlineSpan: Equatable, Sendable {
    public enum Kind: Sendable {
        case bold, italic, strikethrough, code, link
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
        let markerLength: Int
        let destinationGroup: Int?
    }

    private static func rule(_ kind: InlineSpan.Kind, _ pattern: String, content: Int, marker: Int, destination: Int? = nil) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(kind: kind, regex: regex, contentGroup: content, markerLength: marker, destinationGroup: destination)
    }

    /// Priority order: earlier rules claim text first.
    private static let rules: [Rule] = [
        rule(.code, #"`([^`\n]+)`"#, content: 1, marker: 1),
        rule(.link, #"(?<!!)\[([^\]\n]+)\]\(([^)\n]*)\)"#, content: 1, marker: 1, destination: 2),
        rule(.bold, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, content: 2, marker: 2),
        rule(.strikethrough, #"~~(?=\S)(.+?)(?<=\S)~~"#, content: 1, marker: 2),
        rule(.italic, #"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#, content: 1, marker: 1),
        rule(.italic, #"(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![_\w])"#, content: 1, marker: 1),
    ].compactMap { $0 }

    public static func spans(in text: String) -> [InlineSpan] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var accepted: [InlineSpan] = []

        for rule in rules {
            for match in rule.regex.matches(in: text, range: full) {
                let range = match.range
                let content = match.range(at: rule.contentGroup)
                guard content.location != NSNotFound else { continue }

                if accepted.contains(where: { partiallyOverlap($0.range, range) }) { continue }
                if accepted.contains(where: { $0.kind == .code && contains($0.range, range) }) { continue }

                let leading = NSRange(location: range.location, length: content.location - range.location)
                let trailing = NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))
                let destination = rule.destinationGroup.flatMap { group -> String? in
                    let urlRange = match.range(at: group)
                    return urlRange.location == NSNotFound ? nil : (text as NSString).substring(with: urlRange)
                }
                accepted.append(InlineSpan(
                    kind: rule.kind,
                    range: range,
                    content: content,
                    markers: [leading, trailing].filter { $0.length > 0 },
                    destination: destination
                ))
            }
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func partiallyOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0 && !contains(a, b) && !contains(b, a)
    }
}
