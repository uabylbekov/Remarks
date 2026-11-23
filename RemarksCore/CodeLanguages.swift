import Foundation

/// A language a code block can name after its opening fence, as offered in the language picker.
public struct CodeLanguage: Identifiable, Hashable, Sendable {
    /// What is written after the fence, for example "swift".
    public let id: String
    /// What the picker and the card show, for example "Swift".
    public let name: String
}

public enum CodeLanguages {
    /// The languages the editor colors, one entry each.
    public static let all: [CodeLanguage] = SyntaxGrammars.all.compactMap { grammar in
        grammar.aliases.first.map { CodeLanguage(id: $0, name: grammar.name) }
    }

    /// The name to show for the text written after a fence. Known languages and their aliases ("py") show their proper
    /// name, anything else shows as written, and no language shows as Plain Text.
    public static func displayName(for language: String) -> String {
        let key = language.lowercased()
        if key.isEmpty { return String(localized: "Plain Text", bundle: #bundle) }
        return SyntaxGrammars.engine(forLanguage: key)?.grammar.name ?? language
    }
}
