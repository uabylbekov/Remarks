import SwiftUI

/// Display-only marker projection for a paragraph supplied to NSTextContentStorage.
/// Every hidden UTF-16 unit becomes a zero-advance character at the paragraph’s normal font size.
/// Source offsets remain identical, while native line and caret metrics no longer depend on a tiny font.
enum MarkdownDisplayProjection {
    static func hideMarkers(_ range: NSRange, in paragraph: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        paragraph.replaceCharacters(in: range, with: String(repeating: "\u{200B}", count: range.length))
        paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: range)
    }
}
