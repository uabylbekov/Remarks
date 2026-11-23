import SwiftUI
import RemarksCore

/// `![name](attachment://id)` or `[name](attachment://id)` on a line of its own: a picture or a file chip. The line keeps
/// its Markdown but reserves room for the picture or chip, which the layout fragment draws (see `AttachmentFragment`). The
/// height depends only on the attachment, never on the caret, so moving through the line shifts nothing. The Markdown
/// itself is never shown, unless Markdown is shown for the whole note. The caret rests at the end of the line, as tall as
/// the line, and Backspace there removes the attachment.
struct AttachmentElement: MarkdownElement {
    /// The tallest a picture is drawn, in points.
    private static let maxImageHeight: CGFloat = 280


    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .attachment(let attachment) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let display = services.attachmentProvider?(attachment.id)

        var height = AttachmentFragment.chipHeight
        if attachment.isImage, let display, display.isImage, display.pixelSize.height > 0 {
            // Pixels are shown at half size, which is how a Retina screen shows them, up to a maximum height.
            height = min(Self.maxImageHeight, max(AttachmentFragment.chipHeight, display.pixelSize.height / 2))
        }
        // A picture that has not arrived yet is a chip, so the card, the line, and the caret all measure the same.

        let area = CGSize(width: max(0, services.textContainerWidth - 2 * services.linePadding), height: height)
        let displaySize = AttachmentFragment.displaySize(in: area, display: display)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = displaySize.height
        style.maximumLineHeight = displaySize.height
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        // One line only, so a long link never makes the line taller.
        style.lineBreakMode = .byClipping
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: full)
        paragraph.addAttribute(LivePreviewController.attachmentKey, value: attachment.id.uuidString, range: full)
        paragraph.addAttribute(LivePreviewController.attachmentHeightKey, value: Double(height), range: full)

        // Use a native attachment glyph for selection geometry. This paragraph is display-only:
        // replacing one UTF-16 character preserves every source offset and the stored Markdown.
        paragraph.addAttributes([.foregroundColor: EditorColor.clear,
                                 .font: EditorFont.systemFont(ofSize: 0.01)], range: full)
        let placeholder = AttachmentDrawing.placeholder(size: displaySize)
        paragraph.replaceCharacters(in: NSRange(location: 0, length: 1), with: "\u{FFFC}")
        paragraph.addAttribute(.attachment, value: placeholder, range: NSRange(location: 0, length: 1))
        return true
    }

    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange] {
        prefixMark(of: block, in: source).map { [$0] } ?? []
    }

    /// The whole Markdown of the line, without its line break.
    func prefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange? {
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: block.range)
        return NSRange(location: block.range.location, length: max(0, contentsEnd - block.range.location))
    }
}
