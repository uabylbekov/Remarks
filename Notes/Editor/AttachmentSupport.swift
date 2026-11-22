import SwiftUI
import ImageIO
import NotesCore
import UniformTypeIdentifiers

// MARK: - Where an attachment comes from

enum AttachmentSource {
    case photoLibrary
    case camera
    case file
}

/// A file or picture taken from the clipboard, waiting to become an attachment.
struct PastedFile {
    let data: Data
    let fileName: String
    let type: UTType
}

// MARK: - What the editor needs to draw one

/// Everything the text layer needs about one attachment, so it never touches the SwiftData model while drawing.
struct AttachmentDisplay {
    let id: UUID
    let isImage: Bool
    let fileName: String
    let byteCount: Int
    let pixelSize: CGSize
    /// A screen-sized copy of an image. Nil while the data has not arrived (sync) or for files.
    let image: CGImage?
    let hasData: Bool
}

/// Looks attachments up for the open note and keeps decoded images, so drawing a line never decodes anything.
@MainActor
final class AttachmentCatalog {
    private let note: () -> Note
    private var images: [UUID: CGImage] = [:]
    /// The longest side of the cached copy. Enough for a wide text column on a Retina display.
    private static let thumbnailPixels = 1600

    init(note: @escaping () -> Note) {
        self.note = note
    }

    func display(for id: UUID) -> AttachmentDisplay? {
        guard let attachment = note().attachments?.first(where: { $0.id == id }) else { return nil }
        let isImage = AttachmentStore.isImage(attachment)
        var image = images[id]
        if isImage, image == nil, let data = attachment.data {
            image = Self.decode(data)
            images[id] = image
        }
        return AttachmentDisplay(
            id: id,
            isImage: isImage,
            fileName: attachment.fileName,
            byteCount: attachment.byteCount,
            pixelSize: CGSize(width: attachment.pixelWidth, height: attachment.pixelHeight),
            image: image,
            hasData: attachment.data != nil
        )
    }

    func attachment(with id: UUID) -> NotesCore.Attachment? {
        note().attachments?.first { $0.id == id }
    }

