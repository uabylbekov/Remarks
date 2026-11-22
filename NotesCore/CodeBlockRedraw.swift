import Foundation

/// Which lines of a fenced block to style again after an edit inside it.
///
/// A block is one parsed element, so it counts as changed whenever any of its text does. Styling every line of it for a
/// single keystroke makes a long block lay out again from top to bottom, which is what makes the page jump while typing.
/// A line needs styling again only when its own text changed or its syntax colors did, so this finds exactly those.
public enum CodeBlockRedraw {
    private struct Key: Hashable {
        let scope: SyntaxScope
        let location: Int
        let length: Int

        init(_ token: SyntaxToken) {
            scope = token.scope
            location = token.range.location
            length = token.range.length
        }
    }

    /// The whole lines to style again, or nil when the edit is not a plain edit of a closed block's body (its fences or
    /// language changed, or it was never closed), where the caller restyles the whole block.
    /// - Parameters:
    ///   - oldTokens: the block's tokens before the edit, in the old text's offsets.
    ///   - newTokens: the block's tokens after it, in the new text's offsets.
    ///   - editedRange: the changed text, in the new text's offsets.
    public static func range(oldBlock: CodeBlock, newBlock: CodeBlock, oldTokens: [SyntaxToken], newTokens: [SyntaxToken],
                             editedRange: NSRange, changeInLength delta: Int, in text: NSString) -> NSRange? {
        guard let oldClose = oldBlock.close, let newClose = newBlock.close,
              oldBlock.open == newBlock.open, oldBlock.language == newBlock.language,
              newClose == NSRange(location: oldClose.location + delta, length: oldClose.length),
              editedRange.location >= NSMaxRange(newBlock.open), NSMaxRange(editedRange) <= newClose.location else { return nil }

        // The text that changed, including the line it was split into or joined from.
        var affected = NSUnionRange(text.lineRange(for: NSRange(location: editedRange.location, length: 0)),
                                    text.lineRange(for: NSRange(location: NSMaxRange(editedRange), length: 0)))

        // Tokens the edit did not touch keep their meaning, shifted if they come after it. One that overlapped the edit
        // is gone, and so is everything it colored, so its lines change too.
        let removedEnd = NSMaxRange(editedRange) - delta
        var kept = Set<Key>()
        for token in oldTokens {
            let range = token.range
            if NSMaxRange(range) <= editedRange.location {
                kept.insert(Key(token))
            } else if range.location >= removedEnd {
                kept.insert(Key(SyntaxToken(scope: token.scope, range: NSRange(location: range.location + delta, length: range.length))))
            } else {
                let end = max(editedRange.location, NSMaxRange(range) + delta)
                affected = NSUnionRange(affected, NSRange(location: range.location, length: end - range.location))
            }
        }

        // A token that exists on only one side is a color that changed, wherever it is.
        let now = Set(newTokens.map(Key.init))
        for key in kept.symmetricDifference(now) {
            affected = NSUnionRange(affected, NSRange(location: key.location, length: key.length))
        }

        let body = NSIntersectionRange(affected, NSRange(location: NSMaxRange(newBlock.open), length: newClose.location - NSMaxRange(newBlock.open)))
        guard body.length > 0 else { return nil }
        return text.lineRange(for: body)
    }
}
