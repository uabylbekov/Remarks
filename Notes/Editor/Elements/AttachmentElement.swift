import SwiftUI
import NotesCore

/// `![name](attachment://id)` or `[name](attachment://id)` on a line of its own: a picture or a file chip. The line keeps
/// its Markdown but reserves room for the picture or chip, which the layout fragment draws (see `AttachmentFragment`). The
/// height depends only on the attachment, never on the caret, so moving through the line shifts nothing. The Markdown
/// itself shows only while the caret is on the line.
struct AttachmentElement: MarkdownElement {
    /// The tallest a picture is drawn, in points.
    private static let maxImageHeight: CGFloat = 280

    var readsInline: Bool { false }

    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .attachment(let attachment) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let display = services.attachmentProvider?(attachment.id)

        var height = AttachmentFragment.chipHeight
        if attachment.isImage, let display, display.isImage, display.pixelSize.height > 0 {
            // Pixels are shown at half size, which is how a Retina screen shows them, up to a maximum height.
            height = min(Self.maxImageHeight, max(AttachmentFragment.chipHeight, display.pixelSize.height / 2))
        } else if attachment.isImage {
            height = 120
        }

        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height + 8
        style.maximumLineHeight = height + 8
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        // One line only, so a long link never makes the line taller.
        style.lineBreakMode = .byClipping
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
        paragraph.addAttribute(LivePreviewController.attachmentKey, value: attachment.id.uuidString, range: full)
        paragraph.addAttribute(LivePreviewController.attachmentHeightKey, value: Double(height), range: full)

        if line.isActive {
            paragraph.addAttributes([.foregroundColor: EditorTheme.dimColor, .backgroundColor: EditorTheme.codeBackground], range: full)
        } else {
            paragraph.addAttribute(.foregroundColor, value: EditorColor.clear, range: full)
        }
        return true
    }
}
