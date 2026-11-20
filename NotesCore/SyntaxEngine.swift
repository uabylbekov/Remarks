import Foundation

/// Grammar-driven syntax highlighting built only on `NSRegularExpression` (Spike 02).
/// A grammar is a plain `Codable` value: an ordered list of scope and pattern rules. The engine joins the rules
/// into ONE alternation and scans left to right, so an earlier construct (a comment, a string) always consumes
/// its text before a later rule can see it.
public enum SyntaxScope: String, Codable, Sendable, CaseIterable {
    case comment, string, keyword, number, type, function, attribute, constant, property, variable
}

public struct SyntaxRule: Codable, Sendable {
    public let scope: SyntaxScope
    /// ICU regex. Must not contain capturing groups; use `(?:...)`.
    public let pattern: String

    public init(scope: SyntaxScope, pattern: String) {
        self.scope = scope
        self.pattern = pattern
    }
}

public struct SyntaxGrammar: Codable, Sendable {
    public let name: String
    public let aliases: [String]
    public let ignoresCase: Bool
    /// Order is priority: when two rules could match at the same position, the earlier rule wins.
    public let rules: [SyntaxRule]

    public init(name: String, aliases: [String], ignoresCase: Bool, rules: [SyntaxRule]) {
        self.name = name
        self.aliases = aliases
        self.ignoresCase = ignoresCase
        self.rules = rules
    }
}

public struct SyntaxToken: Equatable, Sendable {
    public let scope: SyntaxScope
    /// UTF-16 range in the source string.
    public let range: NSRange

    public init(scope: SyntaxScope, range: NSRange) {
        self.scope = scope
        self.range = range
    }
}

public final class SyntaxEngine: @unchecked Sendable {
    public let grammar: SyntaxGrammar
    private let regex: NSRegularExpression
    private let scopes: [SyntaxScope]

    /// Returns nil if a pattern is invalid or contains its own capturing group (which would break scope lookup).
    public init?(_ grammar: SyntaxGrammar) {
        let combined = grammar.rules.map { "(\($0.pattern))" }.joined(separator: "|")
        let options: NSRegularExpression.Options = grammar.ignoresCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: combined, options: options),
              regex.numberOfCaptureGroups == grammar.rules.count else { return nil }
        self.grammar = grammar
        self.regex = regex
        self.scopes = grammar.rules.map(\.scope)
    }

    /// Tokens inside `range` (the whole string by default). Ranges are in the coordinates of `text`.
    public func tokens(in text: String, range: NSRange? = nil) -> [SyntaxToken] {
        let searchRange = range ?? NSRange(location: 0, length: (text as NSString).length)
        var result: [SyntaxToken] = []
        regex.enumerateMatches(in: text, options: [], range: searchRange) { match, _, _ in
            guard let match else { return }
            for index in 0..<scopes.count {
                let groupRange = match.range(at: index + 1)
                if groupRange.location != NSNotFound {
                    result.append(SyntaxToken(scope: scopes[index], range: groupRange))
                    break
                }
            }
        }
        return result
    }
}
