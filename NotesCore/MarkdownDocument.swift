import Foundation

/// The structure of a note's Markdown: what each line is, and which lines belong together. It is the one place that
/// decides this. The live preview, the layout fragments, and Return handling ask it instead of reading the text again
/// with their own patterns. Pure text in, plain values out, so it can be tested without any UI.
///
/// Every range is UTF-16 and covers whole lines, with their line terminators. The blocks cover the text without gaps
/// or overlap, in order.
public struct MarkdownDocument: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        /// `marker` is the `#` run and the spaces after it.
        case heading(level: Int, marker: NSRange)
        /// `marker` is the `-`, `*` or `+` character.
        case bullet(marker: NSRange)
        /// `mark` is the `- [ ] ` text, including the spaces after it.
        case checklist(mark: NSRange, isChecked: Bool)
        /// `marker` is the `>` and the space after it.
        case quote(marker: NSRange)
        case rule
        case attachment(AttachmentLine)
        /// A fenced block, from its opening fence to its closing fence (or the end of the text when never closed).
        case code(CodeBlock)
        /// A run of table rows.
        case table
    }

    public struct Block: Equatable, Sendable {
        public let kind: Kind
        public let range: NSRange

        /// The lines of the block, each with its terminator.
        public func lines(in text: NSString) -> [NSRange] {
            var lines: [NSRange] = []
            var location = range.location
            while location < NSMaxRange(range) {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                lines.append(line)
                location = NSMaxRange(line)
            }
            return lines
        }
    }

    public let blocks: [Block]
    /// The length of the text this was read from.
    public let length: Int

    public init(_ text: String) {
        let source = text as NSString
        length = source.length

        var blocks: [Block] = []
        let codeBlocks = CodeBlockScanner.scan(text)
        var nextCode = codeBlocks.makeIterator()
        var pendingCode = nextCode.next()
        var location = 0

        while location < source.length {
            if let code = pendingCode, code.whole.location == location {
                blocks.append(Block(kind: .code(code), range: code.whole))
                location = NSMaxRange(code.whole)
                pendingCode = nextCode.next()
                continue
            }

            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let content = source.substring(with: line)
            if Self.kind(ofLine: content, at: line.location) == .paragraph,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               NSMaxRange(line) < source.length {
                let next = source.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
                let underline = source.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = underline.first, first == "=" || first == "-",
                   underline.allSatisfy({ $0 == first }) {
                    blocks.append(Block(kind: .heading(level: first == "=" ? 1 : 2, marker: next),
                                        range: NSUnionRange(line, next)))
                    location = NSMaxRange(next)
                    continue
                }
            }
            if MarkdownEditing.isTableRow(content) {
                // Join the rows that follow, stopping where a fenced block begins.
                var end = NSMaxRange(line)
                while end < source.length, end != pendingCode?.whole.location {
                    let next = source.lineRange(for: NSRange(location: end, length: 0))
                    guard MarkdownEditing.isTableRow(source.substring(with: next)) else { break }
                    end = NSMaxRange(next)
                }
                blocks.append(Block(kind: .table, range: NSRange(location: line.location, length: end - line.location)))
                location = end
            } else {
                blocks.append(Block(kind: Self.kind(ofLine: content, at: line.location), range: line))
                location = NSMaxRange(line)
            }
        }
        self.blocks = blocks
    }

    // MARK: Lookups

    /// The block that contains this character offset. An offset at the very end of the text belongs to the last block.
    public func block(at offset: Int) -> Block? {
        guard !blocks.isEmpty, offset >= 0, offset <= length else { return nil }
        var low = 0, high = blocks.count - 1
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(blocks[middle].range) <= offset { low = middle + 1 } else { high = middle }
        }
        let block = blocks[low]
        return offset < NSMaxRange(block.range) || offset == length ? block : nil
    }

    public var codeBlocks: [CodeBlock] {
        blocks.compactMap { if case .code(let code) = $0.kind { code } else { nil } }
    }

    // MARK: Lines

    private static let headingExpression = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let checklistExpression = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+][ \t]+\[([ xX]?)\](?:[ \t]+|$))"#)
    private static let bulletExpression = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]"#)
    private static let quoteExpression = try? NSRegularExpression(pattern: #"^([ \t]*)(?:>[ \t]?)+"#)
    private static let ruleExpression = try? NSRegularExpression(pattern: #"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)

    /// What one ordinary line is. Code and table lines are found by the caller, which sees their neighbors.
    /// `start` is where the line begins in the text, so the ranges in the result are positions in the text.
    static func kind(ofLine line: String, at start: Int) -> Kind {
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + start, length: range.length) }
        let full = NSRange(location: 0, length: (line as NSString).length)

        if let attachment = AttachmentLine.parse(line) { return .attachment(attachment) }

        let text = line.trimmingCharacters(in: .newlines)
        if ruleExpression?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
            return .rule
        }
        if let match = quoteExpression?.firstMatch(in: line, range: full) {
            return .quote(marker: shifted(match.range))
        }
        if let match = headingExpression?.firstMatch(in: line, range: full) {
            return .heading(level: match.range(at: 1).length, marker: shifted(match.range))
        }
        if let match = checklistExpression?.firstMatch(in: line, range: full) {
            let state = (line as NSString).substring(with: match.range(at: 3))
            return .checklist(mark: shifted(match.range(at: 2)), isChecked: state == "x" || state == "X")
        }
        if let match = bulletExpression?.firstMatch(in: line, range: full) {
            return .bullet(marker: shifted(match.range(at: 2)))
        }
        return .paragraph
    }
}