    /// Changes when attachments are added, removed, or their data arrives, so the editor knows to redraw.
    var signature: Int {
        var hasher = Hasher()
        for attachment in note().attachments ?? [] {
            hasher.combine(attachment.id)
            hasher.combine(attachment.data != nil)
        }
        return hasher.finalize()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Layout fragment

/// Draws an attachment line: the picture, or a file chip, over the line that holds its Markdown.
///
/// The line's height is fixed by the paragraph style (see `LivePreviewController.styleAttachment`), so it never
/// changes with the caret or with the data arriving. This fragment only paints into that space.
final class AttachmentFragment: NSTextLayoutFragment {
    weak var controller: LivePreviewController?

    private static let cornerRadius: CGFloat = 10
    static let chipHeight: CGFloat = 44

    private var paragraph: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    private var attachmentID: UUID? {
        guard let paragraph, paragraph.length > 0,
              let string = paragraph.attribute(LivePreviewController.attachmentKey, at: 0, effectiveRange: nil) as? String
        else { return nil }
        return UUID(uuidString: string)
    }

    private var reservedHeight: CGFloat {
        guard let paragraph, paragraph.length > 0,
              let value = paragraph.attribute(LivePreviewController.attachmentHeightKey, at: 0, effectiveRange: nil) as? NSNumber
        else { return Self.chipHeight }
        return CGFloat(value.doubleValue)
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }

    /// The area the attachment is drawn in, relative to the top left of the text container.
    private func contentRect(at origin: CGPoint) -> CGRect {
        CGRect(
            x: origin.x - layoutFragmentFrame.minX + padding,
            y: origin.y + (textLineFragments.first?.typographicBounds.minY ?? 0),
            width: max(0, containerWidth - 2 * padding),
            height: reservedHeight
        )
    }

    /// The drawn card, in text-container coordinates, also defines its interactive area.
    var attachmentBounds: CGRect {
        visibleRect(in: contentRect(at: layoutFragmentFrame.origin))
    }

    static func displaySize(in area: CGSize, display: AttachmentDisplay?) -> CGSize {
        if let display, display.isImage, let image = display.image {
            let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
            return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        }
        return CGSize(width: min(area.width, 340), height: min(area.height, Self.chipHeight))
    }

    private func visibleRect(in area: CGRect) -> CGRect {
        let display = attachmentID.flatMap { controller?.attachmentDisplay(for: $0) }
        return CGRect(origin: area.origin, size: Self.displaySize(in: area.size, display: display))
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let id = attachmentID else { return }
        let area = contentRect(at: point)
        let display = controller?.attachmentDisplay(for: id)

        context.saveGState()
        defer { context.restoreGState() }

        if let display, display.isImage, let image = display.image {
            drawImage(image, in: area, context: context)
        } else {
            drawChip(display, in: area, context: context)
        }
    }

    // MARK: Image

    private func drawImage(_ image: CGImage, in area: CGRect, context: CGContext) {
        let rect = visibleRect(in: area)

        context.addPath(CGPath(roundedRect: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil))
        context.clip()
        // Text layout draws with y growing downward, and CGContext draws images upright for y growing upward.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    }

    // MARK: Chip (files, and images that have not arrived yet)

    private func drawChip(_ display: AttachmentDisplay?, in area: CGRect, context: CGContext) {
        let chip = visibleRect(in: area)
        let height = chip.height
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(CGPath(roundedRect: chip, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil))
        context.fillPath()

        let title: String
        let detail: String
        let symbol: String
        if let display {
            title = display.fileName.isEmpty ? String(localized: "Attachment") : display.fileName
            if !display.hasData {
                detail = String(localized: "Waiting for iCloud…")
                symbol = "icloud.and.arrow.down"
            } else {
                detail = ByteCountFormatter.string(fromByteCount: Int64(display.byteCount), countStyle: .file)
                symbol = Self.symbol(for: display)
            }
        } else {
            title = String(localized: "Missing attachment")
            detail = ""
            symbol = "exclamationmark.triangle"
        }

        let iconSide: CGFloat = 22
        let icon = CGRect(x: chip.minX + 12, y: chip.midY - iconSide / 2, width: iconSide, height: iconSide)
        let textX = icon.maxX + 10
        let textWidth = max(0, chip.maxX - textX - 12)

        AttachmentDrawing.draw(symbol: symbol, in: icon, color: EditorTheme.accentColor, context: context)
        let titleFont = EditorFont.systemFont(ofSize: 14, weight: .medium)
        let detailFont = EditorFont.systemFont(ofSize: 12)
        if detail.isEmpty {
            AttachmentDrawing.draw(text: title, font: titleFont, color: EditorColor.primaryText,
                                   in: CGRect(x: textX, y: chip.midY - 9, width: textWidth, height: 18), context: context)
        } else {
            AttachmentDrawing.draw(text: title, font: titleFont, color: EditorColor.primaryText,
                                   in: CGRect(x: textX, y: chip.minY + 5, width: textWidth, height: 18), context: context)
            AttachmentDrawing.draw(text: detail, font: detailFont, color: EditorColor.secondaryText,
                                   in: CGRect(x: textX, y: chip.minY + 23, width: textWidth, height: 16), context: context)
        }
    }

    private static func symbol(for display: AttachmentDisplay) -> String {
        if display.isImage { return "photo" }
        let type = UTType(filenameExtension: (display.fileName as NSString).pathExtension)
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .audiovisualContent) == true { return "play.rectangle" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }
}

// MARK: - Drawing helpers

/// Draws SF Symbols and text into the text layout's `CGContext`, on both platforms.
@MainActor
enum AttachmentDrawing {
    /// A transparent native glyph reserves stable width for a custom-drawn preview element.
    static func placeholder(size: CGSize) -> NSTextAttachment {
        let attachment = NSTextAttachment(data: nil, ofType: nil)
        attachment.bounds = CGRect(origin: .zero, size: size)
        #if canImport(UIKit)
        attachment.image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #else
        attachment.image = NSImage(size: CGSize(width: 1, height: 1))
        #endif
        return attachment
    }

    static func draw(symbol: String, in rect: CGRect, color: EditorColor, context: CGContext) {
        #if canImport(UIKit)
        guard let image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        UIGraphicsPushContext(context)
        image.draw(in: fitted(image.size, in: rect))
        UIGraphicsPopContext()
        #else
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        push(context) {
            image.draw(in: fitted(image.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        #endif
    }

    static func draw(text: String, font: EditorFont, color: EditorColor, in rect: CGRect, context: CGContext) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        UIGraphicsPopContext()
        #else
        push(context) {
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        #endif
    }

    /// The largest rectangle with the image's proportions that fits in `rect`, centered.
    private static func fitted(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fit = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2, width: fit.width, height: fit.height)
    }

    #if canImport(AppKit)
    private static func push(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
    #endif
}

// MARK: - Opening

/// Writes an attachment to a temporary file, so the system's Quick Look can show it (`quickLookPreview`, in SwiftUI).
enum AttachmentFiles {
    static func temporaryURL(for attachment: NotesCore.Attachment) -> URL? {
        guard let data = attachment.data else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(attachment.fileName.isEmpty ? "Attachment" : attachment.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension EditorColor {
    static var primaryText: EditorColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }

    static var secondaryText: EditorColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }
}
