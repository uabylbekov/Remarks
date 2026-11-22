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
        // On the first line of code, not on the opening fence, where the language goes.
        #expect(result.selection == range(4))
    }

    @Test func codeBlockOnABlankLineReplacesThatLine() {
        let result = apply(.codeBlock, to: "a\n\nb", selection: range(2))
        #expect(result.text == "a\n```\n\n```\nb")
        #expect(result.selection == range(6))
    }

    @Test func codeBlockOnALineWithTextGoesAfterIt() {
        let result = apply(.codeBlock, to: "hello", selection: range(2))
        #expect(result.text == "hello\n```\n\n```")
        #expect(result.selection == range(10))
    }

    @Test func codeBlockWrapsTheSelectedLines() {
        let result = apply(.codeBlock, to: "x\ny\nz", selection: range(0, 3))
        #expect(result.text == "```\nx\ny\n```\nz")
        #expect(result.selection == range(4))
    }

    @Test func codeBlockResultIsRecognizedByTheScanner() {
        let result = apply(.codeBlock, to: "", selection: range(0))
        let blocks = CodeBlockScanner.scan(result.text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.close != nil)
    }

    @Test func theCaretOfANewCodeBlockIsOnALineOfCode() throws {
        for (source, selection) in [("", range(0)), ("a\n\nb", range(2)), ("hello", range(2)), ("x\ny", range(0, 3))] {
            let result = apply(.codeBlock, to: source, selection: selection)
            let block = try #require(CodeBlockScanner.scan(result.text).first)
            #expect(result.selection.location >= NSMaxRange(block.open), "after the opening fence: \(source.debugDescription)")
            #expect(result.selection.location <= (block.close?.location ?? Int.max), "before the closing fence")
        }
    }

    @Test func codeBlockCreationTransactionsPutTypingInTheBody() throws {
        for (source, selection) in [("", range(0)), ("a\n\nb", range(2)), ("hello", range(2)), ("😀\nx\ny", range(3, 3))] {
            let edit = MarkdownEditing.edit(.codeBlock, in: source, selection: selection)
            let transaction = try #require(edit.transaction(in: source, selectionBefore: selection))
            let block = try #require(CodeBlockScanner.scan(transaction.result).first)
            #expect(edit.selection == range(block.body.location))
            let typed = (transaction.result as NSString).replacingCharacters(in: edit.selection, with: "code")
            #expect(CodeBlockScanner.scan(typed).first?.language == "")
            let undone = try #require(transaction.inverse.transaction(in: transaction.result, selectionBefore: edit.selection))
            #expect(undone.result == source)
            #expect(undone.edit.selection == selection)
        }
    }

    @Test func languageTransactionPreservesBodyAndCanBeUndone() throws {
        let source = "~~~\n😀 code\n~~~"
        let selection = range(4)
        let edit = try #require(MarkdownEditing.setCodeLanguage("swift", inBlockAt: selection.location, in: source))
        let transaction = try #require(edit.transaction(in: source, selectionBefore: selection))
        #expect(transaction.result == "~~~swift\n😀 code\n~~~")
        #expect(edit.selection == range(9))
        let undone = try #require(transaction.inverse.transaction(in: transaction.result, selectionBefore: edit.selection))
        #expect(undone.result == source)
        #expect(undone.edit.selection == selection)
    }

    // MARK: Code language

    @Test func settingALanguageWritesItAfterTheOpeningFence() throws {
        let text = "intro\n```\nlet a = 1\n```\nafter"
        let edit = try #require(MarkdownEditing.setCodeLanguage("swift", inBlockAt: 12, in: text))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result == "intro\n```swift\nlet a = 1\n```\nafter")
        #expect(CodeBlockScanner.scan(result).first?.language == "swift")
        // The caret was in the code, which moved down by the length of the language.
        #expect(edit.selection.location == 12 + 5)
    }

    @Test func changingAndClearingALanguage() throws {
        let text = "```python\nx\n```"
        let changed = try #require(MarkdownEditing.setCodeLanguage("go", inBlockAt: 11, in: text))
        #expect((text as NSString).replacingCharacters(in: changed.range, with: changed.replacement) == "```go\nx\n```")
        let cleared = try #require(MarkdownEditing.setCodeLanguage("", inBlockAt: 11, in: text))
        #expect((text as NSString).replacingCharacters(in: cleared.range, with: cleared.replacement) == "```\nx\n```")
    }

    @Test func theFenceKindAndLengthAreKept() throws {
        let tilde = "~~~\nx\n~~~"
        let edit = try #require(MarkdownEditing.setCodeLanguage("rust", inBlockAt: 4, in: tilde))
        #expect((tilde as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "~~~rust\nx\n~~~")
        let long = "````\nx\n````"
        let longEdit = try #require(MarkdownEditing.setCodeLanguage("c", inBlockAt: 5, in: long))
        #expect((long as NSString).replacingCharacters(in: longEdit.range, with: longEdit.replacement) == "````c\nx\n````")
    }

    @Test func settingALanguageOutsideABlockDoesNothing() {
        #expect(MarkdownEditing.setCodeLanguage("swift", inBlockAt: 0, in: "plain text") == nil)
    }

    @Test func anUnclosedBlockCanHaveALanguage() throws {
        let text = "```\n"
        let edit = try #require(MarkdownEditing.setCodeLanguage("swift", inBlockAt: 4, in: text))
        #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "```swift\n")
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
        for command in MarkdownCommand.allCases {
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
        // The caret goes to the line below the table, which is shown as a grid.
        #expect(edit.replacement.hasSuffix("\n"))
        #expect(edit.selection == NSRange(location: (edit.replacement as NSString).length, length: 0))
    }

    @Test func putsTheTableAfterALineWithText() {
        let edit = MarkdownEditing.edit(.table, in: "Intro", selection: NSRange(location: 5, length: 0))
        #expect(edit.range == NSRange(location: 5, length: 0))
        #expect(edit.replacement.hasPrefix("\n| Column 1"))
        #expect(edit.replacement.hasSuffix("\n"))
    }

    @Test func aTableInTheMiddleOfANoteKeepsItsFollowingLine() {
        let text = "Intro\nOutro"
        let edit = MarkdownEditing.edit(.table, in: text, selection: NSRange(location: 2, length: 0))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result.hasSuffix("|\nOutro"))
        // The caret is at the start of the line after the table.
        #expect((result as NSString).substring(from: edit.selection.location) == "Outro")
    }

    @Test func recognisesRowsAndSeparators() {
        #expect(MarkdownEditing.isTableRow("| a | b |"))
        #expect(!MarkdownEditing.isTableRow("a | b"))
        #expect(MarkdownEditing.isTableSeparator("| --- | :---: |"))
        #expect(!MarkdownEditing.isTableSeparator("| a | b |"))
    }
}
