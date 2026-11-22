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
    /// Finds backtick and tilde fences. Closers must use the same mark and at least the opening length.
    /// Fences inside list and quote containers remain separate from this top-level scanner.
    public static func scan(_ text: String) -> [CodeBlock] {
        let source = text as NSString
        var blocks: [CodeBlock] = []
        var opener: (line: NSRange, ticks: Int, marker: Character, language: String)?
        var location = 0

        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let trimmed = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = trimmed.first ?? " "
            let ticks = (marker == "`" || marker == "~") ? trimmed.prefix(while: { $0 == marker }).count : 0

            if let current = opener {
                if marker == current.marker, ticks >= max(3, current.ticks), trimmed.count == ticks {
                    blocks.append(CodeBlock(
                        open: current.line,
                        close: line,
                        whole: NSUnionRange(current.line, line),
                        language: current.language
                    ))
                    opener = nil
                }
            } else if ticks >= 3, !(marker == "~" && trimmed == "~~~~") {
                // `~~~~` alone is strikethrough switched on with nothing typed yet, which the Strikethrough command writes on
                // an empty line. Longer tilde fences, and any fence with a language, still open a block.
                let info = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
                if marker == "`", info.contains("`") { location = NSMaxRange(line); continue }
                let language = info.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
                opener = (line, ticks, marker, language)
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
