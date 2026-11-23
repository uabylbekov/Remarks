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

public struct MathBlock: Equatable, Sendable {
    public let open: NSRange
    public let close: NSRange
    public let whole: NSRange
    public let body: NSRange
}

/// One top-level fence scanner establishes precedence: math is literal inside code, and code is literal inside math.
enum FencedBlock {
    case code(CodeBlock)
    case math(MathBlock)
    var range: NSRange {
        switch self {
        case .code(let block): block.whole
        case .math(let block): block.whole
        }
    }
}

public enum CodeBlockScanner {
    /// Finds backtick and tilde fences. Closers must use the same mark and at least the opening length.
    /// Fences inside list and quote containers remain separate from this top-level scanner.
    public static func scan(_ text: String) -> [CodeBlock] {
        fencedBlocks(in: text).compactMap { if case .code(let code) = $0 { code } else { nil } }
    }

    static func fencedBlocks(in text: String) -> [FencedBlock] {
        let source = text as NSString
        var blocks: [FencedBlock] = []
        var opener: (line: NSRange, ticks: Int, marker: Character, language: String)?
        var location = 0

        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            var contentsEnd = 0
            source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
            let rawLine = source.substring(with: NSRange(location: line.location, length: contentsEnd - line.location))
            let leadingSpaces = rawLine.prefix { $0 == " " }.count
            // CommonMark fences allow 0–3 leading spaces; deeper indentation or leading tabs are not fences.
            guard leadingSpaces <= 3, !rawLine.hasPrefix("\t") else {
                location = NSMaxRange(line)
                continue
            }
            let trimmed = String(rawLine.dropFirst(leadingSpaces)).trimmingCharacters(in: .whitespaces)
            if opener == nil, let math = mathBlock(startingAt: line, trimmed: trimmed, in: source) {
                blocks.append(.math(math))
                location = NSMaxRange(math.whole)
                continue
            }
            let marker = trimmed.first ?? " "
            let ticks = (marker == "`" || marker == "~") ? trimmed.prefix(while: { $0 == marker }).count : 0

            if let current = opener {
                if marker == current.marker, ticks >= max(3, current.ticks), trimmed.count == ticks {
                    blocks.append(.code(CodeBlock(
                        open: current.line,
                        close: line,
                        whole: NSUnionRange(current.line, line),
                        language: current.language
                    )))
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
            blocks.append(.code(CodeBlock(open: current.line, close: nil, whole: whole, language: current.language)))
        }
        return blocks
    }

    private static func mathBlock(startingAt line: NSRange, trimmed: String, in source: NSString) -> MathBlock? {
        guard trimmed.hasPrefix("$$") else { return nil }
        let contentRange = source.range(of: "$$", options: [], range: line)
        if trimmed.count > 4, trimmed.hasSuffix("$$") {
            let content = trimmed.dropFirst(2).dropLast(2)
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let close = NSRange(location: contentRange.location + trimmed.utf16.count - 2, length: 2)
            return MathBlock(open: contentRange, close: close, whole: line,
                             body: NSRange(location: NSMaxRange(contentRange), length: close.location - NSMaxRange(contentRange)))
        }
        guard trimmed == "$$" else { return nil }
        var location = NSMaxRange(line)
        while location < source.length {
            let next = source.lineRange(for: NSRange(location: location, length: 0))
            let raw = source.substring(with: next).trimmingCharacters(in: .newlines)
            let spaces = raw.prefix { $0 == " " }.count
            if spaces <= 3, !raw.hasPrefix("\t"), String(raw.dropFirst(spaces)).trimmingCharacters(in: .whitespaces) == "$$" {
                return MathBlock(open: line, close: next, whole: NSUnionRange(line, next),
                                 body: NSRange(location: NSMaxRange(line), length: next.location - NSMaxRange(line)))
            }
            location = NSMaxRange(next)
        }
        return nil
    }

}
