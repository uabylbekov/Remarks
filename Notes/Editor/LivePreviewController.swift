import SwiftUI
import NotesCore

// MARK: - Live preview

#if canImport(UIKit)
typealias StorageEditActions = NSTextStorage.EditActions
#else
typealias StorageEditActions = NSTextStorageEditActions
#endif

/// Live preview for a TextKit 2 text view.
/// All styling happens in the content storage delegate, so the stored Markdown text is never modified:
/// selection, copy, undo, and sync always see the real characters.
@MainActor
final class LivePreviewController: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate, NSTextStorageDelegate {
    /// Marks a paragraph as part of a code block, so the layout manager gives it a `CodeBlockFragment`.
    static let blockMarkerKey = NSAttributedString.Key("notes.codeBlock")
    static let headingLevelKey = NSAttributedString.Key("notes.headingLevel")
    static let checklistKey = NSAttributedString.Key("notes.checklist")          // 1 unchecked, 2 checked
    static let checklistWidthKey = NSAttributedString.Key("notes.checklistWidth")
    /// A destination on a link's text, so a tap or click can open it.
    static let linkURLKey = NSAttributedString.Key("notes.linkURL")
    /// Marks a line that has something drawn behind it: "quote" (a bar down the side) or "rule" (a horizontal line).
    static let decorationKey = NSAttributedString.Key("notes.decoration")
    /// On the line of an attachment: the attachment id (a string) and the height reserved for it.
    static let attachmentKey = NSAttributedString.Key("notes.attachment")
    static let attachmentHeightKey = NSAttributedString.Key("notes.attachmentHeight")

    static let codeInset: CGFloat = 12
    /// Combined space beside a table's grid for its native leading and trailing carets.
    static let tableGutter: CGFloat = 16
    /// Space inside the card above the opening fence row and below the closing fence row.
    static let cardPadding: CGFloat = 4
    /// Space outside the card, above and below it. Always the same, whatever the neighboring lines hold, so typing
    /// next to a block never moves anything.
    static let cardMargin: CGFloat = 6
    /// Space between the opening fence row (which shows the language when idle) and the first line of code.
    static let fenceGap: CGFloat = 6

    /// Where one line sits in its block. Asked at draw time (see `CodeBlockFragment`).
    struct BlockRow {
        let isFirst: Bool
        let isLast: Bool
        let isUnclosed: Bool
    }

    /// Where the editor gets the picture or file details for an `attachment://` line.
    var attachmentProvider: ((UUID) -> AttachmentDisplay?)?

    private weak var contentStorage: NSTextContentStorage?
    private weak var layoutManager: NSTextLayoutManager?
    /// The document updates from each edit range. `blocks` is its fenced blocks, kept apart because
    /// every line asks for them while it is styled.
    private var document = MarkdownDocument("")
    private(set) var blocks: [CodeBlock] = []
    /// The table blocks of the document, in order. A table is known by its position in this list.
    private var tables: [MarkdownDocument.Block] = []
    private var tableIDs: [UUID] = []
    private(set) var tableIdentityRevision = 0
    private var parsedText = ""
    /// Each table read as a model, or nil when it is not a complete one. Cleared with the text it was read from.
    private var tableModels: [Int: MarkdownTable?] = [:]
    /// Whether Markdown marks are shown. Off, `#`, `**`, link addresses and the like are hidden once they have taken
    /// effect, and the caret and Backspace treat them as part of the text beside them (see `adjustedSelection`).
    var showsMarkdown = false {
        didSet { if oldValue != showsMarkdown { reload() } }
    }
    /// The text version the caret was last placed for, so a caret that moved because of typing is told from one moved by
    /// the arrow keys.
    private var selectionVersion = 0
    /// Called after styling changes, so a table's view can be placed again once the text has been laid out.
    var onTablesChanged: (() -> Void)?
    /// Writes a change to the text the way typing does, so undo, saving and history all see it.
    var applyTableEdit: ((TextEdit) -> Void)?
    /// Puts the caret in the text view, which also takes the keyboard back from a table.
    var placeCaret: ((NSRange) -> Void)?
    /// The caret came into a table, which is to put it in a cell: its index, then the row and column (-1 is the header).
    var onEnterTable: ((Int, Int, Int) -> Void)?
    /// What the text view has selected. A caret is a selection of length 0. Set only by `selectionChanged(to:)`.
    private var selection = NSRange(location: 0, length: 0)
    /// Increases with every change to the text. Tokens are cached against it.
    private var version = 0
    private var tokenCache: [Int: [SyntaxToken]] = [:]
    private var pendingRedraw: NSRange?
    private var redrawScheduled = false
    /// How each table is laid out, by the position of its first row, so every row of one table uses the same size and
    /// column widths. Cleared with `tokenCache`, so it never outlives the text it was measured from.
    private var tableLayouts: [Int: TableLayout] = [:]

    init(contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        self.contentStorage = contentStorage
        self.layoutManager = layoutManager
        super.init()
        contentStorage.delegate = self
        layoutManager.delegate = self
        rescan(contentStorage.textStorage?.string ?? "")

        // Refresh the block list as the text changes, before the text engine lays the edited lines out. Doing it any
        // later styles them from a stale list, and then every line has to be styled again.
        contentStorage.textStorage?.delegate = self
    }

    // MARK: Updates from the text view

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: StorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let storage = textStorage
        version &+= 1
        let previousBlocks = blocks
        let previousTokens = tokenCache
        tableLayouts.removeAll()
        let redraw = rescan(storage.string, editedRange: editedRange, delta: delta) ?? editedRange
        retainSyntaxTokens(previousTokens, blocks: previousBlocks, editedRange: editedRange, delta: delta)
        onTablesChanged?()

