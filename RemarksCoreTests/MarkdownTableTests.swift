import Testing
import Foundation
@testable import RemarksCore

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

    @Test func emojiCellsRoundTripWithoutTruncation() {
        let table = MarkdownTable(header: ["Item", "Icon"], alignments: [.none, .none], rows: [["Apple", "🍎🎉"], ["Banana", "🍌"]])
        let parsed = MarkdownTable(parsing: table.markdown())
        #expect(parsed == table)
    }

    @Test func initializerSanitizesPipesAndNewlines() {
        let table = MarkdownTable(header: ["A|B"], alignments: [.none], rows: [["line1\nline2"]])
        #expect(table.header == ["A\\|B"])
        #expect(table.rows == [["line1 line2"]])
    }
}

@Suite("Table metrics accessibility scaling")
struct MarkdownTableMetricsTests {
    @Test("Menu width stays larger than menu icon size at accessibility font sizes")
    func menuWidthCoversMenuIconAtAccessibilitySizes() {
        let fontSize = 53.0
        let iconSize = MarkdownTableMetrics.menuIconSize(forFontSize: fontSize)
        let menuWidth = MarkdownTableMetrics.menuWidth(forFontSize: fontSize)
        #expect(iconSize <= 24)
        #expect(menuWidth > iconSize)
    }

    @Test("Column minimum and maximum widths scale proportionally above default body size")
    func columnWidthsScaleWithLargeText() {
        let defaultMin = MarkdownTableMetrics.minimumColumnWidth(forFontSize: 17)
        let largeMin = MarkdownTableMetrics.minimumColumnWidth(forFontSize: 53)
        let defaultMax = MarkdownTableMetrics.maximumColumnWidth(forFontSize: 17)
        let largeMax = MarkdownTableMetrics.maximumColumnWidth(forFontSize: 53)
        #expect(defaultMin == 80)
        #expect(defaultMax == 320)
        #expect(largeMin > defaultMin * 2)
        #expect(largeMax > defaultMax * 2)
    }

    @Test("Row height honors the minimum touch target at small text sizes and grows for larger text")
    func rowHeightHonorsTouchTargetAndLargeText() {
        #expect(MarkdownTableMetrics.rowHeight(fontLineHeight: 20, minimumTouchHeight: 44) == 44)
        #expect(MarkdownTableMetrics.rowHeight(fontLineHeight: 60, minimumTouchHeight: 44) == 76)
    }
}