extension MarkdownDocument {
    /// Ranges use the new text's UTF-16 coordinates. Parsing may examine neighbors that do not need redrawing.
    public struct Update: Sendable {
        public let document: MarkdownDocument
        public let editedRange: NSRange
        public let reparsedRange: NSRange
        public let redrawRange: NSRange
    }

    private init(blocks: [Block], length: Int) {
        self.blocks = blocks
        self.length = length
    }

    /// Applies NSTextStorage's post-edit range and length delta. Complete neighboring blocks provide
    /// context for line joins and table merges. An unclosed fence expands parsing through the suffix.
    public func updating(_ text: String, editedRange: NSRange, changeInLength delta: Int) -> Update {
        let source = text as NSString
        let oldEditLength = editedRange.length - delta
        guard editedRange.location >= 0, editedRange.length >= 0, oldEditLength >= 0,
              editedRange.location <= length, oldEditLength <= length - editedRange.location,
              source.length == length + delta, NSMaxRange(editedRange) <= source.length,
              !blocks.isEmpty else {
            let full = NSRange(location: 0, length: source.length)
            return Update(document: MarkdownDocument(text), editedRange: editedRange, reparsedRange: full, redrawRange: full)
        }

        func index(at offset: Int) -> Int {
            var low = 0, high = blocks.count - 1
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blocks[middle].range) <= offset { low = middle + 1 } else { high = middle }
            }
            return low
        }

        let first = max(0, index(at: editedRange.location) - 1)
        var last = min(blocks.count - 1, index(at: editedRange.location + oldEditLength) + 1)
        let start = blocks[first].range.location
        var end = NSMaxRange(blocks[last].range) + delta
        var parsed = MarkdownDocument(source.substring(with: NSRange(location: start, length: end - start)))
        if end < source.length, case .code(let code) = parsed.blocks.last?.kind, code.close == nil {
            // A new or removed fence can change the interpretation of every following block.
            last = blocks.count - 1
            end = source.length
            parsed = MarkdownDocument(source.substring(from: start))
        }

        let replacement = parsed.blocks.map { $0.shifted(by: start) }
        let suffix = blocks.dropFirst(last + 1).map { $0.shifted(by: delta) }
        let updated = MarkdownDocument(blocks: Array(blocks.prefix(first)) + replacement + suffix, length: source.length)
        let reparsed = NSRange(location: start, length: end - start)

        // Trim unchanged context blocks from the redraw range, but never trim the edit itself.
        var changed = replacement[...]
        var oldFirst = first
        while let block = changed.first, oldFirst <= last,
              NSMaxRange(block.range) <= editedRange.location, block == blocks[oldFirst] {
            changed = changed.dropFirst()
            oldFirst += 1
        }
        var oldLast = last
        while let block = changed.last, oldLast >= oldFirst,
              block.range.location >= NSMaxRange(editedRange), block == blocks[oldLast].shifted(by: delta) {
            changed = changed.dropLast()
            oldLast -= 1
        }
        let redraw: NSRange
        if let firstChanged = changed.first, let lastChanged = changed.last {
            redraw = NSUnionRange(firstChanged.range, lastChanged.range)
        } else {
            redraw = editedRange
        }
        return Update(document: updated, editedRange: editedRange, reparsedRange: reparsed, redrawRange: redraw)
    }
}

