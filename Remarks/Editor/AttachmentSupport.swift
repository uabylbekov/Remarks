import SwiftUI
import SwiftData
import ImageIO
import QuickLookThumbnailing
import RemarksCore
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
    /// A decoded image or document thumbnail. Nil until available, or for unsupported file types.
    let image: CGImage?
    let hasData: Bool
}

/// Looks attachments up for the open note and keeps decoded images, so drawing a line never touches SwiftData or
/// decodes on the main thread.
@MainActor
final class AttachmentCatalog {
    private struct SnapshotEntry {
        let isImage: Bool
        let fileName: String
        let byteCount: Int
        let pixelSize: CGSize
        let hasData: Bool
    }

    private let note: () -> Note
    private let images: NSCache<NSUUID, CGImage> = {
        let cache = NSCache<NSUUID, CGImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var snapshot: [UUID: SnapshotEntry] = [:]
    private var snapshotNoteID: UUID?
    private var snapshotSignature: Int?
    private var inFlight: Set<UUID> = []
    /// Attachments whose image payload failed to decode; cleared if new data arrives so we never retry in a loop.
    private var failedIDs: Set<UUID> = []
    private var decodeTasks: [UUID: Task<Void, Never>] = [:]
    /// Called on the main actor when a background thumbnail decode finishes, so the editor redraws the image.
    var onImageDecoded: ((UUID) -> Void)?
    /// The longest side of the cached copy. Enough for a wide text column on a Retina display.
    private static let thumbnailPixels = 1600

    init(note: @escaping () -> Note) {
        self.note = note
    }

    deinit {
        for task in decodeTasks.values { task.cancel() }
    }

    /// Rebuilds the lightweight attachment metadata snapshot from SwiftData. Call outside drawing (on load or update).
    func refreshSnapshot() {
        let current = note()
        guard !current.isDeleted, current.modelContext != nil else {
            reset()
            return
        }
        if snapshotNoteID != current.id {
            reset()
            snapshotNoteID = current.id
        }
        var next: [UUID: SnapshotEntry] = [:]
        for attachment in current.attachments ?? [] {
            let entry = SnapshotEntry(
                isImage: AttachmentStore.isImage(attachment),
                fileName: attachment.fileName,
                byteCount: attachment.byteCount,
                pixelSize: CGSize(width: attachment.pixelWidth, height: attachment.pixelHeight),
                hasData: attachment.data != nil
            )
            if entry.hasData, snapshot[attachment.id]?.hasData == false {
                failedIDs.remove(attachment.id)
            }
            next[attachment.id] = entry
        }
        let removedIDs = Set(snapshot.keys).subtracting(next.keys)
        for id in removedIDs {
            images.removeObject(forKey: id as NSUUID)
            decodeTasks.removeValue(forKey: id)?.cancel()
            inFlight.remove(id)
            failedIDs.remove(id)
        }
        snapshot = next
        snapshotSignature = signature
    }

    func reset() {
        for task in decodeTasks.values { task.cancel() }
        decodeTasks.removeAll()
        inFlight.removeAll()
        failedIDs.removeAll()
        images.removeAllObjects()
        snapshot.removeAll()
        snapshotNoteID = nil
        snapshotSignature = nil
    }

    func display(for id: UUID) -> AttachmentDisplay? {
        if snapshotSignature == nil { refreshSnapshot() }
        guard let entry = snapshot[id] else { return nil }
        let cached = images.object(forKey: id as NSUUID)
        if cached == nil, entry.hasData, !inFlight.contains(id), !failedIDs.contains(id) {
            scheduleDecode(for: id)
        }
        return AttachmentDisplay(
            id: id,
            isImage: entry.isImage,
            fileName: entry.fileName,
            byteCount: entry.byteCount,
            pixelSize: entry.pixelSize,
            image: cached,
            hasData: entry.hasData
        )
    }

    private func scheduleDecode(for id: UUID) {
        guard let attachment = attachment(with: id), let data = attachment.data else { return }
        let isImage = AttachmentStore.isImage(attachment)
        let fileName = attachment.fileName
        let typeIdentifier = attachment.typeIdentifier
        // Archives have no useful page preview; keep their native document symbol.
        if !isImage, UTType(typeIdentifier)?.conforms(to: .archive) == true {
            failedIDs.insert(id)
            return
        }
        inFlight.insert(id)
        let maxPixels = Self.thumbnailPixels
        decodeTasks[id] = Task { [weak self] in
            let decoded: CGImage?
            if isImage {
                decoded = await Task.detached(priority: .userInitiated) {
                    Self.decode(data, maxPixels: maxPixels)
                }.value
            } else {
                decoded = await DocumentThumbnails.generate(id: id, fileName: fileName, data: data)
            }
            guard let self, !Task.isCancelled else { return }
            self.inFlight.remove(id)
            self.decodeTasks.removeValue(forKey: id)
            guard self.snapshot[id] != nil else { return }
            guard let decoded else {
                self.failedIDs.insert(id)
                return
            }
            let cost = decoded.width * decoded.height * 4
            self.images.setObject(decoded, forKey: id as NSUUID, cost: cost)
            self.onImageDecoded?(id)
        }
    }

    func attachment(with id: UUID) -> RemarksCore.Attachment? {
        let current = note()
        guard !current.isDeleted, current.modelContext != nil else { return nil }
        return current.attachments?.first { $0.id == id }
    }

    /// Changes when attachments are added, removed, or their data arrives, so the editor knows to redraw.
    var signature: Int {
        let current = note()
        guard !current.isDeleted, current.modelContext != nil else { return 0 }
        var hasher = Hasher()
        for attachment in (current.attachments ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(attachment.id)
            hasher.combine(attachment.data != nil)
            hasher.combine(attachment.byteCount)
            hasher.combine(attachment.fileName)
        }
        return hasher.finalize()
    }

    private nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Uses the system's document preview providers, without accepting generic file-icon representations.
@MainActor
enum DocumentThumbnails {
    static func generate(id: UUID, fileName: String, data: Data) async -> CGImage? {
        guard !Task.isCancelled,
              let url = await AttachmentFiles.temporaryURLAsync(id: id, fileName: fileName, data: data),
              !Task.isCancelled else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 56, height: 64), scale: 3,
            representationTypes: .thumbnail
        )
        request.iconMode = false
        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            guard !Task.isCancelled else { return nil }
            return representation.cgImage
        } catch {
            // Unsupported files retain the document symbol; a thumbnail failure does not prevent opening.
            return nil
        }
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
    @MainActor
    static var chipHeight: CGFloat {
        max(64, ceil(EditorTheme.proseFont.pointSize * 2.6))
    }

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

