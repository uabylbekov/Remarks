import Testing
import Foundation
@testable import NotesCore

/// The keyboard bar's formatting commands (Spec 03). Each test applies the edit and checks text and selection.
struct MarkdownEditingTests {
    private func apply(_ command: MarkdownCommand, to text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let edit = MarkdownEditing.edit(command, in: text, selection: selection)
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    private func range(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }

    // MARK: Inline

    @Test func boldWrapsTheSelection() {
        let result = apply(.bold, to: "hello world", selection: range(6, 5))
        #expect(result.text == "hello **world**")
        #expect(result.selection == range(8, 5))
    }

    @Test func boldWithNoSelectionInsertsAPairAndPlacesTheCaretBetween() {
        let result = apply(.bold, to: "ab", selection: range(1))
        #expect(result.text == "a****b")
        #expect(result.selection == range(3))
    }

    @Test func boldTogglesOffWhenTheCaretIsInsideAnEmptyPair() {
        let result = apply(.bold, to: "a****b", selection: range(3))
        #expect(result.text == "ab")
        #expect(result.selection == range(1))
    }

    @Test func boldTogglesOffWhenTheMarkersSurroundTheSelection() {
        let result = apply(.bold, to: "**hi**", selection: range(2, 2))
        #expect(result.text == "hi")
        #expect(result.selection == range(0, 2))
    }

    @Test func inlineCodeItalicAndStrikethroughUseTheirMarkers() {
        #expect(apply(.inlineCode, to: "x", selection: range(0, 1)).text == "`x`")
        #expect(apply(.italic, to: "x", selection: range(0, 1)).text == "_x_")
        #expect(apply(.strikethrough, to: "x", selection: range(0, 1)).text == "~~x~~")
    }

    @Test func emojiSelectionsKeepUTF16RangesCorrect() {
        let text = "😀 go"  // the emoji is two UTF-16 units
        let result = apply(.bold, to: text, selection: range(3, 2))
        #expect(result.text == "😀 **go**")
        #expect(result.selection == range(5, 2))
    }

    // MARK: Code block

    @Test func codeBlockInAnEmptyNote() {
        let result = apply(.codeBlock, to: "", selection: range(0))
        #expect(result.text == "```\n\n```")
        #expect(result.selection == range(3))
    }

    @Test func codeBlockOnABlankLineReplacesThatLine() {
        let result = apply(.codeBlock, to: "a\n\nb", selection: range(2))
        #expect(result.text == "a\n```\n\n```\nb")
        #expect(result.selection == range(5))
    }

    @Test func codeBlockOnALineWithTextGoesAfterIt() {
        let result = apply(.codeBlock, to: "hello", selection: range(2))
        #expect(result.text == "hello\n```\n\n```")
        #expect(result.selection == range(9))
    }

    @Test func codeBlockWrapsTheSelectedLines() {
        let result = apply(.codeBlock, to: "x\ny\nz", selection: range(0, 3))
        #expect(result.text == "```\nx\ny\n```\nz")
        #expect(result.selection == range(3))
    }

    @Test func codeBlockResultIsRecognizedByTheScanner() {
        let result = apply(.codeBlock, to: "", selection: range(0))
        let blocks = CodeBlockScanner.scan(result.text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.close != nil)
    }

    // MARK: Heading

    @Test func headingCyclesThroughThreeLevelsAndBackToPlain() {
        var current = apply(.heading, to: "title", selection: range(5))
        #expect(current.text == "# title")
        #expect(current.selection == range(7))

        current = apply(.heading, to: current.text, selection: current.selection)
        #expect(current.text == "## title")
        #expect(current.selection == range(8))

        current = apply(.heading, to: current.text, selection: current.selection)
        #expect(current.text == "### title")

        current = apply(.heading, to: current.text, selection: current.selection)
        #expect(current.text == "title")
        #expect(current.selection == range(5))
    }

    // MARK: Lists and quotes

    @Test func bulletListTogglesOnAndOffAcrossLines() {
        let on = apply(.bulletList, to: "a\nb", selection: range(0, 3))
        #expect(on.text == "- a\n- b")
        #expect(on.selection == range(0, 7))

        let off = apply(.bulletList, to: on.text, selection: on.selection)
        #expect(off.text == "a\nb")
        #expect(off.selection == range(0, 3))
    }

    @Test func bulletOnABlankLineStartsAList() {
        let result = apply(.bulletList, to: "", selection: range(0))
        #expect(result.text == "- ")
        #expect(result.selection == range(2))
    }

    @Test func checklistReplacesAnExistingBullet() {
        let result = apply(.checklist, to: "- a", selection: range(3))
        #expect(result.text == "- [ ] a")
    }

    @Test func checklistTogglesOff() {
        let result = apply(.checklist, to: "- [x] done", selection: range(0))
        #expect(result.text == "done")
    }

    @Test func numberedListNumbersEachLine() {
        let result = apply(.numberedList, to: "a\nb\nc", selection: range(0, 5))
        #expect(result.text == "1. a\n2. b\n3. c")
    }

    @Test func quoteTogglesOnAndOff() {
        let on = apply(.quote, to: "words", selection: range(5))
        #expect(on.text == "> words")
        #expect(on.selection == range(7))
        let off = apply(.quote, to: on.text, selection: on.selection)
        #expect(off.text == "words")
    }

    @Test func bulletSkipsBlankLinesInsideASelection() {
        let result = apply(.bulletList, to: "a\n\nb", selection: range(0, 4))
        #expect(result.text == "- a\n\n- b")
    }

    // MARK: Link

    @Test func linkWrapsTheSelectionAndPlacesTheCaretInTheParentheses() {
        let result = apply(.link, to: "see docs", selection: range(4, 4))
        #expect(result.text == "see [docs]()")
        #expect(result.selection == range(11))
    }

    @Test func linkWithNoSelectionInsertsAnEmptyLink() {
        let result = apply(.link, to: "", selection: range(0))
        #expect(result.text == "[]()")
        #expect(result.selection == range(1))
    }

    // MARK: Safety

    @Test func outOfRangeSelectionsAreClampedInsteadOfCrashing() {
        for command in MarkdownCommand.allCases {
            let edit = MarkdownEditing.edit(command, in: "abc", selection: NSRange(location: 99, length: 50))
            #expect(edit.range.location <= 3)
            #expect(NSMaxRange(edit.range) <= 3)
        }
    }

    @Test func everyCommandWorksOnAnEmptyNote() {
        // Formatting a table has nothing to do when there is no table.
        for command in MarkdownCommand.allCases where command != .formatTable {
            let edit = MarkdownEditing.edit(command, in: "", selection: NSRange(location: 0, length: 0))
            #expect(!edit.replacement.isEmpty)
        }
    }
}

struct TableEditingTests {
    @Test func insertsAnAlignedTableOnABlankLine() {
        let edit = MarkdownEditing.edit(.table, in: "", selection: NSRange(location: 0, length: 0))
        let lines = edit.replacement.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(Set(lines.map(\.count)).count == 1)
        #expect(MarkdownEditing.isTableSeparator(lines[1]))
        #expect((edit.replacement as NSString).substring(with: edit.selection) == "Column 1")
    }

