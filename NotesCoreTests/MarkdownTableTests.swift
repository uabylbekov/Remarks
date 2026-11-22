import Testing
import Foundation
@testable import NotesCore

struct MarkdownTableTests {
    private let sample = "| Item | Qty |\n| ---- | --- |\n| Apples | 3 |\n| Milk | 1 |\n"

    @Test func readsHeaderAndRows() {
        let table = MarkdownTable(parsing: sample)
        #expect(table?.header == ["Item", "Qty"])
        #expect(table?.rows == [["Apples", "3"], ["Milk", "1"]])
    }

    @Test func aTableNeedsASeparatorRow() {
        #expect(MarkdownTable(parsing: "| a | b |\n| c | d |\n") == nil)
        #expect(MarkdownTable(parsing: "| a | b |\n") == nil)
    }

    @Test func readsColumnAlignment() {
        let table = MarkdownTable(parsing: "| a | b | c | d |\n| :-- | :-: | --: | --- |\n")
        #expect(table?.alignments == [.left, .center, .right, .none])
    }

    @Test func shortRowsAreFilledAndLongRowsAreCut() {
        let table = MarkdownTable(parsing: "| a | b |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |\n")
        #expect(table?.rows == [["1", ""], ["1", "2"]])
    }

    @Test func anEscapedPipeStaysInItsCell() {
        let table = MarkdownTable(parsing: "| a \\| b | c |\n| - | - |\n")
        #expect(table?.header == ["a \\| b", "c"])
    }

    @Test func markdownLinesUpTheColumns() {
        let table = MarkdownTable(parsing: sample)
        #expect(table?.markdown() == """
        | Item   | Qty |
        | ------ | --- |
        | Apples | 3   |
        | Milk   | 1   |
        """)
    }

    @Test func markdownRoundTrips() {
        let table = MarkdownTable(parsing: "| a | b |\n| :-- | --: |\n| x | y |\n")
        let again = table.flatMap { MarkdownTable(parsing: $0.markdown()) }
        #expect(again == table)
    }

    @Test func insertingARowAddsEmptyCells() {
        var table = MarkdownTable(parsing: sample)!
        table.insertRow(at: 1)
        #expect(table.rows == [["Apples", "3"], ["", ""], ["Milk", "1"]])
        table.insertRow(at: 0)
        #expect(table.rows.first == ["", ""])
        table.insertRow(at: 99)
        #expect(table.rows.last == ["", ""])
        #expect(table.rows.count == 5)
    }

    @Test func insertingAColumnBeforeAndAfter() {
        var table = MarkdownTable(parsing: sample)!
        table.insertColumn(at: 0)
        #expect(table.header == ["", "Item", "Qty"])
        #expect(table.rows[0] == ["", "Apples", "3"])
        table.insertColumn(at: 3)
        #expect(table.header == ["", "Item", "Qty", ""])
        #expect(table.alignments.count == 4)
    }

    @Test func deletingKeepsAtLeastOneColumn() {
        var table = MarkdownTable(parsing: "| a | b |\n| - | - |\n| 1 | 2 |\n")!
        table.deleteColumn(at: 0)
        #expect(table.header == ["b"])
        table.deleteColumn(at: 0)
        #expect(table.header == ["b"])
        table.deleteRow(at: 0)
        #expect(table.rows.isEmpty)
        table.deleteRow(at: 0)
        #expect(table.rows.isEmpty)
    }

    @Test func aCellIsOneTrimmedLine() {
        var table = MarkdownTable.blank(columns: 2, rows: 1)
        table.setCell("  one\ntwo  ", row: 0, column: 1)
        #expect(table.rows[0][1] == "one two")
        table.setHeader("Name", column: 0)
        #expect(table.header[0] == "Name")
    }

    @Test func outOfRangeEditsAreIgnored() {
        var table = MarkdownTable.blank(columns: 2, rows: 1)
        let before = table
        table.setCell("x", row: 5, column: 0)
        table.setCell("x", row: 0, column: 5)
        table.setHeader("x", column: 5)
        table.deleteColumn(at: 9)
        #expect(table == before)
    }

    @Test func aBlankTableIsParsedBack() {
        let table = MarkdownTable.blank(columns: 3, rows: 2)
        #expect(MarkdownTable(parsing: table.markdown()) == table)
    }

    @Test func alignmentSurvivesEditing() {
        var table = MarkdownTable.blank(columns: 2, rows: 0)
        table.setAlignment(.right, column: 1)
        table.insertColumn(at: 0)
        #expect(table.alignments == [.none, .none, .right])
        #expect(MarkdownTable(parsing: table.markdown())?.alignments == [.none, .none, .right])
    }
}
