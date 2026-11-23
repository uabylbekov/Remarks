import Testing
import Foundation
@testable import RemarksCore

struct MarkdownDocumentTests {
    private func kinds(_ text: String) -> [MarkdownDocument.Kind] { MarkdownDocument(text).blocks.map(\.kind) }
    private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    @Test func anEmptyStrikethroughOrBoldOnItsOwnLineIsNotABlock() {
        // What the Strikethrough and Bold commands write on an empty line, before anything is typed.
        for text in ["~~~~", "****"] {
            #expect(kinds(text) == [.paragraph], "\(text)")
        }
        // Real fences and rules are untouched.
        #expect(kinds("~~~\ncode\n~~~").count == 1)
        #expect(kinds("~~~~swift\ncode\n~~~~").count == 1)
        #expect(kinds("~~~~~\ncode\n~~~~~").count == 1)
        #expect(kinds("***") == [.rule])
    }

    @Test func anEmptyNoteHasNoBlocks() {
        let document = MarkdownDocument("")
        #expect(document.blocks.isEmpty)
        #expect(document.block(at: 0) == nil)
    }

    @Test func blocksCoverTheTextWithoutGapsOrOverlap() {
        let text = "# Title\n\n- a\n- [x] b\n> q\n---\n| a | b |\n| - | - |\n```swift\nlet a = 1\n```\nend"
        let document = MarkdownDocument(text)
        var expected = 0
        for block in document.blocks {
            #expect(block.range.location == expected)
            expected = NSMaxRange(block.range)
        }
        #expect(expected == (text as NSString).length)
    }

    @Test func classifiesOrdinaryLines() {
        let text = "## Head\n- item\n* star\n> quote\n***\nplain\n"
        let found = kinds(text)
        guard found.count == 6 else { Issue.record("expected 6 blocks, got \(found.count)"); return }
        #expect(found[0] == .heading(level: 2, marker: NSRange(location: 0, length: 3)))
        #expect(found[1] == .bullet(marker: NSRange(location: 8, length: 1)))
        #expect(found[2] == .bullet(marker: NSRange(location: 15, length: 1)))
        if case .quote(let marker) = found[3] { #expect(substring(text, marker) == "> ") } else { Issue.record("not a quote") }
        #expect(found[4] == .rule)
        #expect(found[5] == .paragraph)
    }

    @Test func aChecklistIsNotAPlainBullet() {
        let text = "- [ ] open\n- [x] done\n- [X] also done\n-\t[ ] tabbed\n- [] empty brackets\n"
        let found = kinds(text)
        let states = found.map { kind -> Bool? in
            if case .checklist(_, let checked) = kind { checked } else { nil }
        }
        #expect(states == [false, true, true, false, false])
    }

    @Test func aChecklistMarkIncludesItsTrailingSpace() {
        let text = "  - [ ] task"
        guard case .checklist(let mark, _) = kinds(text).first else { Issue.record("not a checklist"); return }
        #expect(substring(text, mark) == "- [ ] ")
    }

    @Test func aRuleNeedsThreeMarks() {
        #expect(kinds("---") == [.rule])
        #expect(kinds("* * *") == [.rule])
        #expect(kinds("--") == [.paragraph])
    }

    @Test func aFencedBlockIsOneBlockWithItsLanguage() {
        let text = "before\n```swift\nlet a = 1\n\nlet b = 2\n```\nafter"
        let document = MarkdownDocument(text)
        #expect(document.blocks.count == 3)
        guard case .code(let code) = document.blocks[1].kind else { Issue.record("no code block"); return }
        #expect(code.language == "swift")
        #expect(substring(text, document.blocks[1].range) == "```swift\nlet a = 1\n\nlet b = 2\n```\n")
        #expect(document.codeBlocks == [code])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        let text = "a\n```\nlet a = 1\n"
        let document = MarkdownDocument(text)
        guard case .code(let code) = document.blocks.last?.kind else { Issue.record("no code block"); return }
        #expect(code.close == nil)
        #expect(NSMaxRange(document.blocks.last?.range ?? NSRange()) == (text as NSString).length)
    }

    @Test func markdownInsideACodeBlockIsNotInterpreted() {
        let text = "```\n# not a heading\n- [ ] not a task\n| a | b |\n```\n"
        #expect(MarkdownDocument(text).blocks.count == 1)
    }

    @Test func tableRowsFormOneBlockAndOtherLinesEndIt() {
        let text = "| a | b |\n| - | - |\n| 1 | 2 |\ntext\n| c |\n"
        let document = MarkdownDocument(text)
        #expect(document.blocks.map(\.kind) == [.table, .paragraph, .table])
        #expect(substring(text, document.blocks[0].range) == "| a | b |\n| - | - |\n| 1 | 2 |\n")
    }

    @Test func aFenceEndsATableRun() {
        let text = "| a |\n```\ncode\n```\n"
        let document = MarkdownDocument(text)
        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].kind == .table)
    }

    @Test func attachmentLinesAreFound() {
        let id = UUID()
        let text = "![Beach](attachment://\(id.uuidString))\n"
        guard case .attachment(let line) = kinds(text).first else { Issue.record("not an attachment"); return }
        #expect(line.id == id)
        #expect(line.isImage)
    }

    @Test func blockAtAnOffsetFindsTheLineItIsOn() {
        let text = "# one\ntwo\nthree"
        let document = MarkdownDocument(text)
        #expect(document.block(at: 0)?.range == NSRange(location: 0, length: 6))
        #expect(document.block(at: 5)?.range == NSRange(location: 0, length: 6))
        #expect(document.block(at: 6)?.range == NSRange(location: 6, length: 4))
        // The end of the text belongs to the last line.
        #expect(document.block(at: 15)?.range == NSRange(location: 10, length: 5))
        #expect(document.block(at: 16) == nil)
        #expect(document.block(at: -1) == nil)
    }

    @Test func rangesStayCorrectAfterEmoji() {
        let text = "😀 text\n- [ ] 👍 task\n"
        let document = MarkdownDocument(text)
        guard case .checklist(let mark, _) = document.blocks[1].kind else { Issue.record("not a checklist"); return }
        #expect(substring(text, mark) == "- [ ] ")
    }

    @Test func linesOfABlockKeepTheirTerminators() {
        let text = "| a |\n| b |\n"
        let block = MarkdownDocument(text).blocks[0]
        #expect(block.lines(in: text as NSString).map { substring(text, $0) } == ["| a |\n", "| b |\n"])
    }
}