    @Test func putsTheTableAfterALineWithText() {
        let edit = MarkdownEditing.edit(.table, in: "Intro", selection: NSRange(location: 5, length: 0))
        #expect(edit.range == NSRange(location: 5, length: 0))
        #expect(edit.replacement.hasPrefix("\n| Column 1"))
    }

    @Test func recognisesRowsAndSeparators() {
        #expect(MarkdownEditing.isTableRow("| a | b |"))
        #expect(!MarkdownEditing.isTableRow("a | b"))
        #expect(MarkdownEditing.isTableSeparator("| --- | :---: |"))
        #expect(!MarkdownEditing.isTableSeparator("| a | b |"))
    }

    @Test func formattingPadsEveryCellToTheWidestInItsColumn() {
        let text = "| Name | Qty |\n| --- | --- |\n| Apples | 3 |\n"
        let edit = MarkdownEditing.edit(.formatTable, in: text, selection: NSRange(location: 2, length: 0))
        #expect(edit.replacement == "| Name   | Qty |\n| ------ | --- |\n| Apples | 3   |\n")
    }

    @Test func formattingKeepsColumnAlignmentMarks() {
        let text = "| A | B |\n| :-- | --: |\n| x | y |"
        let edit = MarkdownEditing.edit(.formatTable, in: text, selection: NSRange(location: 2, length: 0))
        #expect(edit.replacement.contains("| :-- | --: |"))
    }

    @Test func formattingOutsideATableChangesNothing() {
        let edit = MarkdownEditing.edit(.formatTable, in: "plain text", selection: NSRange(location: 3, length: 0))
        #expect(edit.replacement.isEmpty)
        #expect(edit.range.length == 0)
    }
}
