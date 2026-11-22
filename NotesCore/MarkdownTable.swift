import Foundation

/// A GitHub Markdown table as plain values: the header, how each column is aligned, and the body rows. A table view
/// edits this, and `markdown` turns it back into the lined-up text that is stored in the note.
/// Cells hold their text as written, so an escaped pipe (`\|`) stays as it is and round-trips.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case none, left, center, right
    }

    public private(set) var header: [String]
    public private(set) var alignments: [Alignment]
    public private(set) var rows: [[String]]

    public var columnCount: Int { header.count }

    public init(header: [String], alignments: [Alignment]? = nil, rows: [[String]] = []) {
        let header = header.isEmpty ? [""] : header
        self.header = header
        self.alignments = Self.fit(alignments ?? [], to: header.count, with: .none)
        self.rows = rows.map { Self.fit($0, to: header.count, with: "") }
    }

    /// A table of empty cells, with "Column 1", "Column 2" and so on as its header.
    public static func blank(columns: Int, rows: Int) -> MarkdownTable {
        let count = max(1, columns)
        return MarkdownTable(
            header: (1...count).map { "Column \($0)" },
            rows: Array(repeating: Array(repeating: "", count: count), count: max(0, rows))
        )
    }

    /// Reads the rows of a table. Nil unless the second row is a separator (`| --- | --- |`), which GitHub requires.
    public init?(parsing text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { MarkdownEditing.isTableRow($0) }
        guard lines.count >= 2, MarkdownEditing.isTableSeparator(lines[1]) else { return nil }
        let header = Self.cells(of: lines[0])
        let marks = Self.cells(of: lines[1])
        // A partially typed separator must not activate a grid before all header columns exist.
        guard marks.count == header.count else { return nil }
        let alignments = (0..<header.count).map { column -> Alignment in
            guard column < marks.count else { return .none }
            let left = marks[column].hasPrefix(":"), right = marks[column].hasSuffix(":")
            return left && right ? .center : left ? .left : right ? .right : .none
        }
        self.init(header: header, alignments: alignments, rows: lines.dropFirst(2).map { Self.cells(of: $0) })
    }

    // MARK: Editing

    /// Adds an empty row so that it becomes row `index` of the body (0 is just under the header).
    public mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(0, index), rows.count))
    }

    /// Adds an empty column so that it becomes column `index`. Its header is empty.
    public mutating func insertColumn(at index: Int) {
        let position = min(max(0, index), columnCount)
        header.insert("", at: position)
        alignments.insert(.none, at: position)
        for row in rows.indices { rows[row].insert("", at: position) }
    }

    public mutating func deleteRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    /// A table always keeps at least one column.
    public mutating func deleteColumn(at index: Int) {
        guard columnCount > 1, header.indices.contains(index) else { return }
        header.remove(at: index)
        alignments.remove(at: index)
        for row in rows.indices { rows[row].remove(at: index) }
    }

    public mutating func setHeader(_ text: String, column: Int) {
        guard header.indices.contains(column) else { return }
        header[column] = Self.clean(text)
    }

    public mutating func setCell(_ text: String, row: Int, column: Int) {
        guard rows.indices.contains(row), header.indices.contains(column) else { return }
        rows[row][column] = Self.clean(text)
    }

    public mutating func setAlignment(_ alignment: Alignment, column: Int) {
        guard alignments.indices.contains(column) else { return }
        alignments[column] = alignment
    }

    // MARK: Text

    /// The table as Markdown with every column padded to its widest cell, and no trailing newline.
    public func markdown() -> String {
        var widths = header.map { max(3, $0.count) }
        for row in rows {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }

        func line(_ values: [String]) -> String {
            let padded = values.enumerated().map { column, value in
                value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let separator = alignments.enumerated().map { column, alignment -> String in
            let width = widths[column]
            switch alignment {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }
        return ([line(header), "| " + separator.joined(separator: " | ") + " |"] + rows.map(line)).joined(separator: "\n")
    }

    // MARK: Helpers

    /// A cell is one line, so a line break typed or pasted into it becomes a space.
    private static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var result = ""
        var escaped = false
        for character in line {
            if character == "|", !escaped { result.append("\\") }
            result.append(character)
            escaped = character == "\\" && !escaped
        }
        return result
    }

    private static func fit<Value>(_ values: [Value], to count: Int, with filler: Value) -> [Value] {
        values.count >= count ? Array(values.prefix(count)) : values + Array(repeating: filler, count: count - values.count)
    }

    /// The cells of one row. A pipe after a backslash belongs to its cell.
    static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if MarkdownEditing.tablePipeOffsets(in: trimmed as NSString).last == (trimmed as NSString).length - 1 {
            trimmed.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if character == "|", !escaped {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
