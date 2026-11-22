import Foundation

/// Starter grammars (Spike 02). Swift values for now, but `Codable` data, so they could move to bundled files.
public enum SyntaxGrammars {
    private static let tripleDouble = "\"\"\""

    private static func rule(_ scope: SyntaxScope, _ pattern: String) -> SyntaxRule {
        SyntaxRule(scope: scope, pattern: pattern)
    }

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static let cStyleComments = [
        rule(.comment, #"//[^\n]*"#),
        rule(.comment, #"/\*[\s\S]*?\*/"#),
    ]

    private static let doubleQuoted = #""(?:\\.|[^"\\\n])*""#
    private static let singleQuoted = #"'(?:\\.|[^'\\\n])*'"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let call = #"\b[a-z_][A-Za-z0-9_]*(?=\()"#
    private static let capitalized = #"\b[A-Z][A-Za-z0-9_]*\b"#

    public static let all: [SyntaxGrammar] = [swift, python, javascript, json, bash, sql, rust, go, c, html, css]

    /// Compiled engines keyed by every alias. Compiling the combined regex is the expensive part, so do it once.
    private static let enginesByAlias: [String: SyntaxEngine] = {
        var map: [String: SyntaxEngine] = [:]
        for grammar in all {
            guard let engine = SyntaxEngine(grammar) else { continue }
            for alias in grammar.aliases { map[alias] = engine }
        }
        return map
    }()

    /// The engine for a fence language such as "swift" or "py". Nil if the language is unknown.
    public static func engine(forLanguage language: String) -> SyntaxEngine? {
        enginesByAlias[language.lowercased()]
    }

    public static let swift = SyntaxGrammar(name: "Swift", aliases: ["swift"], ignoresCase: false, rules: cStyleComments + [
        rule(.string, tripleDouble + #"[\s\S]*?"# + tripleDouble),
        rule(.string, doubleQuoted),
        rule(.attribute, #"[@#][A-Za-z_]\w*"#),
        rule(.number, number),
        rule(.keyword, words("func let var struct class enum protocol extension if else guard switch case default for while repeat return break continue import in is as try await async throws throw defer do catch init deinit self Self super static private public internal fileprivate open final override where associatedtype typealias subscript some any actor nonisolated mutating inout")),
        rule(.constant, words("true false nil")),
        rule(.function, call),
        rule(.type, capitalized),
    ])

    public static let python = SyntaxGrammar(name: "Python", aliases: ["python", "py"], ignoresCase: false, rules: [
        rule(.comment, #"#[^\n]*"#),
        rule(.string, #"[rRbBfFuU]{0,2}(?:"# + tripleDouble + #"[\s\S]*?"# + tripleDouble + #"|'''[\s\S]*?''')"#),
        rule(.string, #"[rRbBfFuU]{0,2}(?:"# + doubleQuoted + "|" + singleQuoted + ")"),
        rule(.attribute, #"@[A-Za-z_][\w.]*"#),
        rule(.number, number),
        rule(.keyword, words("def class if elif else for while return import from as with try except finally raise pass break continue lambda yield global nonlocal assert del in is not and or async await match case")),
        rule(.constant, words("True False None")),
        rule(.function, call),
        rule(.type, capitalized),
    ])

    public static let javascript = SyntaxGrammar(name: "JavaScript/TypeScript", aliases: ["javascript", "js", "typescript", "ts", "jsx", "tsx"], ignoresCase: false, rules: cStyleComments + [
        rule(.string, #"`(?:\\.|[^`\\])*`"#),
        rule(.string, doubleQuoted),
        rule(.string, singleQuoted),
        rule(.attribute, #"@[A-Za-z_]\w*"#),
        rule(.number, number),
        rule(.keyword, words("function const let var if else for while do return import export from as default class extends new this super typeof instanceof in of try catch finally throw switch case break continue async await yield static get set interface type enum implements public private protected readonly declare namespace")),
        rule(.constant, words("true false null undefined NaN Infinity")),
        rule(.function, call),
        rule(.type, capitalized),
    ])

    public static let json = SyntaxGrammar(name: "JSON", aliases: ["json", "jsonc"], ignoresCase: false, rules: [
        rule(.property, doubleQuoted + #"(?=\s*:)"#),
        rule(.string, doubleQuoted),
        rule(.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        rule(.constant, words("true false null")),
    ])

    public static let bash = SyntaxGrammar(name: "Shell", aliases: ["bash", "sh", "shell", "zsh"], ignoresCase: false, rules: [
        rule(.comment, #"(?:^|(?<=\s))#[^\n]*"#),
        rule(.string, #"'[^']*'"#),
        rule(.string, #""(?:\\.|[^"\\])*""#),
        rule(.variable, #"\$(?:\{[^}\n]*\}|[A-Za-z_]\w*|[0-9@#?$!*-])"#),
        rule(.number, #"\b\d+\b"#),
        rule(.keyword, words("if then else elif fi for while until do done case esac in function select return exit export local readonly unset source alias")),
        rule(.function, words("echo cd ls cat grep sed awk find mkdir rm cp mv git curl chmod chown sudo xargs sort uniq head tail printf read test")),
    ])

    public static let sql = SyntaxGrammar(name: "SQL", aliases: ["sql", "sqlite", "postgres", "mysql"], ignoresCase: true, rules: [
        rule(.comment, #"--[^\n]*"#),
        rule(.comment, #"/\*[\s\S]*?\*/"#),
        rule(.string, #"'(?:''|[^'])*'"#),
        rule(.number, #"\b\d+(?:\.\d+)?\b"#),
        rule(.keyword, words("select from where and or not in is null like between join inner outer left right full cross on group by order having limit offset insert into values update set delete create table drop alter add column index primary key foreign references unique default as distinct union all case when then else end exists asc desc with")),
        rule(.function, #"\b[A-Za-z_]\w*(?=\()"#),
    ])

    public static let rust = SyntaxGrammar(name: "Rust", aliases: ["rust", "rs"], ignoresCase: false, rules: cStyleComments + [
        rule(.string, #""(?:\\.|[^"\\])*""#),
        rule(.string, #"'(?:\\.|[^'\\\n])'"#),
        rule(.attribute, #"#!?\[[^\]\n]*\]"#),
        rule(.number, number),
        rule(.keyword, words("fn let mut const static struct enum impl trait pub use mod crate self Self super if else match for while loop return break continue as in ref move async await dyn where type unsafe extern")),
        rule(.constant, words("true false None Some Ok Err")),
        rule(.function, #"\b[a-z_][A-Za-z0-9_]*!?(?=\()"#),
        rule(.type, capitalized),
    ])

    public static let go = SyntaxGrammar(name: "Go", aliases: ["go", "golang"], ignoresCase: false, rules: cStyleComments + [
        rule(.string, #"`[^`]*`"#),
        rule(.string, doubleQuoted),
        rule(.string, #"'(?:\\.|[^'\\\n])'"#),
        rule(.number, number),
        rule(.keyword, words("func var const type struct interface map chan package import if else for range switch case default return break continue go defer select fallthrough goto")),
        rule(.constant, words("true false nil iota")),
        rule(.function, call),
        rule(.type, capitalized),
    ])

    public static let c = SyntaxGrammar(name: "C/C++", aliases: ["c", "cpp", "c++", "h", "objc", "objective-c"], ignoresCase: false, rules: cStyleComments + [
        rule(.string, doubleQuoted),
        rule(.string, #"'(?:\\.|[^'\\\n])+'"#),
        rule(.attribute, #"(?m:^[ \t]*#[ \t]*\w+)"#),
        rule(.number, number),
        rule(.keyword, words("if else for while do switch case default break continue return goto struct union enum typedef static extern const volatile sizeof inline void int char short long float double unsigned signed class public private protected namespace template typename using new delete this virtual override auto bool")),
        rule(.constant, words("true false NULL nullptr")),
        rule(.function, call),
        rule(.type, capitalized),
    ])

    /// Markup has no state in a flat regex, so each part is found by what surrounds it: a tag name follows `<` or `</`, a
    /// string is the value after `=`, an attribute is a name before `=`. Text content is left alone, and so is what is
    /// inside `<script>` and `<style>`, which stay uncolored.
    public static let html = SyntaxGrammar(name: "HTML", aliases: ["html", "htm", "xhtml", "xml", "svg"], ignoresCase: true, rules: [
        rule(.comment, #"<!--[\s\S]*?-->"#),
        rule(.attribute, #"<![A-Za-z]+[^>\n]*>"#),
        rule(.string, #"(?<==)"[^"]*""#),
        rule(.string, #"(?<==)'[^']*'"#),
        rule(.keyword, #"(?<=<|</)[A-Za-z][\w:-]*"#),
        rule(.attribute, #"[A-Za-z_:@][\w:.-]*(?=\s*=)"#),
        rule(.constant, #"&(?:[A-Za-z]+|#\d+|#x[0-9A-Fa-f]+);"#),
    ])

    /// A declaration's property is the name before a `:` whose value ends in `;` or `}`, which is what tells it from a
    /// pseudo-class such as `a:hover`. A selector is a name that comes before a `{` with no `;` or `}` in between.
    public static let css = SyntaxGrammar(name: "CSS", aliases: ["css"], ignoresCase: true, rules: [
        rule(.comment, #"/\*[\s\S]*?\*/"#),
        rule(.string, doubleQuoted),
        rule(.string, singleQuoted),
        rule(.keyword, #"@[A-Za-z-]+"#),
        rule(.keyword, #"!\s*important"#),
        rule(.variable, #"--[A-Za-z0-9_-]+"#),
        rule(.property, #"[A-Za-z-]+(?=\s*:\s*[^;{}]*[;}])"#),
        rule(.number, #"#(?:[0-9a-f]{8}|[0-9a-f]{6}|[0-9a-f]{3,4})\b"#),
        rule(.number, #"(?<![\w#.-])-?(?:\d+\.?\d*|\.\d+)(?:px|rem|em|vh|vw|vmin|vmax|ms|s|deg|fr|pt|cm|mm|in|%)?"#),
        rule(.type, #"[.#][A-Za-z_-][\w-]*(?=[^{};]*\{)"#),
        rule(.keyword, words("html body div span p a ul ol li h1 h2 h3 h4 h5 h6 img button input section header footer nav main table tr td th form label textarea select svg article aside figure video canvas code pre small strong em") + #"(?=[^{};]*\{)"#),
        rule(.attribute, #"::?[A-Za-z-]+(?=[^{};]*\{)"#),
        rule(.function, #"[A-Za-z-]+(?=\()"#),
        rule(.constant, #"(?<![\w-])(?:none|auto|inherit|initial|unset|normal|bold|italic|solid|dashed|dotted|block|inline|flex|grid|absolute|relative|fixed|sticky|static|center|left|right|top|bottom|transparent|hidden|visible|nowrap|pointer)(?![\w-])"#),
    ])
}
