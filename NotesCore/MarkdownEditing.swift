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

    /// Validate an edit against a snapshot before handing it to the native text input system.
    /// The inverse restores both the replaced text and the original selection.
    public func transaction(in text: String, selectionBefore: NSRange) -> TextEditTransaction? {
        TextEditTransaction(edit: self, text: text, selectionBefore: selectionBefore)
    }
}

/// The formatting actions offered by the keyboard bar and keyboard shortcuts.
public enum MarkdownCommand: CaseIterable, Sendable {
    case codeBlock, inlineCode, bold, italic, strikethrough, heading
    case bulletList, numberedList, checklist, quote, link
    case table, formatTable
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
        case .table: return table(in: source, selection: selection)
        case .formatTable: return formatTable(in: source, selection: selection)
        }
    }

    // MARK: Inline wrapping

    /// Wraps the selection in a marker, or removes the marker when it already surrounds the selection.
    /// With no selection it inserts a pair and puts the caret between them.
    private static func wrap(_ marker: String, in source: NSString, selection: NSRange) -> TextEdit {
        let markerLength = (marker as NSString).length
        let relevant: (InlineSpan.Kind) -> Bool = { kind in
            switch marker {
            case "**": kind == .bold || kind == .boldItalic
            case "_": kind == .italic || kind == .boldItalic
            case "~~": kind == .strikethrough
            case "`": kind == .code
            default: false
            }
        }
        if let span = InlineScanner.spans(in: source as String)
            .filter({ relevant($0.kind) && selection.location >= $0.content.location && NSMaxRange(selection) <= NSMaxRange($0.content) })
            .min(by: { $0.range.length < $1.range.length }) {
            let remaining = span.kind == .boldItalic ? (marker == "**" ? "*" : "**") : ""
            let content = source.substring(with: span.content)
            return TextEdit(range: span.range, replacement: remaining + content + remaining,
                            selection: NSRange(location: span.range.location + remaining.utf16.count + selection.location - span.content.location,
                                               length: selection.length))
        }

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

        if marker == "`", selection.length > 0 {
            let content = source.substring(with: selection)
            var longest = 0, run = 0
            for character in content {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
            let fence = String(repeating: "`", count: longest + 1)
            let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
            return TextEdit(range: selection, replacement: fence + padding + content + padding + fence,
                            selection: NSRange(location: selection.location + fence.utf16.count + padding.utf16.count,
                                               length: selection.length))
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

    // MARK: Tables (GitHub Markdown)

    /// A table row: starts and ends with a pipe.
    public static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    /// The row under a header: only pipes, colons, dashes, and spaces, with at least one dash.
    public static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTableRow(trimmed), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|:- ".contains($0) }
    }

    /// Where the pipes that divide a table row into cells are (UTF-16). A pipe after a backslash is part of a cell.
    public static func tablePipeOffsets(in line: NSString) -> [Int] {
        var offsets: [Int] = []
        var escaped = false
        for index in 0..<line.length {
            let character = line.character(at: index)
            if character == 124, !escaped { offsets.append(index) }
            escaped = character == 92 && !escaped
        }
        return offsets
    }

    private static func cells(of line: String) -> [String] {
        MarkdownTable.cells(of: line)
    }

    /// A three-column table with a header and two empty rows, already lined up. The table always ends with a line break,
    /// so there is a line below it for the caret: the table is shown as a grid, and the caret cannot rest inside it.
    private static func table(in source: NSString, selection: NSRange) -> TextEdit {
        let header = ["Column 1", "Column 2", "Column 3"]
        let width = 8
        func row(_ values: [String]) -> String {
            "| " + values.map { $0.padding(toLength: width, withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |"
        }
        let rule = "| " + header.map { _ in String(repeating: "-", count: width) }.joined(separator: " | ") + " |"
        let rows = [row(header), rule, row(["", "", ""]), row(["", "", ""])].joined(separator: "\n")

        let line = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0))
        let content = source.substring(with: line)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A blank line becomes the table, and the caret goes to the line after it.
            let replacement = rows + "\n"
            return TextEdit(
                range: line,
                replacement: replacement,
                selection: NSRange(location: line.location + (replacement as NSString).length, length: 0)
            )
        }
        // A line with text: put the table on the lines after it.
        var lineEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: line)
        let terminatorLength = NSMaxRange(line) - lineEnd
        let replacement = "\n" + rows + (terminatorLength > 0 ? "" : "\n")
        // With a line break already after the line, it becomes the table's own, and the caret goes past it.
        let caret = lineEnd + (replacement as NSString).length + terminatorLength
        return TextEdit(range: NSRange(location: lineEnd, length: 0), replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// Lines up the columns of the table the caret is in, by padding every cell to the widest one in its column.
    /// Returns an edit that changes nothing when the caret is not in a table.
    private static func formatTable(in source: NSString, selection: NSRange) -> TextEdit {
        let unchanged = TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        guard source.length > 0 else { return unchanged }
        var start = source.lineRange(for: NSRange(location: min(selection.location, source.length - 1), length: 0))
        guard isTableRow(source.substring(with: start)) else { return unchanged }

        // Grow to the whole run of table rows.
        while start.location > 0 {
            let previous = source.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard isTableRow(source.substring(with: previous)) else { break }
            start = NSUnionRange(start, previous)
        }
        var end = start
        while NSMaxRange(end) < source.length {
            let next = source.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            guard isTableRow(source.substring(with: next)) else { break }
            end = NSUnionRange(end, next)
        }

        let block = source.substring(with: end)
        let hadTrailingNewline = block.last?.isNewline == true
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        let table = lines.map { cells(of: $0) }
        let columns = table.map(\.count).max() ?? 0
        guard columns > 0 else { return unchanged }

        var widths = [Int](repeating: 3, count: columns)
        for (index, line) in lines.enumerated() where !isTableSeparator(line) {
            for (column, cell) in table[index].enumerated() { widths[column] = max(widths[column], cell.count) }
        }

        let formatted = lines.enumerated().map { index, line -> String in
            let values = table[index]
            if isTableSeparator(line) {
                let marks = (0..<columns).map { column -> String in
                    let cell = column < values.count ? values[column] : "---"
                    let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                    let dashes = String(repeating: "-", count: max(1, widths[column] - (left ? 1 : 0) - (right ? 1 : 0)))
                    return (left ? ":" : "") + dashes + (right ? ":" : "")
                }
                return "| " + marks.joined(separator: " | ") + " |"
            }
            let padded = (0..<columns).map { column -> String in
                let cell = column < values.count ? values[column] : ""
                return cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")

        let location = min(selection.location, end.location + (formatted as NSString).length)
        return TextEdit(range: end, replacement: formatted, selection: NSRange(location: location, length: 0))
    }

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

public struct TextEditTransaction: Equatable, Sendable {
    public let edit: TextEdit
    public let inverse: TextEdit
    public let result: String
    public let changesText: Bool

    fileprivate init?(edit: TextEdit, text: String, selectionBefore: NSRange) {
        func valid(_ range: NSRange, in text: String) -> Bool {
            let length = text.utf16.count
            guard range.location >= 0, range.location <= length, range.length >= 0,
                  range.length <= length - range.location else { return false }
            let source = text as NSString
            func scalarBoundary(_ offset: Int) -> Bool {
                offset == 0 || offset == length || !(0xDC00...0xDFFF).contains(source.character(at: offset))
            }
            return scalarBoundary(range.location) && scalarBoundary(NSMaxRange(range))
        }
        guard valid(edit.range, in: text), valid(selectionBefore, in: text) else { return nil }
        let source = text as NSString
        let replaced = source.substring(with: edit.range)
        let result = source.replacingCharacters(in: edit.range, with: edit.replacement)
        guard valid(edit.selection, in: result) else { return nil }
        self.edit = edit
        self.result = result
        self.changesText = replaced != edit.replacement
        self.inverse = TextEdit(
            range: NSRange(location: edit.range.location, length: edit.replacement.utf16.count),
            replacement: replaced, selection: selectionBefore
        )
    }
}