        // Pending ranges were measured against the previous text. A second edit before this task runs
        // conservatively redraws the document rather than applying stale offsets.
        if pendingRedraw != nil {
            pendingRedraw = NSRange(location: 0, length: storage.length)
        } else {
            pendingRedraw = redraw
        }
        guard !redrawScheduled else { return }
        redrawScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            guard let range = self.pendingRedraw else { return }
            self.pendingRedraw = nil
            self.invalidate([range])
        }
    }

    private func retainSyntaxTokens(_ previous: [Int: [SyntaxToken]], blocks oldBlocks: [CodeBlock],
                                    editedRange: NSRange, delta: Int) {
        tokenCache.removeAll()
        let oldEnd = editedRange.location + editedRange.length - delta
        for block in oldBlocks {
            guard let tokens = previous[block.open.location] else { continue }
            let shift: Int
            if NSMaxRange(block.whole) <= editedRange.location {
                shift = 0
            } else if block.whole.location >= oldEnd {
                shift = delta
            } else {
                continue
            }
            let range = NSRange(location: block.whole.location + shift, length: block.whole.length)
            guard blocks.contains(where: { $0.whole == range && $0.language == block.language
                && ($0.close?.location ?? -1) == (block.close.map { $0.location + shift } ?? -1) }) else { continue }
            tokenCache[block.open.location + shift] = tokens.map {
                SyntaxToken(scope: $0.scope, range: NSRange(location: $0.range.location + shift, length: $0.range.length))
            }
        }
    }

    @discardableResult
    private func rescan(_ text: String, editedRange: NSRange? = nil, delta: Int = 0) -> NSRange? {
        let previousTables = tables
        let previousIDs = tableIDs
        let update = editedRange.map { document.updating(text, editedRange: $0, changeInLength: delta) }
        document = update?.document ?? MarkdownDocument(text)
        blocks = document.codeBlocks
        let source = text as NSString
        tables = document.blocks.filter { block in
            guard case .table = block.kind else { return false }
            return MarkdownTable(parsing: source.substring(with: block.range)) != nil
        }
        if editedRange != nil || text != parsedText {
            let sameTables: Bool
            if let editedRange {
                let oldEditEnd = editedRange.location + editedRange.length - delta
                let expectedRanges = previousTables.map { table -> NSRange? in
                    let range = table.range
                    if NSMaxRange(range) <= editedRange.location { return range }
                    if range.location >= oldEditEnd {
                        return NSRange(location: range.location + delta, length: range.length)
                    }
                    if range.location <= editedRange.location, NSMaxRange(range) >= oldEditEnd {
                        return NSRange(location: range.location, length: range.length + delta)
                    }
                    return nil
                }
                sameTables = expectedRanges.count == tables.count
                    && zip(expectedRanges, tables).allSatisfy { $0.0 == $0.1.range }
            } else {
                // A replacement whose correspondence is unknown must not reuse focused table hosts.
                sameTables = false
            }
            if !sameTables { tableIdentityRevision &+= 1 }
        }
        if let editedRange {
            let oldEnd = editedRange.location + editedRange.length - delta
            var available = Set(previousTables.indices)
            tableIDs = tables.map { table in
                let match = available.first { index in
                    let range = previousTables[index].range
                    let expected: NSRange?
                    if NSMaxRange(range) <= editedRange.location {
                        expected = range
                    } else if range.location >= oldEnd {
                        expected = NSRange(location: range.location + delta, length: range.length)
                    } else if range.location <= editedRange.location, NSMaxRange(range) >= oldEnd {
                        expected = NSRange(location: range.location, length: range.length + delta)
                    } else {
                        expected = nil
                    }
                    return expected == table.range
                }
                if let match, previousIDs.indices.contains(match) {
                    available.remove(match)
                    return previousIDs[match]
                }
                return UUID()
            }
        } else if text != parsedText || tableIDs.count != tables.count {
            // For replacements from sync, preserve only unambiguous, unchanged table contents.
            let oldSource = parsedText as NSString
            let newSource = text as NSString
            let oldStrings = previousTables.map { oldSource.substring(with: $0.range) }
            let newStrings = tables.map { newSource.substring(with: $0.range) }
            tableIDs = newStrings.map { value in
                if oldStrings.filter({ $0 == value }).count == 1,
                   newStrings.filter({ $0 == value }).count == 1,
                   let index = oldStrings.firstIndex(of: value), previousIDs.indices.contains(index) {
                    return previousIDs[index]
                }
                return UUID()
            }
        }
        parsedText = text
        tableModels.removeAll()
        return update?.redrawRange
    }

    /// All the rows of the table that `line` belongs to, or nil if the line is not a table row.
    private func tableRun(containing line: NSRange, in source: NSString) -> NSRange? {
        guard MarkdownEditing.isTableRow(source.substring(with: line)) else { return nil }
        var start = line
        var end = line
        while start.location > 0 {
            let previous = source.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard MarkdownEditing.isTableRow(source.substring(with: previous)) else { break }
            start = previous
        }
        while NSMaxRange(end) < source.length {
            let next = source.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            guard MarkdownEditing.isTableRow(source.substring(with: next)) else { break }
            end = next
        }
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    /// Call after text is replaced programmatically (a different note, or a sync update), or when settings change.
    func reload() {
        guard let storage = contentStorage?.textStorage else { return }
        version &+= 1
        // A note loaded or styled again is not an edit the caret has to catch up with.
        selectionVersion = version
        tokenCache.removeAll()
        pendingRedraw = nil
        tableLayouts.removeAll()
        rescan(storage.string)
        selection = clamped(selection, in: storage)
        invalidate([NSRange(location: 0, length: storage.length)])
    }

    func selectionChanged(to range: NSRange) {
        guard let storage = contentStorage?.textStorage else { return }
        // The ranges are measured against the text as it is now, so a deleted tail can never leave a stale one behind.
        let previous = clamped(selection, in: storage)
        selection = clamped(range, in: storage)
        guard previous != selection else { return }

        // Only horizontal rules change with focus. Code fences keep the same layout and visibility.
        let before = affectedRanges(of: previous, in: storage)
        let after = affectedRanges(of: selection, in: storage)
        let stale = before.filter { !after.contains($0) } + after.filter { !before.contains($0) }
        if !stale.isEmpty { invalidate(stale) }
        // Synchronize table hosts after selection-driven navigation.
        if !tables.isEmpty { onTablesChanged?() }
    }

    private func clamped(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        let location = min(range.location, storage.length)
        return NSRange(location: location, length: min(range.length, storage.length - location))
    }

    /// Independently styled paragraphs whose appearance depends on selection.
    private func affectedRanges(of selection: NSRange, in storage: NSTextStorage) -> [NSRange] {
        let lines = lineRange(of: selection, in: storage)
        let ranges = document.blocks.compactMap { block -> NSRange? in
            guard case .rule = block.kind, NSIntersectionRange(block.range, lines).length > 0 else { return nil }
            return block.range
        }
        return ranges
    }

    /// Whether `inner` lies entirely within `outer`.
    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// True when `location` is inside a fenced block. Return and list continuation must leave code alone.
    func isInCodeBlock(_ location: Int) -> Bool {
        guard let storage = contentStorage?.textStorage else { return false }
        return activeBlock(at: location, in: storage) != nil
    }

    /// The whole lines a selection touches. A caret after a final newline is on the empty line below it, not on the
    /// line above (see `isLineActive`).
    private func lineRange(of selection: NSRange, in storage: NSTextStorage) -> NSRange {
        let source = storage.string as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        if selection.length > 0 { return source.lineRange(for: selection) }
        if selection.location >= source.length, source.character(at: source.length - 1) == 10 {
            return NSRange(location: source.length, length: 0)
        }
        return source.lineRange(for: NSRange(location: min(selection.location, source.length - 1), length: 0))
    }

    /// Re-runs the paragraph delegate for these ranges without changing any characters.
    private func invalidate(_ ranges: [NSRange]) {
        guard let contentStorage, let storage = contentStorage.textStorage else { return }
        contentStorage.performEditingTransaction {
            for range in ranges {
                let visible = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
                if visible.length > 0 { storage.edited(.editedAttributes, range: visible, changeInLength: 0) }
            }
        }
        onTablesChanged?()
    }

    // MARK: Active region

    /// The block the caret is in, if any. A caret on the empty line after a closed block's last newline is below the
    /// block. After an open block's newline it is on the block's next line of code.
    private func activeBlock(at location: Int, in storage: NSTextStorage) -> CodeBlock? {
        let length = storage.length
        let text = storage.string as NSString
        return blocks.first { block in
            let end = NSMaxRange(block.whole)
            if location >= block.whole.location && location < end { return true }
            guard location == end, end == length else { return false }
            return block.close == nil || text.character(at: length - 1) != 10
        }
    }

    /// A block is active when the selection touches it, or the caret is in it.
    private func isActive(_ block: CodeBlock, selection: NSRange, in storage: NSTextStorage) -> Bool {
        // A selection that reaches beyond the block (Select All, or a drag across several lines) is not editing it.
        if selection.length > 0 { return Self.contains(block.whole, selection) }
        return activeBlock(at: selection.location, in: storage) == block
    }

    /// The selection touches this line. A caret at the very end of the text belongs to the last line, but not when that line
    /// ends with a newline: then the caret is on the empty line after it.
    private func isLineActive(_ range: NSRange, in storage: NSTextStorage, selection given: NSRange? = nil) -> Bool {
        let selection = given ?? self.selection
        // Only a selection inside this line means it is being edited. One that spans lines (Select All) leaves every
        // line as it looks at rest, so the checkboxes stay checkboxes.
        if selection.length > 0 { return Self.contains(range, selection) }
        let caret = selection.location
        let lineEnd = NSMaxRange(range)
        guard caret >= range.location else { return false }
        if caret < lineEnd { return true }
        guard caret == lineEnd, lineEnd == storage.length, lineEnd > 0 else { return false }
        return (storage.string as NSString).character(at: lineEnd - 1) != 10
    }

    /// Where the line that starts a layout element sits in its block, or nil if it is not in a block.
    func blockRow(for element: NSTextElement?) -> BlockRow? {
        guard let location = element?.elementRange?.location, let contentStorage,
              let storage = contentStorage.textStorage else { return nil }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        // A table row is drawn on the same card as a line of code, so both ask the same question.
        guard let block = blocks.first(where: { NSLocationInRange(offset, $0.whole) }) else {
            return tableRow(for: element).map { BlockRow(isFirst: $0.isFirst, isLast: $0.isLast, isUnclosed: false) }
        }

        let lastLine: Int
        if let close = block.close {
            lastLine = close.location
        } else if block.body.length > 0 {
            lastLine = (storage.string as NSString).lineRange(for: NSRange(location: NSMaxRange(block.body) - 1, length: 0)).location
        } else {
            lastLine = block.open.location
        }
        return BlockRow(isFirst: offset == block.open.location, isLast: offset == lastLine, isUnclosed: block.close == nil)
    }

    // MARK: NSTextContentStorageDelegate

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, range.length > 0,
              let block = document.block(at: range.location), NSLocationInRange(range.location, block.range) else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        if showsMarkdown {
            paragraph.addAttributes([.font: EditorTheme.codeFont, .foregroundColor: EditorTheme.codeTextColor,
                                     .paragraphStyle: EditorTheme.bodyParagraphStyle],
                                    range: NSRange(location: 0, length: paragraph.length))
            return NSTextParagraph(attributedString: paragraph)
        }
        let line = ElementLine(range: range, block: block, isActive: isLineActive(range, in: storage))
        // The document says what kind of line this is, and that kind's element says how it looks.
        let element = MarkdownElements.element(for: block.kind)
        return element.style(paragraph, line: line, services: self) ? NSTextParagraph(attributedString: paragraph) : nil
    }

    // MARK: Code blocks

    private func syntaxTokens(for block: CodeBlock, in storage: NSTextStorage) -> [SyntaxToken] {
        if let cached = tokenCache[block.open.location] { return cached }
        var tokens: [SyntaxToken] = []
        if block.body.length > 0, block.body.length <= CodeBlockElement.highlightLimit,
           let engine = SyntaxGrammars.engine(forLanguage: block.language) {
            tokens = engine.tokens(in: storage.string, range: block.body).sorted { $0.range.location < $1.range.location }
        }
        tokenCache[block.open.location] = tokens
        return tokens
    }

    func tableID(at index: Int) -> UUID? {
        tableIDs.indices.contains(index) ? tableIDs[index] : nil
    }

    func tableIndex(for id: UUID) -> Int? { tableIDs.firstIndex(of: id) }

    // MARK: Table grids

    /// What the table view needs to be placed: which table, what it holds, and where it goes (text container coordinates).
    struct GridTable {
        let id: UUID
        let index: Int
        let table: MarkdownTable
        let frame: CGRect
    }

    private func tableModel(at index: Int, in storage: NSTextStorage) -> MarkdownTable? {
        if let known = tableModels[index] { return known }
        let model = MarkdownTable(parsing: (storage.string as NSString).substring(with: tables[index].range))
        tableModels[index] = .some(model)
        return model
    }

    /// The table that a line belongs to, when it is shown as a grid. That is every complete table, whatever the caret
    /// does: the rows are never shown as text. A table without a separator row is not complete, and stays text.
    private func gridTable(at offset: Int, in storage: NSTextStorage) -> (index: Int, block: MarkdownDocument.Block, table: MarkdownTable)? {
        guard !showsMarkdown, let index = tables.firstIndex(where: { NSLocationInRange(offset, $0.range) }),
              let table = tableModel(at: index, in: storage) else { return nil }
        return (index, tables[index], table)
    }

    /// Where each grid table goes. Only tables shown as grids are listed. A table whose text has not been laid out is left
    /// out, unless `forcingLayout` asks for it to be laid out now. The text view lays out a screenful at a time, and
    /// asking for layout from inside its own layout pass is not allowed, so the overlay places what is already there, in
    /// the same pass, and the table moves with the text.
    func gridTables(forcingLayout: Bool = false) -> [GridTable] {
        guard let layoutManager, let contentStorage, let storage = contentStorage.textStorage,
              let container = layoutManager.textContainer else { return [] }
        let padding = container.lineFragmentPadding
        var result: [GridTable] = []
        for index in tables.indices {
            guard let grid = gridTable(at: tables[index].range.location, in: storage),
                  let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: tables[index].range.location)
            else { continue }
            let fragment: NSTextLayoutFragment?
            if forcingLayout {
                fragment = layoutManager.textLayoutFragment(for: location)
            } else {
                var found: NSTextLayoutFragment?
                layoutManager.enumerateTextLayoutFragments(from: location, options: []) { candidate in
                    if candidate.rangeInElement.location.compare(location) == .orderedSame, candidate.state == .layoutAvailable {
                        found = candidate
                    }
                    return false
                }
                fragment = found
            }
            guard let fragment else { continue }
            let frame = CGRect(
                x: padding + Self.tableGutter / 2,
                y: fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0),
                width: TableGridView.width(for: grid.table, in: container.size.width, padding: padding, gutter: Self.tableGutter),
                height: TableGridView.height(for: grid.table)
            )
            result.append(GridTable(id: tableIDs[index], index: index, table: grid.table, frame: frame))
        }
        return result
    }

    /// Writes a changed table back into the text. The caret stays where it was, outside the table, so the table keeps
    /// showing as a grid while it is being edited.
    func replaceTable(at index: Int, with table: MarkdownTable) {
        guard tables.indices.contains(index), let storage = contentStorage?.textStorage else { return }
        var range = tables[index].range
        // The last row's line break belongs to the line after the table, not to the table.
        let source = storage.string as NSString
        while range.length > 0, [10, 13].contains(source.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }

        let replacement = table.markdown()
        var caret = clamped(selection, in: storage)
        if caret.location >= NSMaxRange(range) { caret.location += (replacement as NSString).length - range.length }
        applyTableEdit?(TextEdit(range: range, replacement: replacement, selection: caret))
    }

    // MARK: Hidden Markdown

    /// The marks on a line that are hidden: the `#` of a heading, the `>` of a quote, the `- [ ] ` in front of a
    /// checkbox, and the marks around bold, italic, code and links. Nothing is hidden while Markdown is shown.
    private func hiddenRanges(inLine line: NSRange, in storage: NSTextStorage) -> [NSRange] {
        guard !showsMarkdown, line.length > 0, let block = document.block(at: line.location),
              NSLocationInRange(line.location, block.range) else { return [] }
        let element = MarkdownElements.element(for: block.kind)
        var hidden = element.hiddenMarks(of: block, line: line, in: storage.string as NSString)
        if element.readsInline {
            let text = (storage.string as NSString).substring(with: line)
            for span in InlineScanner.spans(in: text) {
                for marker in span.markers {
                    hidden.append(NSRange(location: line.location + marker.location, length: marker.length))
                }
            }
        }
        return hidden
    }

    /// The positions that look the same, because only hidden characters lie between them. A caret anywhere in one is
    /// drawn in the same place, so they count as one position.
    private func visualClass(containing position: Int, hidden: [NSRange]) -> NSRange {
        var low = position, high = position
        var grew = true
        while grew {
            grew = false
            for range in hidden where range.location <= high && NSMaxRange(range) >= low {
                if range.location < low { low = range.location; grew = true }
                if NSMaxRange(range) > high { high = NSMaxRange(range); grew = true }
            }
        }
        return NSRange(location: low, length: high - low)
    }

    private func composedLength(at location: Int, in source: NSString) -> Int {
        location < source.length ? source.rangeOfComposedCharacterSequence(at: location).length : 0
    }

    private func composedLength(before location: Int, in source: NSString) -> Int {
        location > 0 ? source.rangeOfComposedCharacterSequence(at: location - 1).length : 0
    }

    /// Normalize a source-mode caret without interpreting it as an arrow key or changing document text.
    func selectionForPreview(_ range: NSRange) -> NSRange {
        guard let storage = contentStorage?.textStorage else { return range }
        let range = clamped(range, in: storage)
        guard !showsMarkdown, range.length == 0 else { return range }
        let source = storage.string as NSString
        if let block = document.block(at: range.location), case .table = block.kind,
           tables.contains(where: { $0.range == block.range }), range.location < NSMaxRange(block.range) {
            let location = range.location == block.range.location ? range.location : tableCaretPosition(of: block, in: source)
            return NSRange(location: location, length: 0)
        }
        let line = source.lineRange(for: range)
        let spot = visualClass(containing: range.location, hidden: hiddenRanges(inLine: line, in: storage))
        // A native attachment has two visible boundaries; preserve its leading edge.
        if let block = document.block(at: range.location), case .attachment = block.kind,
           range.location == block.range.location { return range }
        return spot.length > 0 ? NSRange(location: NSMaxRange(spot), length: 0) : range
    }

    /// The caret must not rest in Markdown that cannot be seen: a hidden mark, the rows of a table. It always sits just
    /// before a visible character, so what is typed takes that character's style. Returns where it goes instead, or nil
    /// when it is fine where it is. An arrow key that would move the caret from one place to where it already looks to
    /// be steps over the hidden mark and one visible character, so no key press seems to do nothing.
    func adjustedSelection(to new: NSRange) -> NSRange? {
        guard !showsMarkdown, new.length == 0, let storage = contentStorage?.textStorage else { return nil }
        let source = storage.string as NSString
        let caret = min(new.location, source.length)
        let edited = version != selectionVersion
        selectionVersion = version

        if let block = document.block(at: caret), case .attachment = block.kind,
           let mark = linePrefixMark(of: block, in: source) {
            let leading = mark.location
            let trailing = NSMaxRange(mark)
            if caret == leading || caret == trailing { return nil }
            if caret > leading, caret < trailing {
                let target = !edited && selection.length == 0 && selection.location == trailing ? leading : trailing
                return NSRange(location: target, length: 0)
            }
        }

        // The end of the text belongs to the last block, but a caret on the empty line after a table's line break is
        // below the table, not in it.
        if let block = document.block(at: caret), case .table = block.kind,
           tables.contains(where: { $0.range == block.range }) {
            let end = NSMaxRange(block.range)
            let isInside = caret < end || (caret == end && end > 0 && source.character(at: end - 1) != 10)
            let restingPlace = tableCaretPosition(of: block, in: source)
            if caret == restingPlace || caret == block.range.location { return nil }
            if !edited, selection.length == 0, selection.location == block.range.location,
               caret > selection.location, isInside,
               let index = tables.firstIndex(where: { $0.range == block.range }) {
                onEnterTable?(index, -1, 0)
                return selection
            }
            // Anywhere in the first row after its first character is the end of the table: a click beside the grid can land
            // there. Left from the end of the table goes into the last cell.
            if caret > block.range.location, caret < restingPlace {
                let previous = clamped(selection, in: storage)
                if !edited, previous.length == 0, previous.location == restingPlace,
                   let index = tables.firstIndex(where: { $0.range == block.range }),
                   let table = tableModel(at: index, in: storage) {
                    onEnterTable?(index, table.rows.count - 1, table.columnCount - 1)
                    return previous
                }
                return NSRange(location: restingPlace, length: 0)
            }
            if isInside {
                // Down from the caret at the end of a table leaves the table, as it would past any other block.
                if !edited, selection.length == 0, selection.location == restingPlace, caret > selection.location {
                    if end == source.length, end > 0, source.character(at: end - 1) != 10 {
                        Task { @MainActor [weak self] in self?.ensureLineAfterTable() }
                        return selection
                    }
                    return NSRange(location: end, length: 0)
                }
                // The caret at the very end of a note that ends with a table is below the table, not in it: the click or
                // the key was for the place after it. There is no line there yet, so one is added.
                if caret == source.length, end == source.length, caret > 0, source.character(at: end - 1) != 10 {
                    Task { @MainActor [weak self] in self?.ensureLineAfterTable() }
                    return nil
                }
                // An arrow key or a click that brings the caret into a table puts it in a cell instead, and the text view's
                // own caret stays where it was. The way in decides which cell: down gets the first, up the last.
                let previous = clamped(selection, in: storage)
                if !edited, caret != previous.location, previous.length == 0,
                   let index = tables.firstIndex(where: { $0.range == block.range }),
                   let table = tableModel(at: index, in: storage) {
                    let entersFromAbove = caret >= previous.location
                    onEnterTable?(index, entersFromAbove ? -1 : table.rows.count - 1, entersFromAbove ? 0 : table.columnCount - 1)
                    return previous
                }
                if caret >= selection.location || block.range.location == 0 {
                    // A table that ends the text has no line after it to put the caret on, so one is added. Not now:
                    // this runs while the text view is still working on the change that moved the caret.
                    if end == source.length, source.character(at: end - 1) != 10 {
                        Task { @MainActor [weak self] in self?.ensureLineAfterTable() }
                        return nil
                    }
                    return end == caret ? nil : NSRange(location: end, length: 0)
                }
                return NSRange(location: block.range.location - 1, length: 0)
            }
        }

        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let hidden = hiddenRanges(inLine: line, in: storage)
        guard !hidden.isEmpty else { return nil }
        let spot = visualClass(containing: caret, hidden: hidden)
        guard spot.length > 0 else { return nil }

        var target = NSMaxRange(spot)
        let previous = selection.location
        if !edited, caret != previous, spot == visualClass(containing: previous, hidden: hidden) {
            if caret > previous {
                target += composedLength(at: target, in: source)
            } else if spot.location > 0 {
                target = spot.location - composedLength(before: spot.location, in: source)
            }
        }
        return target == caret ? nil : NSRange(location: target, length: 0)
    }

    /// Only the gutters belong to the outer editor; cells keep their own native selection.
    func tableBoundary(at point: CGPoint) -> NSRange? {
        guard !showsMarkdown, let storage = contentStorage?.textStorage else { return nil }
        for grid in gridTables() where point.y >= grid.frame.minY && point.y <= grid.frame.maxY {
            let gutter = Self.tableGutter / 2
            if point.x >= grid.frame.minX - gutter && point.x < grid.frame.minX {
                return NSRange(location: tables[grid.index].range.location, length: 0)
            }
            if point.x > grid.frame.maxX && point.x <= grid.frame.maxX + gutter {
                return NSRange(location: tableCaretPosition(of: tables[grid.index], in: storage.string as NSString), length: 0)
            }
        }
        return nil
    }

    /// The card's outer edges place a caret; its interior retains attachment selection/opening.
    func elementBoundary(at point: CGPoint) -> NSRange? {
        if let boundary = tableBoundary(at: point) { return boundary }
        guard !showsMarkdown, let layoutManager, let contentStorage,
              let storage = contentStorage.textStorage else { return nil }
        let padding = layoutManager.textContainer?.lineFragmentPadding ?? 5
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: padding, y: point.y)) as? AttachmentFragment,
              let location = fragment.textElement?.elementRange?.location else { return nil }
        let rect = fragment.attachmentBounds
        guard point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard let block = document.block(at: offset), let mark = linePrefixMark(of: block, in: storage.string as NSString) else { return nil }
        if point.x >= rect.minX - 8, point.x <= rect.minX {
            return NSRange(location: mark.location, length: 0)
        }
        if point.x >= rect.maxX, point.x <= rect.maxX + 8 {
            return NSRange(location: NSMaxRange(mark), length: 0)
        }
        return nil
    }

    /// Where the caret rests "at the end of a table": the end of its first row, which is drawn at the right edge, in the
    /// gutter beside the grid, as tall as the table (see `TableElement`). The other resting position is the start of the block.
    private func tableCaretPosition(of block: MarkdownDocument.Block, in source: NSString) -> Int {
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: source.lineRange(for: NSRange(location: block.range.location, length: 0)))
        return contentsEnd
    }

    /// The caret is at the end of a table, and something is typed. It goes on the line after the table, not into the
    /// table's first row: a new line is made for it if the next one has text. Returns nil when the caret is elsewhere.
    func redirectedInsert(_ text: String, at selection: NSRange) -> TextEdit? {
        guard !showsMarkdown, !text.isEmpty, selection.length == 0, let storage = contentStorage?.textStorage,
              let block = document.block(at: selection.location) else { return nil }
        let source = storage.string as NSString
        let trailing: Int
        switch block.kind {
        case .attachment:
            guard let mark = linePrefixMark(of: block, in: source) else { return nil }
            trailing = NSMaxRange(mark)
        case .table:
            guard tables.contains(where: { $0.range == block.range }) else { return nil }
            trailing = tableCaretPosition(of: block, in: source)
        case .code(let code):
            guard let close = code.close else { return nil }
            var end = 0
            source.getLineStart(nil, end: nil, contentsEnd: &end, for: close)
            guard selection.location == end else { return nil }
            trailing = end
        default: return nil
        }
        if selection.location == block.range.location {
            let prefix = text.hasSuffix("\n") ? text : text + "\n"
            return TextEdit(range: NSRange(location: block.range.location, length: 0), replacement: prefix,
                            selection: NSRange(location: block.range.location + (text == "\n" ? 0 : (text as NSString).length), length: 0))
        }
        guard selection.location == trailing else { return nil }

        let end = NSMaxRange(block.range)
        let length = (text as NSString).length
        // A table that ends the text has no line after it yet.
        if end == source.length, end > 0, source.character(at: end - 1) != 10 {
            return TextEdit(range: NSRange(location: end, length: 0), replacement: "\n" + text, selection: NSRange(location: end + 1 + length, length: 0))
        }
        if text == "\n" {
            return TextEdit(range: NSRange(location: end, length: 0), replacement: "\n", selection: NSRange(location: end, length: 0))
        }
        let nextLineHasText = end < source.length && source.character(at: end) != 10
        return TextEdit(
            range: NSRange(location: end, length: 0),
            replacement: nextLineHasText ? text + "\n" : text,
            selection: NSRange(location: end + length, length: 0)
        )
    }

    /// Gives a table that ends the text a line below it, for the caret.
    private func ensureLineAfterTable() {
        guard !showsMarkdown else { return }
        guard let storage = contentStorage?.textStorage, let table = tables.last else { return }
        let source = storage.string as NSString
        let end = NSMaxRange(table.range)
        guard end == source.length, end > 0, source.character(at: end - 1) != 10 else { return }
        applyTableEdit?(TextEdit(range: NSRange(location: end, length: 0), replacement: "\n", selection: NSRange(location: end + 1, length: 0)))
    }

    enum BackspaceAction {
        /// Nothing special: the text view deletes as usual.
        case normal
        /// Do nothing, because there is nothing to delete.
        case ignore
        case edit(TextEdit)
    }

    /// The mark in front of a line that Backspace takes away to turn the line back into plain text.
    private func linePrefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange? {
        MarkdownElements.element(for: block.kind).prefixMark(of: block, in: source)
    }

    /// What Backspace does with the caret at `caret`. It deletes the visible character before the caret, never a hidden
    /// mark. At the start of a heading, quote or checklist item it takes the mark away and keeps the text. At the start
    /// of the line after a table it moves to the trailing edge before another Backspace removes the table.
    func backspace(at caret: Int) -> BackspaceAction {
        guard !showsMarkdown else { return .normal }
        guard let storage = contentStorage?.textStorage else { return .normal }
        let source = storage.string as NSString

        if let block = document.block(at: caret), case .attachment = block.kind, caret == block.range.location {
            return .ignore
        }

        // Joining the preceding line into a table would damage its header.
        if tables.contains(where: { $0.range.location == caret }) { return .ignore }

        // Arriving from the line after a table first places the tall caret at its trailing edge.
        if let block = tables.first(where: { NSMaxRange($0.range) == caret && caret > 0 }) {
            return .edit(TextEdit(range: NSRange(location: caret, length: 0), replacement: "",
                                  selection: NSRange(location: tableCaretPosition(of: block, in: source), length: 0)))
        }
        // A second Backspace at that edge removes the table as one undoable edit.
        if let block = tables.first(where: { caret == tableCaretPosition(of: $0, in: source) }) {
            return .edit(TextEdit(range: block.range, replacement: "", selection: NSRange(location: block.range.location, length: 0)))
        }

        // Deletion at a hidden fence moves past its syntax instead of joining it to code or prose.
        if let block = document.block(at: caret), case .code(let code) = block.kind {
            let line = source.lineRange(for: NSRange(location: caret, length: 0))
            let hidden = CodeBlockElement().hiddenMarks(of: block, line: line, in: source).first
            if let hidden, caret >= hidden.location, caret <= NSMaxRange(hidden) {
                guard line.location > 0 else { return .ignore }
                var end = 0
                source.getLineStart(nil, end: nil, contentsEnd: &end,
                                    for: NSRange(location: line.location - 1, length: 0))
                // With no body, go to the language row rather than consuming a fence character.
                // The opening fence has nothing of the block before it, so Backspace goes to the end of the previous line.
                let target = line.location == code.open.location ? end : max(code.open.location, end)
                return .edit(TextEdit(range: NSRange(location: caret, length: 0), replacement: "",
                                      selection: NSRange(location: target, length: 0)))
            }
        }

        if let block = document.block(at: caret), case .heading(_, let underline) = block.kind,
           caret == block.range.location, underline.location > block.range.location {
            return .edit(TextEdit(range: underline, replacement: "", selection: NSRange(location: caret, length: 0)))
        }

        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let spot = visualClass(containing: caret, hidden: hiddenRanges(inLine: line, in: storage))
        guard spot.length > 0 else { return .normal }

        if spot.location == line.location {
            if let block = document.block(at: line.location), let mark = linePrefixMark(of: block, in: source) {
                return .edit(TextEdit(range: mark, replacement: "", selection: NSRange(location: mark.location, length: 0)))
            }
            guard spot.location > 0 else { return .ignore }
        }
        let length = composedLength(before: spot.location, in: source)
        let range = NSRange(location: spot.location - length, length: length)
        return .edit(TextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0)))
    }

    /// What the forward delete key does: it deletes the visible character after the caret, stepping over hidden marks.
    func deleteForward(at caret: Int) -> BackspaceAction {
        guard !showsMarkdown else { return .normal }
        guard let storage = contentStorage?.textStorage else { return .normal }
        let source = storage.string as NSString
        let line = source.lineRange(for: NSRange(location: caret, length: 0))

        if let block = document.block(at: caret), case .attachment = block.kind,
           let mark = linePrefixMark(of: block, in: source) {
            if caret == mark.location {
                return .edit(TextEdit(range: block.range, replacement: "", selection: NSRange(location: caret, length: 0)))
            }
            if caret == NSMaxRange(mark) { return .ignore }
        }

        if let block = document.block(at: caret), case .code(let code) = block.kind,
           let close = code.close, caret >= close.location, caret < NSMaxRange(close) {
            let target = NSMaxRange(close)
            return target == source.length && source.character(at: target - 1) != 10 ? .ignore
                : .edit(TextEdit(range: NSRange(location: caret, length: 0), replacement: "",
                                 selection: NSRange(location: target, length: 0)))
        }

        if let table = tables.first(where: { $0.range.location == caret }) {
            return .edit(TextEdit(range: table.range, replacement: "", selection: NSRange(location: caret, length: 0)))
        }

        // At the end of a table there is nothing after the caret to delete.
        if tables.contains(where: { caret == tableCaretPosition(of: $0, in: source) }) { return .ignore }

        // Forward delete at the end of the line above a table removes the table, as joining it would break it.
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        if caret == contentsEnd, contentsEnd > line.location, let table = tables.first(where: { $0.range.location == NSMaxRange(line) }) {
            return .edit(TextEdit(range: table.range, replacement: "", selection: NSRange(location: caret, length: 0)))
        }

        let spot = visualClass(containing: caret, hidden: hiddenRanges(inLine: line, in: storage))
        guard spot.length > 0 else { return .normal }

        let end = NSMaxRange(spot)
        let length = composedLength(at: end, in: source)
        guard length > 0 else { return .ignore }
        return .edit(TextEdit(range: NSRange(location: end, length: length), replacement: "", selection: NSRange(location: end, length: 0)))
    }

    /// The caret leaves a table with the keyboard: it goes to the end of the line above, or to the line below.
    func exitTable(at index: Int, toward exit: TableExit) {
        guard tables.indices.contains(index), let storage = contentStorage?.textStorage else { return }
        let source = storage.string as NSString
        let block = tables[index]
        let end = NSMaxRange(block.range)

        // Out of the top goes to the line above. Out of the bottom goes to the end of the table, the tall caret in the gutter,
        // from where Down goes on to the line below.
        var location = tableCaretPosition(of: block, in: source)
        if exit == .before { location = block.range.location }
        placeCaret?(NSRange(location: location, length: 0))
    }

    /// Removes a table and its line break.
    func deleteTable(at index: Int) {
        guard tables.indices.contains(index) else { return }
        let range = tables[index].range
        applyTableEdit?(TextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0)))
    }

    // MARK: Tables

    /// Where the table row that starts a layout element sits in its table, or nil if it is not in one.
    func tableRow(for element: NSTextElement?) -> (isFirst: Bool, isLast: Bool)? {
        guard let location = element?.elementRange?.location, let contentStorage,
              let storage = contentStorage.textStorage else { return nil }
        let source = storage.string as NSString
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard offset < source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: offset, length: 0))
        guard MarkdownEditing.isTableRow(source.substring(with: line)) else { return nil }

        var isFirst = true
        if line.location > 0 {
            let previous = source.lineRange(for: NSRange(location: line.location - 1, length: 0))
            isFirst = !MarkdownEditing.isTableRow(source.substring(with: previous))
        }
        var isLast = true
        if NSMaxRange(line) < source.length {
            let next = source.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            isLast = !MarkdownEditing.isTableRow(source.substring(with: next))
        }
        return (isFirst, isLast)
    }

    private struct TableLayout {
        /// The rows of the table.
        let run: NSRange
        /// How much smaller than normal the text must be to fit the width, never below 60%.
        let scale: CGFloat
    }

    /// How much smaller than normal the table's text must be to fit the width. The widest row decides, so all rows
    /// share one size and the columns stay lined up. An edit or a new width styles the whole table again (see
    /// `textStorage(_:didProcessEditing:...)` and `containerWidthMayHaveChanged`), which keeps this cache fresh.
    private func tableLayout(forRowAt range: NSRange, in storage: NSTextStorage) -> TableLayout {
        let source = storage.string as NSString
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        guard let run = tableRun(containing: line, in: source) else { return TableLayout(run: line, scale: 1) }
        if let known = tableLayouts[run.location] { return known }

        let padding = layoutManager?.textContainer?.lineFragmentPadding ?? 5
        let available = (layoutManager?.textContainer?.size.width ?? 0) - 2 * Self.codeInset - 2 * padding
        var scale: CGFloat = 1
        if available > 0 {
            var widest: CGFloat = 0
            source.enumerateSubstrings(in: run, options: .byLines) { row, _, _, _ in
                guard let row else { return }
                widest = max(widest, (row as NSString).size(withAttributes: [.font: EditorTheme.codeFont]).width)
            }
            if widest > available { scale = max(0.6, available / widest) }
        }

        let layout = TableLayout(run: run, scale: scale)
        tableLayouts[run.location] = layout
        return layout
    }

    private func nextLineIsTableSeparator(after range: NSRange, in storage: NSTextStorage) -> Bool {
        let source = storage.string as NSString
        let next = NSMaxRange(range)
        guard next < source.length else { return false }
        return MarkdownEditing.isTableSeparator(source.substring(with: source.lineRange(for: NSRange(location: next, length: 0))))
    }

    // MARK: Attachments

    private func attachmentRange(of block: MarkdownDocument.Block, in source: NSString) -> NSRange {
        var end = NSMaxRange(block.range)
        while end > block.range.location, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: block.range.location, length: end - block.range.location)
    }

    /// Selection belongs to the clicked occurrence, even when a file is referenced more than once.
    func attachmentSelection(at point: CGPoint) -> NSRange? {
        guard !showsMarkdown, let layoutManager, let contentStorage, let storage = contentStorage.textStorage,
              let fragment = layoutManager.textLayoutFragment(for: point) as? AttachmentFragment,
              fragment.attachmentBounds.contains(point),
              let location = fragment.textElement?.elementRange?.location else { return nil }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard let block = document.block(at: offset), case .attachment = block.kind else { return nil }
        return attachmentRange(of: block, in: storage.string as NSString)
    }

    func attachmentID(in selection: NSRange) -> UUID? {
        guard !showsMarkdown, selection.length > 0, let storage = contentStorage?.textStorage,
              let block = document.block(at: selection.location), case .attachment(let attachment) = block.kind,
              attachmentRange(of: block, in: storage.string as NSString) == selection else { return nil }
        return attachment.id
    }


    func attachmentDisplay(for id: UUID) -> AttachmentDisplay? {
        attachmentProvider?(id)
    }

    /// The attachment whose picture or chip is under `point` (text container coordinates).
    func attachmentID(at point: CGPoint) -> UUID? {
        guard !showsMarkdown else { return nil }
        guard let layoutManager,
              let fragment = layoutManager.textLayoutFragment(for: point) as? AttachmentFragment,
              fragment.attachmentBounds.contains(point),
              let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let value = paragraph.attributedString.attribute(Self.attachmentKey, at: 0, effectiveRange: nil) as? String
        else { return nil }
        return UUID(uuidString: value)
    }

    /// The address of the link under `point` (text container coordinates), unless the caret is on that line: then a
    /// tap places the caret, so the link can be edited.
    func linkURL(at point: CGPoint) -> URL? {
        guard !showsMarkdown else { return nil }
        guard let layoutManager, let contentStorage, let storage = contentStorage.textStorage,
              let fragment = layoutManager.textLayoutFragment(for: point),
              let paragraph = fragment.textElement as? NSTextParagraph,
              let start = fragment.textElement?.elementRange?.location
        else { return nil }

        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: start)
        let lineEnd = offset + paragraph.attributedString.length
        if isLineActive(NSRange(location: offset, length: lineEnd - offset), in: storage) { return nil }

        let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        for line in fragment.textLineFragments where line.typographicBounds.contains(local) {
            let inLine = CGPoint(x: local.x - line.typographicBounds.minX, y: local.y - line.typographicBounds.minY)
            let index = line.characterIndex(for: inLine)
            guard index >= 0, index < paragraph.attributedString.length,
                  let value = paragraph.attributedString.attribute(Self.linkURLKey, at: index, effectiveRange: nil) as? String,
                  let url = URL(string: value), url.scheme != nil
            else { continue }
            return url
        }
        return nil
    }

    // MARK: Width

    private var lastContainerWidth: CGFloat = 0
    private var widthRefreshScheduled = false

    /// Native layout wraps prose during resize. Only width-dependent preview elements need restyling.
    func containerWidthMayHaveChanged() {
        guard let width = layoutManager?.textContainer?.size.width, abs(width - lastContainerWidth) > 0.5 else { return }
        let isFirst = lastContainerWidth == 0
        lastContainerWidth = width
        guard !isFirst, !showsMarkdown, !widthRefreshScheduled else { return }
        widthRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.widthRefreshScheduled = false
            guard !self.showsMarkdown else { return }
            self.tableLayouts.removeAll()
            let ranges = self.document.blocks.compactMap { block -> NSRange? in
                switch block.kind {
                case .attachment, .table: return block.range
                default: return nil
                }
            }
            if !ranges.isEmpty { self.invalidate(ranges) }
        }
    }

    /// Draws the lines again, for when pictures arrive by sync or an attachment is added.
    func refreshAttachments() {
        reload()
    }

    // MARK: Checklists

    /// Finds the checklist line whose box is under `point` (text container coordinates).
    /// Returns a location inside that line, or nil if the point is not on a checkbox.
    func checklistLine(at point: CGPoint) -> Int? {
        guard !showsMarkdown else { return nil }
        guard let layoutManager, let contentStorage,
              let fragment = layoutManager.textLayoutFragment(for: point) as? ChecklistFragment,
              let start = fragment.textElement?.elementRange?.location else { return nil }
        let target = fragment.checkboxBounds.insetBy(dx: -4, dy: -4)
        guard target.contains(point) else { return nil }
        return contentStorage.offset(from: contentStorage.documentRange.location, to: start)
    }

    // MARK: NSTextLayoutManagerDelegate

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            if paragraph.attributedString.attribute(Self.headingLevelKey, at: 0, effectiveRange: nil) != nil {
                return HeadingFragment(textElement: textElement, range: textElement.elementRange)
            }
            if paragraph.attributedString.attribute(Self.blockMarkerKey, at: 0, effectiveRange: nil) != nil {
                let fragment = CodeBlockFragment(textElement: textElement, range: textElement.elementRange)
                fragment.controller = self
                return fragment
            }
            if paragraph.attributedString.attribute(Self.decorationKey, at: 0, effectiveRange: nil) != nil {
                return DecorationFragment(textElement: textElement, range: textElement.elementRange)
            }
            if paragraph.attributedString.attribute(Self.attachmentKey, at: 0, effectiveRange: nil) != nil {
                let fragment = AttachmentFragment(textElement: textElement, range: textElement.elementRange)
                fragment.controller = self
                return fragment
            }
            if paragraph.attributedString.attribute(Self.checklistKey, at: 0, effectiveRange: nil) != nil {
                return ChecklistFragment(textElement: textElement, range: textElement.elementRange)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Element services

extension LivePreviewController: ElementServices {
    var textContainerWidth: CGFloat { layoutManager?.textContainer?.size.width ?? 0 }
    var linePadding: CGFloat { layoutManager?.textContainer?.lineFragmentPadding ?? 5 }

    func syntaxTokens(for block: CodeBlock) -> [SyntaxToken] {
        guard let storage = contentStorage?.textStorage else { return [] }
        return syntaxTokens(for: block, in: storage)
    }

    func isActive(_ block: CodeBlock) -> Bool {
        guard let storage = contentStorage?.textStorage else { return false }
        return isActive(block, selection: selection, in: storage)
    }

    func tableModel(for block: MarkdownDocument.Block) -> MarkdownTable? {
        guard let storage = contentStorage?.textStorage,
              let index = tables.firstIndex(where: { $0.range == block.range }) else { return nil }
        return tableModel(at: index, in: storage)
    }

    func tableLayout(forRowAt range: NSRange) -> (run: NSRange, scale: CGFloat) {
        guard let storage = contentStorage?.textStorage else { return (range, 1) }
        let layout: TableLayout = tableLayout(forRowAt: range, in: storage)
        return (layout.run, layout.scale)
    }

    func nextLineIsTableSeparator(after range: NSRange) -> Bool {
        guard let storage = contentStorage?.textStorage else { return false }
        return nextLineIsTableSeparator(after: range, in: storage)
    }
}
