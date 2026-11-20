import Foundation

/// A single text replacement plus the selection to restore afterwards. Ranges are UTF-16.
public struct TextEdit: Equatable, Sendable {
    /// The range of the original text to replace.
    public var range: NSRange
    public var replacement: String
    /// The selection in the text after the replacement is applied.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// The formatting actions offered by the keyboard bar and keyboard shortcuts.
public enum MarkdownCommand: CaseIterable, Sendable {
    case codeBlock, inlineCode, bold, italic, strikethrough, heading
    case bulletList, numberedList, checklist, quote, link
}

/// Pure text logic for the formatting controls, so it can be tested without any UI.
/// It never touches the note directly: the editor applies the returned `TextEdit` so undo keeps working.
public enum MarkdownEditing {
    public static func edit(_ command: MarkdownCommand, in text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        let selection = clamped(selection, length: source.length)

        switch command {
        case .inlineCode: return wrap("`", in: source, selection: selection)
        case .bold: return wrap("**", in: source, selection: selection)
        case .italic: return wrap("_", in: source, selection: selection)
        case .strikethrough: return wrap("~~", in: source, selection: selection)
        case .codeBlock: return codeBlock(in: source, selection: selection)
        case .heading: return heading(in: source, selection: selection)
        case .bulletList: return toggleLines(.bullet, in: source, selection: selection)
        case .numberedList: return toggleLines(.numbered, in: source, selection: selection)
        case .checklist: return toggleLines(.checklist, in: source, selection: selection)
        case .quote: return toggleLines(.quote, in: source, selection: selection)
        case .link: return link(in: source, selection: selection)
        }
    }

    // MARK: Inline wrapping

    /// Wraps the selection in a marker, or removes the marker when it already surrounds the selection.
    /// With no selection it inserts a pair and puts the caret between them.
    private static func wrap(_ marker: String, in source: NSString, selection: NSRange) -> TextEdit {
        let markerLength = (marker as NSString).length

        let hasMarkerBefore = selection.location >= markerLength
            && source.substring(with: NSRange(location: selection.location - markerLength, length: markerLength)) == marker
        let hasMarkerAfter = NSMaxRange(selection) + markerLength <= source.length
            && source.substring(with: NSRange(location: NSMaxRange(selection), length: markerLength)) == marker
        if hasMarkerBefore && hasMarkerAfter {
            let outer = NSRange(location: selection.location - markerLength, length: selection.length + 2 * markerLength)
            return TextEdit(
                range: outer,
                replacement: source.substring(with: selection),
                selection: NSRange(location: outer.location, length: selection.length)
            )
        }

        if selection.length == 0 {
            return TextEdit(
                range: selection,
                replacement: marker + marker,
                selection: NSRange(location: selection.location + markerLength, length: 0)
            )
        }
        return TextEdit(
            range: selection,
            replacement: marker + source.substring(with: selection) + marker,
            selection: NSRange(location: selection.location + markerLength, length: selection.length)
        )
    }

    // MARK: Code block

    /// Inserts a fenced block and leaves the caret right after the opening ``` so a language can be typed.
    private static func codeBlock(in source: NSString, selection: NSRange) -> TextEdit {
        if selection.length > 0 {
            let lines = source.lineRange(for: selection)
            var content = source.substring(with: lines)
            let hadNewline = content.hasSuffix("\n")
            if hadNewline { content.removeLast() }
            return TextEdit(
                range: lines,
                replacement: "```\n" + content + "\n```" + (hadNewline ? "\n" : ""),
                selection: NSRange(location: lines.location + 3, length: 0)
            )
        }

        let line = source.lineRange(for: selection)
        let content = source.substring(with: line)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A blank line becomes the block, keeping its own newline.
            let hadNewline = content.hasSuffix("\n")
            return TextEdit(
                range: line,
                replacement: "```\n\n```" + (hadNewline ? "\n" : ""),
                selection: NSRange(location: line.location + 3, length: 0)
            )
        }

        // A line with text: put the block after it.
        let lineEnd = NSMaxRange(line) - (content.hasSuffix("\n") ? 1 : 0)
        return TextEdit(
            range: NSRange(location: lineEnd, length: 0),
            replacement: "\n```\n\n```",
            selection: NSRange(location: lineEnd + 1 + 3, length: 0)
        )
    }

