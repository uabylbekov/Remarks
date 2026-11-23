import Foundation

/// Source ranges for offline equation and diagram previews. Ranges always address the original UTF-16 text.
public struct RichMarkdown: Equatable, Sendable {
    public enum Kind: String, Sendable { case inlineMath, displayMath, mermaid }
    public let kind: Kind
    public let range: NSRange
    public let content: String
    public var isInline: Bool { kind == .inlineMath }

    public static func scan(_ text: String, document existingDocument: MarkdownDocument? = nil) -> [Self] {
        guard text.contains("$") || text.localizedCaseInsensitiveContains("mermaid") else { return [] }
        let source = text as NSString
        let document = existingDocument ?? MarkdownDocument(text)
        var result: [Self] = []
        for block in document.blocks {
            switch block.kind {
            case .code(let code):
                if code.language == "mermaid", code.close != nil {
                    result.append(Self(kind: .mermaid, range: code.whole, content: source.substring(with: code.body)))
                }
            case .math(let math):
                result.append(Self(kind: .displayMath, range: math.whole, content: source.substring(with: math.body)))
            case .table, .attachment: break
            default:
                for line in block.lines(in: source) {
                    let value = source.substring(with: line)
                    guard value.contains("$") else { continue }
                    for span in InlineScanner.spans(in: value) where span.kind == .math {
                        result.append(Self(kind: .inlineMath,
                                           range: NSRange(location: line.location + span.range.location, length: span.range.length),
                                           content: (value as NSString).substring(with: span.content)))
                    }
                }
            }
        }
        return result
    }
}
