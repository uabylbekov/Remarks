import Testing
import Foundation
@testable import NotesCore

/// Ported from the highlighter spike's lab cases (specs/spikes/02-highlighter-spike.md).
struct SyntaxCase: Sendable, CustomTestStringConvertible {
    let language: String
    let name: String
    let source: String
    let expects: [(SyntaxScope, String)]
    let rejects: [(SyntaxScope, String)]

    var testDescription: String { "\(language): \(name)" }

    init(_ language: String, _ name: String, _ source: String,
         expects: [(SyntaxScope, String)] = [], rejects: [(SyntaxScope, String)] = []) {
        self.language = language
        self.name = name
        self.source = source
        self.expects = expects
        self.rejects = rejects
    }
}

struct SyntaxTests {
    static let cases: [SyntaxCase] = [
        SyntaxCase("swift", "keyword inside string and comment",
                   #"let x = "if \(a) // not a comment" // real"#,
                   expects: [(.keyword, "let"), (.string, #""if \(a) // not a comment""#), (.comment, "// real")],
                   rejects: [(.keyword, "if")]),
        SyntaxCase("swift", "multi-line block comment",
                   "/* a\n func b */ let c = 1",
                   expects: [(.comment, "/* a\n func b */"), (.keyword, "let"), (.number, "1")],
                   rejects: [(.keyword, "func")]),
        SyntaxCase("swift", "multi-line string",
                   "let s = \"\"\"\nline \"quoted\" if\n\"\"\"\nlet t = 2",
                   expects: [(.string, "\"\"\"\nline \"quoted\" if\n\"\"\""), (.number, "2")],
                   rejects: [(.keyword, "if")]),
        SyntaxCase("swift", "unterminated string does not run past the line",
                   "let s = \"abc\nlet t = 1",
                   expects: [(.keyword, "let"), (.number, "1")]),
        SyntaxCase("swift", "emoji and accents keep UTF-16 ranges correct",
                   "let s = \"héllo 😀\" // ok",
                   expects: [(.string, "\"héllo 😀\""), (.comment, "// ok")]),
        SyntaxCase("swift", "attribute, type and call",
                   "@MainActor func run() { Task { await go() } }",
                   expects: [(.attribute, "@MainActor"), (.keyword, "func"), (.function, "run"), (.type, "Task"), (.keyword, "await"), (.function, "go")]),
        SyntaxCase("python", "comment marker inside f-string, then real comment",
                   "s = f\"{x} # not\"  # real",
                   expects: [(.string, "f\"{x} # not\""), (.comment, "# real")]),
        SyntaxCase("python", "triple-quoted docstring with quotes",
                   "def f():\n    \"\"\"doc 'x' if\n    more\"\"\"\n    return 1",
                   expects: [(.keyword, "def"), (.function, "f"), (.string, "\"\"\"doc 'x' if\n    more\"\"\""), (.keyword, "return")],
                   rejects: [(.keyword, "if")]),
        SyntaxCase("python", "decorator and constants",
                   "@dataclass\nclass A:\n    x = None",
                   expects: [(.attribute, "@dataclass"), (.keyword, "class"), (.type, "A"), (.constant, "None")]),
        SyntaxCase("javascript", "template literal with expression",
                   "const t = `a ${b} c`; // done",
                   expects: [(.keyword, "const"), (.string, "`a ${b} c`"), (.comment, "// done")]),
        SyntaxCase("javascript", "TypeScript keywords",
                   "interface User { name: string }\nexport type Id = number",
                   expects: [(.keyword, "interface"), (.type, "User"), (.keyword, "export"), (.keyword, "type")]),
        SyntaxCase("json", "keys versus values",
                   #"{"name": "x", "n": -1.5e3, "ok": true, "z": null}"#,
                   expects: [(.property, "\"name\""), (.string, "\"x\""), (.number, "-1.5e3"), (.constant, "true"), (.constant, "null")],
                   rejects: [(.string, "\"name\"")]),
        SyntaxCase("bash", "variable, comment, quotes",
                   "echo \"hi $USER\" # c\nif [ -f x ]; then echo 'a b'; fi",
                   expects: [(.function, "echo"), (.string, "\"hi $USER\""), (.comment, "# c"), (.keyword, "if"), (.keyword, "then"), (.string, "'a b'"), (.keyword, "fi")]),
        SyntaxCase("bash", "variable outside quotes",
                   "cd ${HOME}/src && ls $1",
                   expects: [(.function, "cd"), (.variable, "${HOME}"), (.variable, "$1")]),
        SyntaxCase("sql", "case-insensitive keywords and comment",
                   "select name, COUNT(*) from users where id = 1 -- c",
                   expects: [(.keyword, "select"), (.function, "COUNT"), (.keyword, "from"), (.keyword, "where"), (.number, "1"), (.comment, "-- c")]),
        SyntaxCase("sql", "escaped quote in string",
                   "select 'it''s' from t",
                   expects: [(.string, "'it''s'")]),
        SyntaxCase("rust", "macro, lifetime and char",
                   "fn main() { let c = 'x'; println!(\"{}\", c); } // end",
                   expects: [(.keyword, "fn"), (.function, "main"), (.string, "'x'"), (.function, "println!"), (.comment, "// end")]),
        SyntaxCase("go", "raw string and defer",
                   "func main() {\n\tdefer f()\n\ts := `a\nb`\n}",
                   expects: [(.keyword, "func"), (.keyword, "defer"), (.string, "`a\nb`")]),
        SyntaxCase("c", "preprocessor and types",
                   "#include <stdio.h>\nint main(void) { return 0; }",
                   expects: [(.attribute, "#include"), (.keyword, "int"), (.function, "main"), (.keyword, "return"), (.number, "0")]),
        SyntaxCase("html", "tags, attributes, values and entities",
                   #"<div class="box" id='a'>Don't <b>bold</b> &amp; more</div>"#,
                   expects: [(.keyword, "div"), (.attribute, "class"), (.string, "\"box\""), (.attribute, "id"), (.string, "'a'"),
                             (.keyword, "b"), (.constant, "&amp;")],
                   rejects: [(.string, "'t <b>bold</b> &amp; more</div>")]),
        SyntaxCase("html", "doctype and a comment that holds a tag",
                   "<!DOCTYPE html>\n<!-- <p>note</p> -->\n<p>hi</p>",
                   expects: [(.attribute, "<!DOCTYPE html>"), (.comment, "<!-- <p>note</p> -->")],
                   rejects: [(.keyword, "html")]),
        SyntaxCase("html", "a closing tag and a multi-line attribute value",
                   "<a href=\"x\n y\">link</a>",
                   expects: [(.keyword, "a"), (.attribute, "href"), (.string, "\"x\n y\"")]),
        SyntaxCase("css", "class, property, hex color, unit and comment",
                   ".card { color: #ff0000; margin: 4px 0; /* note */ }",
                   expects: [(.type, ".card"), (.property, "color"), (.number, "#ff0000"), (.property, "margin"), (.number, "4px"),
                             (.number, "0"), (.comment, "/* note */")]),
        SyntaxCase("css", "pseudo-class is not a property, and a file name is not a class",
                   "a:hover { background: url(a.png) }",
                   expects: [(.keyword, "a"), (.attribute, ":hover"), (.property, "background"), (.function, "url")],
                   rejects: [(.property, "a"), (.type, ".png")]),
        SyntaxCase("css", "at-rule, !important and a value keyword",
                   "@media (min-width: 600px) { .x { display: none !important; } }",
                   expects: [(.keyword, "@media"), (.type, ".x"), (.property, "display"), (.constant, "none"), (.keyword, "!important")],
                   rejects: [(.property, "min-width")]),
        SyntaxCase("css", "custom properties and var()",
                   ":root { --main-color: blue; color: var(--main-color); }",
                   expects: [(.attribute, ":root"), (.variable, "--main-color"), (.property, "color"), (.function, "var")]),
        SyntaxCase("css", "a hyphenated property keeps its keyword-looking tail",
                   ".a { margin-left: 2rem; text-align: center }",
                   expects: [(.property, "margin-left"), (.number, "2rem"), (.property, "text-align"), (.constant, "center")],
                   rejects: [(.constant, "left")]),
    ]

    private func tokens(_ language: String, _ source: String) throws -> [(SyntaxScope, String)] {
        let engine = try #require(SyntaxGrammars.engine(forLanguage: language))
        let text = source as NSString
        return engine.tokens(in: source).map { ($0.scope, text.substring(with: $0.range)) }
    }

    @Test(arguments: cases)
    func highlightsAsExpected(_ testCase: SyntaxCase) throws {
        let found = try tokens(testCase.language, testCase.source)
        for (scope, text) in testCase.expects {
            #expect(found.contains { $0.0 == scope && $0.1 == text }, "missing \(scope) \(text.debugDescription)")
        }
        for (scope, text) in testCase.rejects {
            #expect(!found.contains { $0.0 == scope && $0.1 == text }, "unwanted \(scope) \(text.debugDescription)")
        }
    }

    // Regex cannot do these. They are documented limits, so the expectation is a known issue.

    @Test func nestedBlockCommentsAreAKnownLimit() throws {
        let found = try tokens("swift", "/* a /* b */ c */ let d")
        withKnownIssue("Regex cannot count nested comment depth") {
            #expect(found.contains { $0.0 == .comment && $0.1 == "/* a /* b */ c */" })
        }
    }

    @Test func interpolationContainingQuotesIsAKnownLimit() throws {
        let found = try tokens("swift", #"let s = "a \("b") c""#)
        withKnownIssue("Regex cannot parse nested string literals") {
            #expect(found.contains { $0.0 == .string && $0.1 == #""a \("b") c""# })
        }
    }

    @Test func javascriptRegexLiteralsAreAKnownLimit() throws {
        let found = try tokens("javascript", "const r = /ab+c\"d/g;")
        withKnownIssue("A slash is ambiguous with division without parsing context") {
            #expect(found.contains { $0.0 == .string && $0.1 == "/ab+c\"d/g" })
        }
    }

    // MARK: Engine

    @Test func everyBuiltInGrammarCompiles() {
        for grammar in SyntaxGrammars.all {
            #expect(SyntaxEngine(grammar) != nil, "\(grammar.name) failed to compile")
        }
    }

    @Test func aliasesResolveCaseInsensitively() {
        #expect(SyntaxGrammars.engine(forLanguage: "Swift") != nil)
        #expect(SyntaxGrammars.engine(forLanguage: "PY") != nil)
        #expect(SyntaxGrammars.engine(forLanguage: "ts") != nil)
        #expect(SyntaxGrammars.engine(forLanguage: "klingon") == nil)
    }

    @Test func rangeLimitsTokensToThatRange() throws {
        let engine = try #require(SyntaxGrammars.engine(forLanguage: "swift"))
        let source = "let a = 1\nlet b = 2"
        let second = NSRange(location: 10, length: 9)
        let found = engine.tokens(in: source, range: second)
        #expect(found.allSatisfy { NSLocationInRange($0.range.location, second) })
        #expect(found.contains { $0.scope == .number })
    }
}

struct CodeBlockScannerTests {
    @Test func findsABlockAndItsLanguage() {
        let text = "intro\n```Swift\nlet x = 1\n```\nafter"
        let blocks = CodeBlockScanner.scan(text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.language == "swift")
        let body = blocks.first.map { (text as NSString).substring(with: $0.body) }
        #expect(body == "let x = 1\n")
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        let text = "```py\nx = 1"
        let blocks = CodeBlockScanner.scan(text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.close == nil)
        #expect(blocks.first?.whole == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test func aFenceWithALanguageDoesNotCloseABlock() {
        let text = "```\ncode\n```js\nmore\n```\n"
        let blocks = CodeBlockScanner.scan(text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.close != nil)
    }

    @Test func aLongerOpenerNeedsAnAtLeastAsLongCloser() {
        let text = "````\n```\ninner\n```\n````\n"
        let blocks = CodeBlockScanner.scan(text)
        #expect(blocks.count == 1)
        let whole = blocks.first.map { (text as NSString).substring(with: $0.whole) }
        #expect(whole == text)
    }

    @Test func findsMultipleBlocksAndIgnoresNoteWithoutFences() {
        #expect(CodeBlockScanner.scan("just text\nmore").isEmpty)
        #expect(CodeBlockScanner.scan("```\na\n```\n\n```\nb\n```").count == 2)
    }

    @Test func emptyDocumentHasNoBlocks() {
        #expect(CodeBlockScanner.scan("").isEmpty)
    }
}