    // MARK: Heading

    private static let headingPrefix = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]"#)

    /// Cycles the current line through #, ##, ###, and back to plain text.
    private static func heading(in source: NSString, selection: NSRange) -> TextEdit {
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = source.substring(with: line)

        var oldPrefixLength = 0
        var newPrefix = "# "
        if let match = headingPrefix?.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
            let level = match.range(at: 1).length
            oldPrefixLength = match.range.length
            newPrefix = level < 3 ? String(repeating: "#", count: level + 1) + " " : ""
        }

        let delta = (newPrefix as NSString).length - oldPrefixLength
        let caret = max(line.location + (newPrefix as NSString).length, selection.location + delta)
        return TextEdit(
            range: NSRange(location: line.location, length: oldPrefixLength),
            replacement: newPrefix,
            selection: NSRange(location: caret, length: selection.length)
        )
    }

    // MARK: Line prefixes (lists and quotes)

    private enum LineStyle {
        case bullet, numbered, checklist, quote

        func prefix(number: Int) -> String {
            switch self {
            case .bullet: "- "
            case .numbered: "\(number). "
            case .checklist: "- [ ] "
            case .quote: "> "
            }
        }

        /// Matches the leading mark of this style.
        var pattern: String {
            switch self {
            case .bullet: #"^[-*+][ \t]+(?!\[[ xX]\])"#
            case .numbered: #"^\d+[.)][ \t]+"#
            case .checklist: #"^[-*+][ \t]+\[[ xX]\][ \t]+"#
            case .quote: #"^>[ \t]?"#
            }
        }
    }

    private static let anyLinePrefix = try? NSRegularExpression(
        pattern: #"^(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+|>[ \t]?)"#
    )

    private static func removingPrefix(_ style: LineStyle, from line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: style.pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        return (line as NSString).replacingCharacters(in: match.range, with: "")
    }

    /// Adds the style to every non-empty selected line, or removes it when all of them already have it.
    private static func toggleLines(_ style: LineStyle, in source: NSString, selection: NSRange) -> TextEdit {
        let lines = source.lineRange(for: selection)
        let block = source.substring(with: lines)
        let endsWithNewline = block.hasSuffix("\n")
        var parts = block.components(separatedBy: "\n")
        if endsWithNewline { parts.removeLast() }

        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        // A single blank line still counts, so the button starts a list on an empty line.
        let candidates = parts.indices.filter { !isBlank(parts[$0]) || parts.count == 1 }
        let allHaveStyle = !candidates.isEmpty && candidates.allSatisfy { removingPrefix(style, from: parts[$0]) != nil }

        var number = 1
        for index in candidates {
            if allHaveStyle, let stripped = removingPrefix(style, from: parts[index]) {
                parts[index] = stripped
            } else {
                var line = parts[index]
                if let other = anyLinePrefix?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    line = (line as NSString).replacingCharacters(in: other.range, with: "")
                }
                parts[index] = style.prefix(number: number) + line
                number += 1
            }
        }

        let replacement = parts.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let newSelection: NSRange
        if selection.length == 0 {
            let oldFirst = (block.components(separatedBy: "\n").first ?? "") as NSString
            let newFirst = (parts.first ?? "") as NSString
            let caret = selection.location + newFirst.length - oldFirst.length
            newSelection = NSRange(location: min(max(caret, lines.location), lines.location + newFirst.length), length: 0)
        } else {
            let length = (replacement as NSString).length - (endsWithNewline ? 1 : 0)
            newSelection = NSRange(location: lines.location, length: length)
        }
        return TextEdit(range: lines, replacement: replacement, selection: newSelection)
    }

    // MARK: Link

    /// `[selection]()` with the caret between the parentheses, or `[]()` with the caret between the brackets.
    private static func link(in source: NSString, selection: NSRange) -> TextEdit {
        if selection.length == 0 {
            return TextEdit(range: selection, replacement: "[]()", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let label = source.substring(with: selection)
        return TextEdit(
            range: selection,
            replacement: "[\(label)]()",
            selection: NSRange(location: selection.location + (label as NSString).length + 3, length: 0)
        )
    }

    // MARK: Helpers

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }
}
