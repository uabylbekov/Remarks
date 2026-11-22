import Testing
import Foundation
@testable import NotesCore

struct EditorBehaviorTests {
    @Test func nestedDelimitersAndCodeRunsKeepTheirSourceRanges() {
        let text = "**bold with *italic* inside** and ``a ` b``"
        let spans = InlineScanner.spans(in: text)
        #expect(spans.map(\.kind) == [.bold, .italic, .code])
        #expect(spans.last.map { (text as NSString).substring(with: $0.content) } == "a ` b")
        #expect(InlineScanner.spans(in: "snake_case_name").isEmpty)
        #expect(InlineScanner.spans(in: "`**literal**`").map(\.kind) == [.code])
    }

    @Test func togglingFromInsideAStyleRemovesOnlyThatStyle() throws {
        let text = "***hello***"
        let caret = NSRange(location: 5, length: 0)
        let bold = MarkdownEditing.edit(.bold, in: text, selection: caret)
        #expect(try #require(bold.transaction(in: text, selectionBefore: caret)).result == "*hello*")
        let italic = MarkdownEditing.edit(.italic, in: text, selection: caret)
        #expect(try #require(italic.transaction(in: text, selectionBefore: caret)).result == "**hello**")
        let nested = "**bold _italic_ end**"
        let edit = MarkdownEditing.edit(.bold, in: nested, selection: NSRange(location: 10, length: 0))
        #expect((nested as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "bold _italic_ end")
    }

    @Test func insertingInlineCodeChoosesASafeDelimiter() throws {
        let text = "a ` b"
        let selected = NSRange(location: 0, length: text.utf16.count)
        let edit = MarkdownEditing.edit(.inlineCode, in: text, selection: selected)
        let result = try #require(edit.transaction(in: text, selectionBefore: selected)).result
        #expect(result == "``a ` b``")
        #expect(InlineScanner.spans(in: result).map(\.kind) == [.code])
    }

    @Test func tildeFencesNeedMatchingClosers() {
        let text = "~~~swift\n```\nlet a = 1\n~~~\nafter"
        let blocks = CodeBlockScanner.scan(text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.language == "swift")
        #expect(blocks.first?.close != nil)
        #expect(CodeBlockScanner.scan("```swift\n~~~\n").first?.close == nil)
    }

    @Test func setextHeadingsAndContainerRelationshipsAreStructural() {
        let text = "Title\n=====\n- parent\n    - child\n> > quoted\n"
        let document = MarkdownDocument(text)
        guard case .heading(let level, _) = document.blocks.first?.kind else {
            Issue.record("Missing Setext heading"); return
        }
        #expect(level == 1)
        let containers = document.containers(in: text)
        #expect(containers.count == 4)
        #expect(containers[1].parent == 0)
        #expect(containers[2].parent == 1)
        #expect(containers[2].depth == 1)
        #expect(containers[3].depth == 2)
    }

    @Test func nestedQuoteReturnKeepsDepthAndEmptyListsOutdentOneLevel() throws {
        let text = "> > quote"
        let edit = try #require(MarkdownEditing.returnKeyEdit(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        #expect(edit.replacement == "\n> > ")
        let empty = "    - "
        let outdent = try #require(MarkdownEditing.returnKeyEdit(in: empty, selection: NSRange(location: empty.utf16.count, length: 0)))
        #expect(outdent.replacement == "- ")
    }

    @Test func listIndentAndOutdentPreserveTextSelectionAndTaskState() throws {
        let text = "- [x] one\n- two\n"
        let selected = NSRange(location: 0, length: text.utf16.count)
        let indent = try #require(MarkdownEditing.indentList(in: text, selection: selected, outdent: false))
        let changed = try #require(indent.transaction(in: text, selectionBefore: selected))
        #expect(changed.result == "    - [x] one\n    - two\n")
        let outdent = try #require(MarkdownEditing.indentList(in: changed.result, selection: indent.selection, outdent: true))
        #expect((changed.result as NSString).replacingCharacters(in: outdent.range, with: outdent.replacement) == text)
    }
    @Test func typedTablePipesRemainInTheirCell() throws {
        var table = MarkdownTable.blank(columns: 2, rows: 1)
        table.setCell("one | two", row: 0, column: 0)
        table.setHeader("a \\| b", column: 1)
        let restored = try #require(MarkdownTable(parsing: table.markdown()))
        #expect(restored == table)
        #expect(restored.rows[0][0] == "one \\| two")
    }

    @Test func evenBackslashesDoNotEscapeTableDividers() {
        let row = "| a\\\\| b |"
        #expect(MarkdownEditing.tablePipeOffsets(in: row as NSString) == [0, 5, 9])
        #expect(MarkdownTable.cells(of: row) == ["a\\\\", "b"])
    }

    @Test func formattingATablePreservesEscapedPipes() throws {
        let source = "| a \\| b | c |\n| --- | --- |\n| x | y |\n"
        let edit = MarkdownEditing.edit(.formatTable, in: source, selection: NSRange(location: 3, length: 0))
        let result = try #require(edit.transaction(in: source, selectionBefore: NSRange(location: 3, length: 0))).result
        #expect(MarkdownTable(parsing: result) == MarkdownTable(parsing: source))
    }

    @Test func insertingATableDoesNotSplitCRLF() throws {
        let source = "before\r\nafter"
        let caret = NSRange(location: 2, length: 0)
        let edit = MarkdownEditing.edit(.table, in: source, selection: caret)
        let result = try #require(edit.transaction(in: source, selectionBefore: caret)).result
        #expect(MarkdownDocument(result).blocks.contains { if case .table = $0.kind { true } else { false } })
        #expect((result as NSString).substring(from: edit.selection.location) == "after")
    }

    @Test func aPartialSeparatorCannotActivateAMultiColumnTable() {
        #expect(MarkdownTable(parsing: "| First | Second |\n| --- |") == nil)
        #expect(MarkdownTable(parsing: "| First | Second |\n| --- | --- |")?.columnCount == 2)
        #expect(MarkdownTable(parsing: "| First |\n| --- | --- |") == nil)
    }

}