private extension MarkdownDocument.Block {
    func shifted(by delta: Int) -> Self {
        guard delta != 0 else { return self }
        func shift(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }
        let shiftedKind: MarkdownDocument.Kind
        switch kind {
        case .heading(let level, let marker): shiftedKind = .heading(level: level, marker: shift(marker))
        case .bullet(let marker): shiftedKind = .bullet(marker: shift(marker))
        case .checklist(let mark, let checked): shiftedKind = .checklist(mark: shift(mark), isChecked: checked)
        case .quote(let marker): shiftedKind = .quote(marker: shift(marker))
        case .code(let code):
            shiftedKind = .code(CodeBlock(open: shift(code.open), close: code.close.map(shift),
                                          whole: shift(code.whole), language: code.language))
        case .paragraph, .rule, .attachment, .table: shiftedKind = kind
        }
        return Self(kind: shiftedKind, range: shift(range))
    }
}

extension MarkdownDocument {
    public struct Container: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case section(level: Int), list, quote }
        public let kind: Kind
        public let range: NSRange
        public let depth: Int
        public let parent: Int?
    }

    /// A separate hierarchy over the source blocks keeps nested structure out of rendering code.
    public func containers(in text: String) -> [Container] {
        let source = text as NSString
        guard source.length == length else { return [] }
        var result: [Container] = []
        var sections: [(level: Int, index: Int)] = []
        var lists: [(indent: Int, index: Int)] = []
        for (blockIndex, block) in blocks.enumerated() {
            if case .heading(let level, _) = block.kind {
                while let last = sections.last, last.level >= level { sections.removeLast() }
                let end = blocks.dropFirst(blockIndex + 1).first {
                    if case .heading(let next, _) = $0.kind { next <= level } else { false }
                }?.range.location ?? length
                result.append(Container(kind: .section(level: level), range: NSRange(location: block.range.location, length: end - block.range.location),
                                        depth: sections.count, parent: sections.last?.index))
                sections.append((level, result.count - 1))
                lists.removeAll()
                continue
            }
            let line = source.substring(with: block.range)
            let numbered = line.range(of: #"^[ \t]*[0-9]+[.)][ \t]+"#, options: .regularExpression) != nil
            let isList: Bool
            switch block.kind { case .bullet, .checklist: isList = true; default: isList = numbered }
            if isList {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                while let last = lists.last, last.indent >= indent { lists.removeLast() }
                result.append(Container(kind: .list, range: block.range, depth: lists.count,
                                        parent: lists.last?.index ?? sections.last?.index))
                lists.append((indent, result.count - 1))
            } else {
                lists.removeAll()
                if case .quote(let marker) = block.kind {
                    let depth = source.substring(with: marker).filter { $0 == ">" }.count
                    result.append(Container(kind: .quote, range: block.range, depth: depth, parent: sections.last?.index))
                }
            }
        }
        return result
    }
}