struct MarkdownDocumentUpdateTests {
    private func check(_ text: String, range: NSRange, replacement: String) {
        let next = (text as NSString).replacingCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        let update = MarkdownDocument(text).updating(next, editedRange: edited, changeInLength: edited.length - range.length)
        #expect(update.document == MarkdownDocument(next), "Edit at \(range) with \(replacement.debugDescription)")
        #expect(update.reparsedRange.location >= 0)
        #expect(NSMaxRange(update.reparsedRange) <= (next as NSString).length)
        #expect(NSMaxRange(update.redrawRange) <= (next as NSString).length)
    }

    @Test func ordinaryEditsParseLocalContextAndRedrawOnlyTheChangedLine() {
        let text = (0..<1_000).map { "Line \($0)\n" }.joined()
        let range = (text as NSString).range(of: "Line 500")
        let next = (text as NSString).replacingCharacters(in: range, with: "Changed")
        let update = MarkdownDocument(text).updating(next, editedRange: NSRange(location: range.location, length: 7),
                                                     changeInLength: 7 - range.length)
        #expect(update.document == MarkdownDocument(next))
        #expect(update.reparsedRange.length < 100)
        #expect(update.redrawRange == NSRange(location: range.location, length: 8))
    }

    @Test func editingEveryCharacterBoundaryMatchesFullParsing() {
        let texts = [
            "Title\n===\nbody\nSubtitle\n---\ntail", "~~~swift\ncode\n~~~\nafter\n",
            "", "# Heading\nplain\n- [ ] task\n> quote\nend",
            "| A |\n| --- |\n| B |\n\n| C |\n| --- |\n| D |",
            "` `\nplain\n```swift\nlet a = 1\n```\nafter\n",
            "before\n```\nunclosed\n",
            "😀 title\r\n- [x] 👩🏽‍💻\r\n| A |\r\n| --- |\r\n",
            "a\rb\r# c\r", "a\u{2028}b\u{2029}c"
        ]
        let replacements = ["", "x", "\n", "\r", "| X |\n", "```\n", "😀", "- [ ] ", "$$\n", "$$x$$\n"]
        for text in texts {
            let boundaries = text.indices.map { NSRange($0..<$0, in: text).location } + [(text as NSString).length]
            for (index, location) in boundaries.enumerated() {
                for replacement in replacements {
                    check(text, range: NSRange(location: location, length: 0), replacement: replacement)
                    if index + 1 < boundaries.count {
                        check(text, range: NSRange(location: location, length: boundaries[index + 1] - location), replacement: replacement)
                    }
                }
            }
            check(text, range: NSRange(location: 0, length: (text as NSString).length), replacement: "")
        }
    }

    @Test func successiveEditsMatchFullParsing() {
        var text = "# Start\n\n| A |\n| --- |\n| B |\n\n```swift\nlet a = 1\n```\nEnd\n"
        var document = MarkdownDocument(text)
        var random: UInt64 = 42
        func choose(_ limit: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int(random % UInt64(limit))
        }
        let replacements = ["", "x", "\n", "\r\n", "```", "| a |\n", "- [ ] ", "😀"]
        for _ in 0..<1_000 {
            let boundaries = text.indices.map { NSRange($0..<$0, in: text).location } + [(text as NSString).length]
            let first = choose(boundaries.count)
            let last = min(boundaries.count - 1, first + choose(5))
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = replacements[choose(replacements.count)]
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            let edited = NSRange(location: range.location, length: (replacement as NSString).length)
            let update = document.updating(text, editedRange: edited, changeInLength: edited.length - range.length)
            #expect(update.document == MarkdownDocument(text), "Source: \(text.debugDescription)")
            document = update.document
        }
    }
}

