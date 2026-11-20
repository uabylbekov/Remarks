import Testing
import Foundation
@testable import NotesCore

// MARK: - Inline spans

struct InlineScannerTests {
    private func spans(_ text: String) -> [InlineSpan] { InlineScanner.spans(in: text) }
    private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    @Test func findsBoldItalicStrikeAndCode() {
        let text = "a **bold** b _it_ c ~~gone~~ d `code`"
        let found = spans(text)
        let kinds = found.map(\.kind)
        #expect(kinds == [.bold, .italic, .strikethrough, .code])
        #expect(found.map { substring(text, $0.content) } == ["bold", "it", "gone", "code"])
    }

    @Test func markersAreTheTextAroundTheContent() {
        let text = "**hi**"
        let span = spans(text).first
        #expect(span?.markers == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        #expect(span?.content == NSRange(location: 2, length: 2))
    }

    @Test func linkHidesTheBracketsAndTheDestination() {
        let text = "see [docs](https://x.dev) now"
        let span = spans(text).first
        #expect(span?.kind == .link)
        #expect(span?.destination == "https://x.dev")
        #expect(span.map { substring(text, $0.content) } == "docs")
        let hidden = span?.markers.map { substring(text, $0) }
        #expect(hidden == ["[", "](https://x.dev)"])
    }

    @Test func imagesAreNotLinks() {
        #expect(spans("![alt](pic.png)").isEmpty)
    }

    @Test func codeContentsStayLiteral() {
        let text = "`**not bold**`"
        let found = spans(text)
        #expect(found.count == 1)
        #expect(found.first?.kind == .code)
    }

    @Test func stylesCanNest() {
        let text = "**bold with _italic_ inside**"
        let kinds = spans(text).map(\.kind)
        #expect(kinds.contains(.bold))
        #expect(kinds.contains(.italic))
    }

    @Test func ordinaryAsterisksUnderscoresAndTildesAreLeftAlone() {
        #expect(spans("2 * 3 * 4").isEmpty)
        #expect(spans("snake_case_name and other_name").isEmpty)
        #expect(spans("a ~ b ~ c").isEmpty)
        #expect(spans("** not bold **").isEmpty)
    }

    @Test func unterminatedMarksAreIgnored() {
        #expect(spans("**oops").isEmpty)
        #expect(spans("a `open").isEmpty)
    }

    @Test func rangesStayCorrectAfterEmoji() {
        let text = "😀 **go**"
        let span = spans(text).first
        #expect(span.map { substring(text, $0.content) } == "go")
    }

    @Test func emptyAndPlainTextHaveNoSpans() {
        #expect(spans("").isEmpty)
        #expect(spans("just words").isEmpty)
    }
}

// MARK: - Return key in lists

struct ListContinuationTests {
    private func apply(_ text: String, caret: Int) -> (text: String, selection: NSRange)? {
        guard let edit = MarkdownEditing.returnKeyEdit(in: text, selection: NSRange(location: caret, length: 0)) else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test func bulletContinues() {
        let result = apply("- a", caret: 3)
        #expect(result?.text == "- a\n- ")
        #expect(result?.selection == NSRange(location: 6, length: 0))
    }

    @Test func emptyBulletEndsTheList() {
        let result = apply("- a\n- ", caret: 6)
        #expect(result?.text == "- a\n")
        #expect(result?.selection == NSRange(location: 4, length: 0))
    }

    @Test func checklistContinuesWithAnUncheckedBox() {
        #expect(apply("- [x] done", caret: 10)?.text == "- [x] done\n- [ ] ")
        #expect(apply("- [ ] todo", caret: 10)?.text == "- [ ] todo\n- [ ] ")
    }

    @Test func emptyChecklistItemEndsTheList() {
        #expect(apply("- [ ] ", caret: 6)?.text == "")
    }

    @Test func aFreshlyTypedCheckboxWithoutASpaceStartsTheNextItem() {
        // Typing "- []" and pressing Return used to continue as a plain bullet.
        let result = apply("- []", caret: 4)
        #expect(result?.text == "- []\n- [ ] ")
        #expect(apply("- [ ]", caret: 5)?.text == "- [ ]\n- [ ] ")
        #expect(apply("- [x]", caret: 5)?.text == "- [x]\n- [ ] ")
    }

    @Test func aCheckboxWithoutASpaceStillCountsAsACheckboxWhenItHasText() {
        #expect(apply("- [] buy milk", caret: 13)?.text == "- [] buy milk\n- [ ] ")
    }

    @Test func aBulletWhoseTextIsALinkIsNotACheckbox() {
        #expect(apply("- [docs](x)", caret: 11)?.text == "- [docs](x)\n- ")
    }

    @Test func numberedListCountsUp() {
        #expect(apply("1. a", caret: 4)?.text == "1. a\n2. ")
        #expect(apply("9) a", caret: 4)?.text == "9) a\n10) ")
    }

    @Test func indentationIsKept() {
        #expect(apply("  - nested", caret: 10)?.text == "  - nested\n  - ")
    }

    @Test func quoteContinues() {
        #expect(apply("> a", caret: 3)?.text == "> a\n> ")
    }

    @Test func returnInTheMiddleSplitsTheItem() {
        let result = apply("- ab", caret: 3)
        #expect(result?.text == "- a\n- b")
    }

    @Test func plainLinesAndMarksAreLeftToTheTextView() {
        #expect(apply("hello", caret: 5) == nil)
        #expect(apply("- a", caret: 1) == nil)   // caret inside the mark
        #expect(apply("", caret: 0) == nil)
    }

    @Test func aSelectionIsLeftToTheTextView() {
        let edit = MarkdownEditing.returnKeyEdit(in: "- abc", selection: NSRange(location: 2, length: 2))
        #expect(edit == nil)
    }

    @Test func outOfRangeCaretDoesNotCrash() {
        #expect(MarkdownEditing.returnKeyEdit(in: "- a", selection: NSRange(location: 99, length: 0)) == nil)
    }
}

// MARK: - Checkbox toggling

struct ChecklistToggleTests {
    private func toggled(_ text: String, line: Int, selection: NSRange = NSRange(location: 0, length: 0)) -> String? {
        guard let edit = MarkdownEditing.toggleChecklist(in: text, atLine: line, keepingSelection: selection) else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func checksAndUnchecks() {
        #expect(toggled("- [ ] a", line: 0) == "- [x] a")
        #expect(toggled("- [x] a", line: 0) == "- [ ] a")
        #expect(toggled("- [X] a", line: 0) == "- [ ] a")
    }

    @Test func emptyBracketsGetAnXInserted() {
        #expect(toggled("- [] a", line: 0) == "- [x] a")
    }

    @Test func worksOnTheRightLineOfSeveral() {
        let text = "- [ ] one\n- [ ] two\n- [ ] three"
        #expect(toggled(text, line: 11) == "- [ ] one\n- [x] two\n- [ ] three")
    }

    @Test func indentedAndAlternateMarkers() {
        #expect(toggled("  * [ ] nested", line: 0) == "  * [x] nested")
    }

    @Test func nonChecklistLinesAreIgnored() {
        #expect(toggled("- plain", line: 0) == nil)
        #expect(toggled("text", line: 0) == nil)
        #expect(toggled("", line: 0) == nil)
        #expect(toggled("- [ ] a", line: 99) == nil)
    }

    @Test func theSelectionIsKept() {
        let edit = MarkdownEditing.toggleChecklist(in: "- [ ] a", atLine: 0, keepingSelection: NSRange(location: 5, length: 0))
        #expect(edit?.selection == NSRange(location: 5, length: 0))
    }
}