    @MainActor
    static func displaySize(in area: CGSize, display: AttachmentDisplay?) -> CGSize {
        if let display, display.isImage {
            let sourceSize: CGSize
            if let image = display.image {
                sourceSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
            } else if display.pixelSize.width > 0, display.pixelSize.height > 0 {
                sourceSize = display.pixelSize
            } else {
                sourceSize = .zero
            }
            if sourceSize.width > 0, sourceSize.height > 0, area.width > 0, area.height > 0 {
                let scale = min(area.width / sourceSize.width, area.height / sourceSize.height)
                return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            }
        }
        let maxChipWidth = max(340, ceil(EditorTheme.proseFont.pointSize * 18))
        return CGSize(width: min(area.width, maxChipWidth), height: min(area.height, Self.chipHeight))
    }

    private func visibleRect(in area: CGRect, display: AttachmentDisplay? = nil) -> CGRect {
        let resolved = display ?? attachmentID.flatMap { controller?.attachmentDisplay(for: $0) }
        return CGRect(origin: area.origin, size: Self.displaySize(in: area.size, display: resolved))
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX - 2, y: -2, width: containerWidth + 4, height: layoutFragmentFrame.height + 4)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let id = attachmentID else { return }
        let area = contentRect(at: point)
        let display = controller?.attachmentDisplay(for: id)
        let rect = visibleRect(in: area, display: display)

