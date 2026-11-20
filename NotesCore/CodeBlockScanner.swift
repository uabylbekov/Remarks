import Foundation

/// A fenced code block located in Markdown source. All ranges are UTF-16 and include line terminators.
public struct CodeBlock: Equatable, Sendable {
    /// The opening fence line, for example "```swift\n".
    public let open: NSRange
    /// The closing fence line. Nil when the fence is never closed (the block then runs to the end).
    public let close: NSRange?
    public let whole: NSRange
    /// The language named on the opening fence, lowercased. Empty if none.
    public let language: String

    /// The lines between the fences.
    public var body: NSRange {
        let start = NSMaxRange(open)
        let end = close?.location ?? NSMaxRange(whole)
        return NSRange(location: start, length: max(0, end - start))
    }
}

public enum CodeBlockScanner {
    /// Finds fenced blocks. A closing fence is a line made only of backticks, at least as long as the opener.
    /// Known gaps (Spec 03): `~~~` fences and fences nested in lists or block quotes.
    public static func scan(_ text: String) -> [CodeBlock] {
        let source = text as NSString
        var blocks: [CodeBlock] = []
        var opener: (line: NSRange, ticks: Int, language: String)?
        var location = 0

        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let trimmed = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let ticks = trimmed.prefix(while: { $0 == "`" }).count

            if let current = opener {
                if ticks >= max(3, current.ticks), trimmed.count == ticks {
                    blocks.append(CodeBlock(
                        open: current.line,
                        close: line,
                        whole: NSUnionRange(current.line, line),
                        language: current.language
                    ))
                    opener = nil
                }
            } else if ticks >= 3 {
                let info = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
                let language = info.split(separator: " ").first.map { String($0).lowercased() } ?? ""
                opener = (line, ticks, language)
            }
            location = NSMaxRange(line)
        }

        if let current = opener {
            let whole = NSRange(location: current.line.location, length: source.length - current.line.location)
            blocks.append(CodeBlock(open: current.line, close: nil, whole: whole, language: current.language))
        }
        return blocks
    }
}
