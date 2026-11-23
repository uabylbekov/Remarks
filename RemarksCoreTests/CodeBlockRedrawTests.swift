import Testing
import Foundation
@testable import RemarksCore

struct CodeBlockRedrawTests {
    private let source: String = {
        let lines = (0..<120).map { "    let value\($0) = \"text \($0)\" // note \($0)" }
        return "Intro\n\n```swift\n" + lines.joined(separator: "\n") + "\n```\n\nOutro\n"
    }()

    private func tokens(_ text: String, _ block: CodeBlock) -> [SyntaxToken] {
        guard let engine = SyntaxGrammars.engine(forLanguage: block.language) else { return [] }
        return engine.tokens(in: text, range: block.body).sorted { $0.range.location < $1.range.location }
    }

    /// The redraw for replacing `range` of `text` with `replacement`, plus the old and new text.
    private func redraw(_ text: String, replacing range: NSRange, with replacement: String)
        -> (range: NSRange?, old: String, new: String, oldTokens: [SyntaxToken], newTokens: [SyntaxToken], delta: Int)? {
        guard let oldBlock = CodeBlockScanner.scan(text).first else { return nil }
        let new = (text as NSString).replacingCharacters(in: range, with: replacement)
        guard let newBlock = CodeBlockScanner.scan(new).first else { return nil }
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        let delta = edited.length - range.length
        let oldTokens = tokens(text, oldBlock)
        let newTokens = tokens(new, newBlock)
        let result = CodeBlockRedraw.range(oldBlock: oldBlock, newBlock: newBlock, oldTokens: oldTokens, newTokens: newTokens,
                                           editedRange: edited, changeInLength: delta, in: new as NSString)
        return (result, text, new, oldTokens, newTokens, delta)
    }

    @Test func typingACharacterRestylesOnlyItsLine() throws {
        let location = (source as NSString).range(of: "value60").location
        let result = try #require(redraw(source, replacing: NSRange(location: location, length: 0), with: "x"))
        let range = try #require(result.range)
        #expect(range.length < 80, "one line of 120, not the block: \(range)")
        #expect(NSLocationInRange(location, range))
    }

    @Test func returnRestylesTheTwoLinesItMakes() throws {
        let location = (source as NSString).range(of: "= \"text 60\"").location
        let result = try #require(redraw(source, replacing: NSRange(location: location, length: 0), with: "\n"))
        let range = try #require(result.range)
        #expect(range.length < 120, "the split line, not the block: \(range)")
        #expect((result.new as NSString).substring(with: range).contains("\n"))
    }

    @Test func openingABlockCommentRestylesEverythingItNowCovers() throws {
        // A comment is closed twenty lines down, so opening it above turns those lines into comment.
        let closing = (source as NSString).range(of: "let value30").location
        let closed = (source as NSString).replacingCharacters(in: NSRange(location: closing, length: 0), with: "*/ ")
        let location = (closed as NSString).range(of: "let value10").location
        let result = try #require(redraw(closed, replacing: NSRange(location: location, length: 0), with: "/* "))
        let range = try #require(result.range)
        let end = (result.new as NSString).range(of: "*/ ").location
        #expect(range.location <= location)
        #expect(NSMaxRange(range) > end, "covers the line that closes the comment: \(range)")
        // But not the lines after it, which keep their colors.
        #expect(NSMaxRange(range) < (result.new as NSString).range(of: "let value40").location)
    }

    @Test func aChangedFenceOrLanguageRestylesTheWholeBlock() throws {
        let open = (source as NSString).range(of: "```swift")
        #expect(try #require(redraw(source, replacing: NSRange(location: open.location + 3, length: 5), with: "")).range == nil)
        let close = (source as NSString).range(of: "\n```\n\nOutro")
        #expect(try #require(redraw(source, replacing: NSRange(location: close.location + 1, length: 0), with: "x")).range == nil)
        // An unclosed block has no closing fence to anchor on.
        let unclosed = "```swift\nlet a = 1\nlet b = 2"
        let location = (unclosed as NSString).range(of: "a").location
        #expect(try #require(redraw(unclosed, replacing: NSRange(location: location, length: 0), with: "x")).range == nil)
    }

    /// The contract: whatever lies outside the lines it returns keeps the color it had.
    @Test func nothingOutsideTheRedrawRangeChangesColor() throws {
        let text = "```swift\n/* a\n b */\nlet s = \"x\"\n// c\nlet n = 1\nfunc f() {}\n```\n"
        let replacements = ["", "x", "\n", "/*", "*/", "\"", "//", " ", "1", "func "]
        let count = (text as NSString).length
        var checked = 0
        for location in 0..<count {
            for length in [0, 1, 2] where location + length <= count {
                for replacement in replacements {
                    let range = NSRange(location: location, length: length)
                    guard let result = redraw(text, replacing: range, with: replacement), let redrawn = result.range else { continue }
                    let oldColors = colors(result.oldTokens, length: (result.old as NSString).length)
                    let newColors = colors(result.newTokens, length: (result.new as NSString).length)
                    let removedEnd = NSMaxRange(range)
                    let editEnd = location + (replacement as NSString).length
                    for index in 0..<(result.new as NSString).length where !NSLocationInRange(index, redrawn) {
                        // Where this character was before the edit, if it is not part of what was typed.
                        let before: Int?
                        if index < location { before = index } else if index >= editEnd { before = index - result.delta } else { before = nil }
                        guard let before, before >= 0, before < oldColors.count, !(before >= location && before < removedEnd) else { continue }
                        #expect(newColors[index] == oldColors[before], "\(range) -> \(replacement.debugDescription): index \(index) outside \(redrawn)")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked > 200)
    }

    private func colors(_ tokens: [SyntaxToken], length: Int) -> [SyntaxScope?] {
        var result = [SyntaxScope?](repeating: nil, count: length)
        for token in tokens {
            for index in token.range.location..<min(length, NSMaxRange(token.range)) { result[index] = token.scope }
        }
        return result
    }
}
