import Foundation

/// Return-key behavior for lists and quotes, and checkbox toggling (Spec 03).
/// Pure text logic: the editor applies the returned `TextEdit` so undo keeps working.
extension MarkdownEditing {
    private struct ListItem {
        enum Kind { case bullet(marker: String, checkbox: Bool), numbered(number: Int, separator: String), quote }

        let indent: String
        let kind: Kind
        /// UTF-16 length of the indentation and mark, including the space after it.
        let prefixLength: Int
        /// A checkbox typed as `[]` or `[ ]` with nothing after it yet. Return then starts the next item
        /// instead of ending the list, because the box has just been typed and is not an abandoned empty item.
        var isFreshCheckbox = false
        var quoteContinuation: String?

        /// The mark for the next line.
        var continuation: String {
            switch kind {
            case .bullet(let marker, let checkbox): indent + marker + " " + (checkbox ? "[ ] " : "")
            case .numbered(let number, let separator): indent + "\(number + 1)\(separator) "
            case .quote: quoteContinuation ?? (indent + "> ")
            }
        }
    }

    /// Group 5 is an optional checkbox: `[ ]`, `[x]`, or `[]`, followed by a space or the end of the line.
    private static let listPattern = try? NSRegularExpression(
        pattern: #"^([ \t]*)(?:(\d+)([.)])|([-*+]))[ \t]+(\[[ xX]?\](?:[ \t]+|$))?"#
    )
    private static let quotePattern = try? NSRegularExpression(pattern: #"^([ \t]*)(?:>[ \t]?)+"#)

    private static func parseListItem(_ line: String) -> ListItem? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        let source = line as NSString

        if let match = listPattern?.firstMatch(in: line, range: range) {
            let indent = source.substring(with: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound, let number = Int(source.substring(with: match.range(at: 2))) {
                return ListItem(
                    indent: indent,
                    kind: .numbered(number: number, separator: source.substring(with: match.range(at: 3))),
                    prefixLength: match.range.length
                )
            }
            let hasCheckbox = match.range(at: 5).location != NSNotFound
            var item = ListItem(
                indent: indent,
                kind: .bullet(marker: source.substring(with: match.range(at: 4)), checkbox: hasCheckbox),
                prefixLength: match.range.length
            )
            if hasCheckbox {
                let box = source.substring(with: match.range(at: 5))
                item.isFreshCheckbox = !(box.hasSuffix(" ") || box.hasSuffix("\t"))
            }
            return item
        }
        if let match = quotePattern?.firstMatch(in: line, range: range) {
            return ListItem(indent: source.substring(with: match.range(at: 1)), kind: .quote, prefixLength: match.range.length,
                            quoteContinuation: source.substring(with: match.range))
        }
        return nil
    }

    /// The edit for pressing Return, or nil to let the text view insert a plain newline.
    /// - In a list item with text: starts the next item (a new checkbox is always unchecked, numbers count up).
    /// - In an empty list item: removes the mark and leaves a blank line, which ends the list.
    /// - Anywhere else, or with a selection, or with the caret inside the mark: nil.
    public static func returnKeyEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let source = text as NSString
        guard selection.location <= source.length else { return nil }

        let lineRange = source.lineRange(for: selection)
        var line = source.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        guard let item = parseListItem(line) else { return nil }

        let caretInLine = selection.location - lineRange.location
        guard caretInLine >= item.prefixLength else { return nil }

        let lineLength = (line as NSString).length
        let content = (line as NSString).substring(from: min(item.prefixLength, lineLength))
        if content.trimmingCharacters(in: .whitespaces).isEmpty && caretInLine == lineLength && !item.isFreshCheckbox {
            if !item.indent.isEmpty {
                let removed = item.indent.hasSuffix("\t") ? 1 : min(4, item.indent.count)
                let replacement = String(item.indent.dropLast(removed)) + (line as NSString).substring(from: item.indent.utf16.count)
                return TextEdit(range: NSRange(location: lineRange.location, length: lineLength), replacement: replacement,
                                selection: NSRange(location: lineRange.location + replacement.utf16.count, length: 0))
            }
            if let quote = item.quoteContinuation, quote.filter({ $0 == ">" }).count > 1,
               let lastMark = quote.lastIndex(of: ">") {
                let replacement = String(quote[..<lastMark])
                return TextEdit(range: NSRange(location: lineRange.location, length: lineLength), replacement: replacement,
                                selection: NSRange(location: lineRange.location + replacement.utf16.count, length: 0))
            }
            return TextEdit(
                range: NSRange(location: lineRange.location, length: lineLength),
                replacement: "",
                selection: NSRange(location: lineRange.location, length: 0)
            )
        }

        let next = item.continuation
        return TextEdit(
            range: NSRange(location: selection.location, length: 0),
            replacement: "\n" + next,
            selection: NSRange(location: selection.location + 1 + (next as NSString).length, length: 0)
        )
    }

    private static let checkboxPattern = try? NSRegularExpression(pattern: #"^([ \t]*[-*+][ \t]+\[)([ xX]?)(\])"#)

    /// Flips `[ ]`, `[]`, and `[x]` on the line that contains `location`. Nil if that line is not a checklist item.
    /// `selection` is carried through unchanged, because tapping a box must not move the caret.
    public static func toggleChecklist(in text: String, atLine location: Int, keepingSelection selection: NSRange) -> TextEdit? {
        let source = text as NSString
        guard location >= 0, location <= source.length else { return nil }

        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let line = source.substring(with: lineRange)
        guard let match = checkboxPattern?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let state = match.range(at: 2)
        let current = (line as NSString).substring(with: state)
        let isChecked = current == "x" || current == "X"
        // `[]` has nothing between the brackets, so checking it inserts the `x`.
        return TextEdit(
            range: NSRange(location: lineRange.location + state.location, length: state.length),
            replacement: isChecked ? " " : "x",
            selection: selection
        )
    }
}

extension MarkdownEditing {
    /// Indent/outdent selected list or quote lines without changing their marker or task state.
    public static func indentList(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length,
              selection.length >= 0, selection.length <= source.length - selection.location else { return nil }
        let probe = NSRange(location: selection.location, length: max(0, selection.length - (selection.length > 0 ? 1 : 0)))
        let range = source.lineRange(for: probe)
        let lines = source.substring(with: range) as NSString
        var pieces: [String] = []
        var offset = 0
        var changes: [(location: Int, removed: Int, added: Int)] = []
        while offset < lines.length {
            let lineRange = lines.lineRange(for: NSRange(location: offset, length: 0))
            let line = lines.substring(with: lineRange)
            guard parseListItem(line) != nil else { return nil }
            let removed: Int
            let prefix: String
            if outdent {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                removed = indent.first == "\t" ? 1 : min(4, indent.prefix { $0 == " " }.count)
                prefix = ""
            } else {
                removed = 0
                prefix = "    "
            }
            pieces.append(prefix + (line as NSString).substring(from: removed))
            changes.append((range.location + offset, removed, prefix.utf16.count))
            offset = NSMaxRange(lineRange)
        }
        guard !changes.isEmpty else { return nil }
        func moved(_ position: Int) -> Int {
            var result = position
            for change in changes where position >= change.location {
                result += change.added - min(change.removed, position - change.location)
            }
            return result
        }
        let start = moved(selection.location), end = moved(NSMaxRange(selection))
        return TextEdit(range: range, replacement: pieces.joined(), selection: NSRange(location: start, length: max(0, end - start)))
    }
}
