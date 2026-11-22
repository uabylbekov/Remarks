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
            let text: String
            if insideFence {
                text = line
            } else if MarkdownEditing.isTableRow(line) {
                // A table row reads as its cells. The separator row (`|---|---|`) says nothing.
                guard !MarkdownEditing.isTableSeparator(line) else { continue }
                text = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                // An attachment line reads as its name, not as a link with an id in it.
                text = AttachmentLine.parse(line)?.label ?? strippingInlineMarks(from: strippingMarks(from: line))
            }
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

    /// The text of a line without the marks of bold, italic, strikethrough, code and links (a link keeps its label).
    private static func strippingInlineMarks(from line: String) -> String {
        let markers = InlineScanner.spans(in: line).flatMap(\.markers).sorted { $0.location > $1.location }
        var result = line as NSString
        for marker in markers { result = result.replacingCharacters(in: marker, with: "") as NSString }
        return (result as String).trimmingCharacters(in: .whitespaces)
    }

    private static func strippingMarks(from line: String) -> String {
        guard let leadingMarks else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return leadingMarks
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
