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
    case table, math, diagram
}

/// Pure text logic for the formatting controls, so it can be tested without any UI.
/// It never touches the note directly: the editor applies the returned `TextEdit` so undo keeps working.
public enum MarkdownEditing {
    public static func edit(_ command: MarkdownCommand, in text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        let selection = clamped(selection, length: source.length)

        switch command {
        case .math: return richBlock("$$", body: "E = mc^2", in: text, selection: selection)
        case .diagram: return richBlock("```mermaid", body: "flowchart LR\n    A[Start] --> B[End]", in: text, selection: selection)
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
        }
    }

    private static func richBlock(_ fence: String, body: String, in text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        let content = selection.length > 0 ? source.substring(with: selection) : body
        let closing = fence == "$$" ? "$$" : "```"
        var edit = insertBlock(fence + "\n" + content + "\n" + closing, in: text, selection: selection)
        let prefix = edit.replacement.hasPrefix("\n") ? 1 : 0
        edit.selection = NSRange(location: edit.range.location + prefix + fence.utf16.count + 1, length: content.utf16.count)
        return edit
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
        let lineRange = source.lineRange(for: selection)
        let localSelection = NSRange(location: selection.location - lineRange.location, length: selection.length)
        if let span = InlineScanner.spans(in: source.substring(with: lineRange))
            .filter({ relevant($0.kind) && localSelection.location >= $0.content.location && NSMaxRange(localSelection) <= NSMaxRange($0.content) })
            .min(by: { $0.range.length < $1.range.length }) {
            let spanRange = NSRange(location: lineRange.location + span.range.location, length: span.range.length)
            let spanContent = NSRange(location: lineRange.location + span.content.location, length: span.content.length)
            let remaining = span.kind == .boldItalic ? (marker == "**" ? "*" : "**") : ""
            var content = source.substring(with: spanContent)
            var leadingPadTrimmed = 0
            // CommonMark pads inline code spans that start or end with a backtick; strip that single space pair on untoggle.
            if span.kind == .code, content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
               content.contains(where: { $0 != " " }) {
                content = String(content.dropFirst().dropLast())
                leadingPadTrimmed = 1
            }
            let newContentLength = (content as NSString).length
            let relativeStart = max(0, min(selection.location - spanContent.location - leadingPadTrimmed, newContentLength))
            let relativeEnd = max(relativeStart, min(NSMaxRange(selection) - spanContent.location - leadingPadTrimmed, newContentLength))
            return TextEdit(range: spanRange, replacement: remaining + content + remaining,
                            selection: NSRange(location: spanRange.location + remaining.utf16.count + relativeStart,
                                               length: relativeEnd - relativeStart))
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

    /// Returns the line's content without its terminator, plus the terminator itself (LF, CRLF, CR, etc.).
    private static func splitTerminator(of range: NSRange, in source: NSString) -> (content: String, terminator: String) {
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: range)
        let content = source.substring(with: NSRange(location: range.location, length: max(0, contentsEnd - range.location)))
        let terminator = source.substring(with: NSRange(location: contentsEnd, length: max(0, NSMaxRange(range) - contentsEnd)))
        return (content, terminator)
    }

    /// Inserts a fenced block with the caret at the start of its first body line.
    private static func codeBlock(in source: NSString, selection: NSRange) -> TextEdit {
        if selection.length > 0 {
            let lines = source.lineRange(for: selection)
            let (content, terminator) = splitTerminator(of: lines, in: source)
            return TextEdit(
                range: lines,
                replacement: "```\n" + content + "\n```" + terminator,
                selection: NSRange(location: lines.location + 4, length: 0)
            )
        }

        let line = source.lineRange(for: selection)
        let (content, terminator) = splitTerminator(of: line, in: source)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A blank line becomes the block, keeping its own newline.
            return TextEdit(
                range: line,
                replacement: "```\n\n```" + terminator,
                selection: NSRange(location: line.location + 4, length: 0)
            )
        }

        // A line with text: put the block after it.
        let lineEnd = line.location + (content as NSString).length
        return TextEdit(
            range: NSRange(location: lineEnd, length: 0),
            replacement: "\n```\n\n```",
            selection: NSRange(location: lineEnd + 1 + 4, length: 0)
        )
    }

    /// Sets the language of the fenced block that contains `offset`: the text after the opening fence. An empty language
    /// removes it. Nil if `offset` is not in a fenced block. The fence characters are kept, because a closing fence has
    /// to match them.
    public static func setCodeLanguage(_ language: String, inBlockAt offset: Int, in text: String) -> TextEdit? {
        let source = text as NSString
        let blocks = CodeBlockScanner.scan(text)
        guard let block = blocks.first(where: { NSLocationInRange(offset, $0.whole) })
            ?? blocks.first(where: { offset == NSMaxRange($0.whole) }) else { return nil }
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: block.open)
        let opener = source.substring(with: NSRange(location: block.open.location, length: contentsEnd - block.open.location))
        let leading = opener.prefix { $0 == " " || $0 == "\t" }
        let rest = opener.dropFirst(leading.count)
        let fenceChar = rest.first
        let fence = rest.prefix { $0 == fenceChar }
        // Info strings cannot contain line breaks, and backtick fences cannot contain backticks in their info string.
        let sanitized = language
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let name = fenceChar == "`" ? sanitized.replacingOccurrences(of: "`", with: "") : sanitized
        let line = String(leading) + String(fence) + name
        let range = NSRange(location: block.open.location, length: contentsEnd - block.open.location)
        let delta = (line as NSString).length - range.length
        // The caret stays where it was, moved with the text that came before it.
        let caret = offset > NSMaxRange(range) ? offset + delta : min(offset, range.location + (line as NSString).length)
        return TextEdit(range: range, replacement: line, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Heading

    private static let headingPrefix = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)

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

