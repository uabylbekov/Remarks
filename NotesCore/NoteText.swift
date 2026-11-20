import Foundation

/// Derives the list title and snippet from a note's Markdown body (Spec 01, "Rules the model must enforce itself").
public enum NoteText {
    public static let maxTitleLength = 200
    public static let maxSnippetLength = 200

    /// Leading Markdown marks: headings, block quotes, bullets, task boxes, and ordered-list numbers.
    private static let leadingMarks = try? NSRegularExpression(
        pattern: #"^(?:#{1,6}(?:\s+|$)|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)+"#
    )

    /// - Returns: the first non-empty line without Markdown marks, and the following text joined into one line.
    ///   Fence marker lines (``` or ~~~) are skipped, but the code inside a fence is kept as text.
    public static func derive(from body: String) -> (title: String, snippet: String) {
        var title: String?
        var snippetParts: [String] = []
        var snippetLength = 0
        var insideFence = false

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            let text = insideFence ? line : strippingMarks(from: line)
            guard !text.isEmpty else { continue }

            if title == nil {
                title = String(text.prefix(maxTitleLength))
                continue
            }
            snippetParts.append(text)
            snippetLength += text.count + 1
            if snippetLength >= maxSnippetLength { break }
        }
        return (title ?? "", String(snippetParts.joined(separator: " ").prefix(maxSnippetLength)))
    }

    private static func strippingMarks(from line: String) -> String {
        guard let leadingMarks else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return leadingMarks
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
