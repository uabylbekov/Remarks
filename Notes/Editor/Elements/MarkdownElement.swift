import SwiftUI
import NotesCore

/// One line of a block, as an element sees it.
struct ElementLine {
    /// The line in the stored text, with its line break. It is the same range as the paragraph being styled.
    let range: NSRange
    let block: MarkdownDocument.Block
    /// The caret is on this line. Only a few elements look different for it (a rule, an attachment).
    let isActive: Bool
}

/// What the live preview offers an element while it styles a line.
@MainActor
protocol ElementServices: AnyObject {
    /// Marks are shown (dimmed) instead of hidden.
    var showsMarkdown: Bool { get }
    var attachmentProvider: ((UUID) -> AttachmentDisplay?)? { get }
    /// The width of the text container, and the padding inside it at each side of a line.
    var textContainerWidth: CGFloat { get }
    var linePadding: CGFloat { get }
    /// The syntax colors of a fenced block.
    func syntaxTokens(for block: CodeBlock) -> [SyntaxToken]
    /// The caret is in, or the selection touches, a fenced block.
    func isActive(_ block: CodeBlock) -> Bool
    /// The table as a model, or nil when it is not a complete one (no separator row) and is shown as text.
    func tableModel(for block: MarkdownDocument.Block) -> MarkdownTable?
    /// How a table shown as text is sized to fit the width.
    func tableLayout(forRowAt range: NSRange) -> (run: NSRange, scale: CGFloat)
    func nextLineIsTableSeparator(after range: NSRange) -> Bool
}

/// One kind of Markdown block: a heading, a quote, a checklist item, a table, and so on. An element knows how its lines
/// look in the live preview, which marks it hides, and what Backspace does at the start of its line. Everything about one
/// element lives in its own file, so it can be fixed or replaced without reading the others. `MarkdownElements` has the
/// list, and `MarkdownDocument` decides which element a line belongs to.
///
/// To add an element:
/// 1. Teach `MarkdownDocument` to recognize it, with a new `Kind` and a test in `MarkdownDocumentTests`.
/// 2. The switch in `MarkdownElements` stops compiling. Add a type for it in a new file in this folder.
/// 3. Give the type `style`, and `hiddenMarks` and `prefixMark` if it hides a mark. If it needs a layout fragment to
///    draw something, put the fragment in the same file and return it from `textLayoutManager(_:textLayoutFragmentFor:in:)`.
@MainActor
protocol MarkdownElement {
    /// Whether bold, italic, code and links are read on this element's lines.
    var readsInline: Bool { get }

    /// Styles the paragraph that shows one line. Returns false when the line is left as it is.
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool

    /// The marks this element hides on a line, as positions in the stored text. Marks inside the text (bold, links) are
    /// not here: `readsInline` covers them.
    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange]

    /// The mark at the front of the line that Backspace takes away, turning the line back into plain text.
    func prefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange?
}

extension MarkdownElement {
    var readsInline: Bool { true }
    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange] { [] }
    func prefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange? { nil }
}

/// The elements, one for each kind of block. The switch has no `default`, so a new kind of block cannot be added to
/// `MarkdownDocument` without saying here which element draws it.
@MainActor
enum MarkdownElements {
    static func element(for kind: MarkdownDocument.Kind) -> any MarkdownElement {
        switch kind {
        case .paragraph: ParagraphElement()
        case .heading: HeadingElement()
        case .bullet: BulletElement()
        case .checklist: ChecklistElement()
        case .quote: QuoteElement()
        case .rule: RuleElement()
        case .attachment: AttachmentElement()
        case .code: CodeBlockElement()
        case .table: TableElement()
        }
    }
}