        let newPrefixLength = (newPrefix as NSString).length
        let delta = newPrefixLength - oldPrefixLength
        let newLength = source.length + delta
        let minCaret = line.location + newPrefixLength
        let newStart = min(max(minCaret, selection.location + delta), newLength)
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: newStart, length: 0)
        } else {
            let newEnd = min(max(newStart, NSMaxRange(selection) + delta), newLength)
            newSelection = NSRange(location: newStart, length: newEnd - newStart)
        }
        return TextEdit(
            range: NSRange(location: line.location, length: oldPrefixLength),
            replacement: newPrefix,
            selection: newSelection
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

        private static let bulletRegex = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+(?!\[[ xX]?\](?:[ \t]+|$))"#)
        private static let numberedRegex = try? NSRegularExpression(pattern: #"^([ \t]*)\d+[.)][ \t]+"#)
        private static let checklistRegex = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+\[[ xX]?\](?:[ \t]+|$)"#)
        private static let quoteRegex = try? NSRegularExpression(pattern: #"^([ \t]*)>[ \t]?"#)

        /// Pre-compiled regex matching the leading indentation (group 1) and mark of this style.
        var regex: NSRegularExpression? {
            switch self {
            case .bullet: Self.bulletRegex
            case .numbered: Self.numberedRegex
            case .checklist: Self.checklistRegex
            case .quote: Self.quoteRegex
            }
        }
    }

    private static let anyLinePrefix = try? NSRegularExpression(
        pattern: #"^([ \t]*)(?:[-*+][ \t]+(?:\[[ xX]?\](?:[ \t]+|$))?|\d+[.)][ \t]+|>[ \t]?)"#
    )

    private static func removingPrefix(_ style: LineStyle, from line: String) -> String? {
        guard let regex = style.regex,
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let ns = line as NSString
        let indent = ns.substring(with: match.range(at: 1))
        return indent + ns.substring(from: NSMaxRange(match.range))
    }

    /// Adds the style to every non-empty selected line, or removes it when all of them already have it.
    private static func toggleLines(_ style: LineStyle, in source: NSString, selection: NSRange) -> TextEdit {
        let lines = source.lineRange(for: selection)
        var lineEntries: [(content: String, terminator: String)] = []
        var offset = lines.location
        if lines.length == 0 {
            lineEntries.append(("", ""))
        } else {
            while offset < NSMaxRange(lines) {
                let lineRange = source.lineRange(for: NSRange(location: offset, length: 0))
                lineEntries.append(splitTerminator(of: lineRange, in: source))
                offset = NSMaxRange(lineRange)
            }
        }

        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        // A single blank line still counts, so the button starts a list on an empty line.
        let candidates = lineEntries.indices.filter { !isBlank(lineEntries[$0].content) || lineEntries.count == 1 }
        let allHaveStyle = !candidates.isEmpty && candidates.allSatisfy { removingPrefix(style, from: lineEntries[$0].content) != nil }

        let oldFirstLength = (lineEntries.first?.content as NSString?)?.length ?? 0
        var number = 1
        for index in candidates {
            if allHaveStyle, let stripped = removingPrefix(style, from: lineEntries[index].content) {
                lineEntries[index].content = stripped
            } else {
                let line = lineEntries[index].content
                let ns = line as NSString
                if let other = anyLinePrefix?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let indent = ns.substring(with: other.range(at: 1))
                    let rest = ns.substring(from: NSMaxRange(other.range))
                    lineEntries[index].content = indent + style.prefix(number: number) + rest
                } else {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    let rest = line.dropFirst(indent.count)
                    lineEntries[index].content = String(indent) + style.prefix(number: number) + String(rest)
                }
                number += 1
            }
        }

        let replacement = lineEntries.map { $0.content + $0.terminator }.joined()
        let trailingTerminatorLength = (lineEntries.last?.terminator as NSString?)?.length ?? 0
        let newSelection: NSRange
        if selection.length == 0 {
            let newFirstLength = (lineEntries.first?.content as NSString?)?.length ?? 0
            let caret = selection.location + newFirstLength - oldFirstLength
            newSelection = NSRange(location: min(max(caret, lines.location), lines.location + newFirstLength), length: 0)
        } else {
            let length = max(0, (replacement as NSString).length - trailingTerminatorLength)
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

    /// The row under a header: every cell contains only optional colons and at least one dash.
    public static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTableRow(trimmed) else { return false }
        let cells = MarkdownTable.cells(of: trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            guard !cell.isEmpty else { return false }
            var body = cell[...]
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
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