        context.saveGState()
        if let display, display.isImage, let image = display.image {
            drawImage(image, in: rect, context: context)
        } else {
            drawChip(display, in: rect, context: context)
        }
        context.restoreGState()
    }

    // MARK: Image

    private func drawImage(_ image: CGImage, in rect: CGRect, cornerRadius: CGFloat = AttachmentFragment.cornerRadius, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        // Text layout draws with y growing downward, and CGContext draws images upright for y growing upward.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    }

    // MARK: Chip (files, and images that have not arrived yet)

    private func drawChip(_ display: AttachmentDisplay?, in chip: CGRect, context: CGContext) {
        context.setFillColor(EditorTheme.codeBackground.cgColor)
        context.addPath(CGPath(roundedRect: chip, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil))
        context.fillPath()

        context.setStrokeColor(EditorTheme.separatorColor.cgColor)
        context.setLineWidth(EditorTheme.increaseContrast ? 1.5 : 0.75)
        context.addPath(CGPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil))
        context.strokePath()

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
                symbol = display.isImage ? "photo" : "doc"
            }
        } else {
            title = String(localized: "Missing attachment")
            detail = ""
            symbol = "exclamationmark.triangle"
        }

        let proseSize = EditorTheme.proseFont.pointSize
        let titleSize = max(13, proseSize * 0.88)
        let detailSize = max(11, proseSize * 0.74)
        let titleFont = EditorFont.systemFont(ofSize: titleSize, weight: .medium)
        let detailFont = EditorFont.systemFont(ofSize: detailSize)
        let titleHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let detailHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading)

        let iconHeight = min(chip.width * 0.25, max(0, chip.height - 16))
        let icon = CGRect(x: chip.minX + 12, y: chip.midY - iconHeight / 2, width: iconHeight * 0.85, height: iconHeight)
        let textX = icon.maxX + 10
        let textWidth = max(0, chip.maxX - textX - 12)

        if let display, !display.isImage, let thumbnail = display.image {
            let scale = min(icon.width / CGFloat(thumbnail.width), icon.height / CGFloat(thumbnail.height))
            let size = CGSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
            let preview = CGRect(x: icon.midX - size.width / 2, y: icon.midY - size.height / 2,
                                 width: size.width, height: size.height)
            drawImage(thumbnail, in: preview, cornerRadius: 3, context: context)
        } else if let display, !display.isImage, display.hasData {
            AttachmentDrawing.drawFileIcon(fileName: display.fileName, in: icon, context: context)
        } else {
            AttachmentDrawing.draw(symbol: symbol, in: icon, color: EditorColor.secondaryText, context: context)
        }
        if detail.isEmpty {
            AttachmentDrawing.draw(text: title, font: titleFont, color: EditorColor.primaryText,
                                   in: CGRect(x: textX, y: chip.midY - titleHeight / 2, width: textWidth, height: titleHeight), context: context)
        } else {
            let gap: CGFloat = 1
            let totalHeight = titleHeight + gap + detailHeight
            let topY = chip.midY - totalHeight / 2
            AttachmentDrawing.draw(text: title, font: titleFont, color: EditorColor.primaryText,
                                   in: CGRect(x: textX, y: topY, width: textWidth, height: titleHeight), context: context)
            AttachmentDrawing.draw(text: detail, font: detailFont, color: EditorColor.secondaryText,
                                   in: CGRect(x: textX, y: topY + titleHeight + gap, width: textWidth, height: detailHeight), context: context)
        }
    }

}

// MARK: - Drawing helpers

/// Draws SF Symbols and text into the text layout's `CGContext`, on both platforms.
@MainActor
enum AttachmentDrawing {
    #if canImport(UIKit)
    private static let blankImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    #else
    private static let blankImage: NSImage = NSImage(size: CGSize(width: 1, height: 1))
    #endif

    /// A transparent native glyph reserves stable width for a custom-drawn preview element.
    static func placeholder(size: CGSize) -> NSTextAttachment {
        let attachment = NSTextAttachment(data: nil, ofType: nil)
        attachment.bounds = CGRect(origin: .zero, size: size)
        attachment.image = blankImage
        return attachment
    }

    /// Native monochrome symbols adapt to light and dark appearances, with no badge fill.
    static func drawFileIcon(fileName: String, in rect: CGRect, context: CGContext) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let isArchive = UTType(filenameExtension: fileExtension)?.conforms(to: .archive) == true
            || ["zip", "rar", "7z", "tar", "gz"].contains(fileExtension)
        draw(symbol: isArchive ? "doc.zipper" : "doc", in: rect,
             color: .primaryText, context: context)
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
    static func temporaryURL(for attachment: RemarksCore.Attachment) -> URL? {
        guard let data = attachment.data else { return nil }
        return writeTemporaryFile(id: attachment.id, fileName: attachment.fileName, data: data)
    }

    /// Writes the attachment payload off the main actor so Quick Look opening never stalls UI rendering on large files.
    static func temporaryURLAsync(id: UUID, fileName: String, data: Data) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            writeTemporaryFile(id: id, fileName: fileName, data: data)
        }.value
    }

    private nonisolated static func writeTemporaryFile(id: UUID, fileName: String, data: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let rawName = (fileName as NSString).lastPathComponent
        let safeName = (rawName.isEmpty || rawName == "." || rawName == "..") ? "Attachment" : rawName
        let url = directory.appendingPathComponent(safeName)
        do {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == data.count {
                return url
            }
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
