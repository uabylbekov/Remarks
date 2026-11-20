import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

// MARK: - Limits and errors (Spec 07)

public enum AttachmentLimits {
    /// One file, after images have been downscaled.
    public static let maxFileBytes = 25 * 1024 * 1024
    public static let maxPerNote = 20
    /// The longest side of a stored image, in pixels.
    public static let maxImagePixels = 2048
    /// An attachment that no text refers to is removed after this long, so undo and Version History keep working.
    public static let unreferencedGracePeriod: TimeInterval = 30 * 24 * 60 * 60
}

public enum AttachmentError: Error, Equatable, LocalizedError {
    case tooLarge
    case tooMany
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "That file is larger than 25 MB.")
        case .tooMany: String(localized: "A note can have up to 20 attachments.")
        case .unreadable: String(localized: "That file could not be read.")
        }
    }
}

// MARK: - Markdown form

/// A line that holds nothing but an attachment: `![alt](attachment://UUID)` or `[name](attachment://UUID)`.
public struct AttachmentLine: Equatable, Sendable {
    public let id: UUID
    public let isImage: Bool
    public let label: String

    private static let expression = try? NSRegularExpression(
        pattern: #"^\s*(!?)\[([^\]]*)\]\(attachment://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)\s*$"#
    )
    private static let anywhere = try? NSRegularExpression(
        pattern: #"attachment://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
    )

    /// - Returns: nil unless the whole line is an attachment reference.
    public static func parse(_ line: String) -> AttachmentLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression?.firstMatch(in: line, range: range),
              let id = UUID(uuidString: (line as NSString).substring(with: match.range(at: 3)))
        else { return nil }
        let marker = (line as NSString).substring(with: match.range(at: 1))
        return AttachmentLine(id: id, isImage: marker == "!", label: (line as NSString).substring(with: match.range(at: 2)))
    }

    /// Every attachment id that the text refers to, anywhere in it.
    public static func references(in body: String) -> Set<UUID> {
        guard let anywhere else { return [] }
        let text = body as NSString
        let matches = anywhere.matches(in: body, range: NSRange(location: 0, length: text.length))
        return Set(matches.compactMap { UUID(uuidString: text.substring(with: $0.range(at: 1))) })
    }

    /// The Markdown for an attachment. Brackets are removed from the name, because they would end the link text.
    public static func markdown(id: UUID, name: String, isImage: Bool) -> String {
        let clean = name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "\(isImage ? "!" : "")[\(clean)](attachment://\(id.uuidString))"
    }
}

// MARK: - Images

/// What is stored for an image after it has been prepared.
public struct PreparedImage: Sendable {
    public let data: Data
    public let typeIdentifier: String
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum ImagePreparation {
    /// Reads the image size, and downscales and re-encodes it when it is larger than the limit.
    /// Animated GIFs are kept as they are, because re-encoding would drop the animation.
    /// - Returns: nil when the data is not an image.
    public static func prepare(_ data: Data, typeIdentifier: String) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let isGIF = UTType(typeIdentifier)?.conforms(to: .gif) == true
        let longest = max(width, height)
        if longest <= AttachmentLimits.maxImagePixels || isGIF {
            return PreparedImage(data: data, typeIdentifier: typeIdentifier, pixelWidth: width, pixelHeight: height)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentLimits.maxImagePixels,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(
            data: output as Data,
            typeIdentifier: UTType.jpeg.identifier,
            pixelWidth: scaled.width,
            pixelHeight: scaled.height
        )
    }
}

// MARK: - Store

/// Adds attachments to notes and cleans up the ones no text refers to (Spec 07). Like `Library`, it works on any
/// `ModelContext`.
public struct AttachmentStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Creates the attachment record for `data` and links it to `note`. The caller inserts `markdown(for:)` into the note.
    /// - Throws: `AttachmentError` when the file is too big, the note has too many attachments, or the data is empty.
    @discardableResult
    public func add(
        data: Data,
        fileName: String,
        typeIdentifier: String,
        to note: Note,
        now: Date = .now
    ) throws -> Attachment {
        guard !data.isEmpty else { throw AttachmentError.unreadable }
        guard (note.attachments?.count ?? 0) < AttachmentLimits.maxPerNote else { throw AttachmentError.tooMany }

        let isImage = UTType(typeIdentifier)?.conforms(to: .image) == true
        var stored = data
        var type = typeIdentifier
        var width = 0
        var height = 0
        if isImage, let prepared = ImagePreparation.prepare(data, typeIdentifier: typeIdentifier) {
            stored = prepared.data
            type = prepared.typeIdentifier
            width = prepared.pixelWidth
            height = prepared.pixelHeight
        }
        guard stored.count <= AttachmentLimits.maxFileBytes else { throw AttachmentError.tooLarge }

        let attachment = Attachment(fileName: fileName, typeIdentifier: type, data: stored, now: now)
        attachment.pixelWidth = width
        attachment.pixelHeight = height
        attachment.note = note
        context.insert(attachment)
        return attachment
    }

    public static func markdown(for attachment: Attachment) -> String {
        let base = (attachment.fileName as NSString).deletingPathExtension
        let isImage = Self.isImage(attachment)
        return AttachmentLine.markdown(
            id: attachment.id,
            name: isImage ? (base.isEmpty ? attachment.fileName : base) : attachment.fileName,
            isImage: isImage
        )
    }

    public static func isImage(_ attachment: Attachment) -> Bool {
        UTType(attachment.typeIdentifier)?.conforms(to: .image) == true
    }

    // MARK: Cleanup

    /// Attachments of live notes that no text refers to and that are older than the grace period.
    public func unreferenced(now: Date = .now) throws -> [Attachment] {
        let cutoff = now.addingTimeInterval(-AttachmentLimits.unreferencedGracePeriod)
        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))
        var result: [Attachment] = []
        for note in notes {
            guard let attachments = note.attachments, !attachments.isEmpty else { continue }
            let referenced = AttachmentLine.references(in: note.body)
            result += attachments.filter { !referenced.contains($0.id) && $0.createdAt <= cutoff }
        }
        return result
    }

    @discardableResult
    public func purgeUnreferenced(now: Date = .now) throws -> Int {
        let stale = try unreferenced(now: now)
        stale.forEach(context.delete)
        return stale.count
    }
}

// MARK: - Inserting into the text

extension MarkdownEditing {
    /// Puts `markdown` on a line of its own at the selection (replacing the selection), with the caret on the line after.
    public static func insertBlock(_ markdown: String, in text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        let start = min(selection.location, source.length)
        let end = min(NSMaxRange(selection), source.length)
        let startsLine = start == 0 || source.character(at: start - 1) == 10
        let replacement = (startsLine ? "" : "\n") + markdown + "\n"
        let caret = start + (replacement as NSString).length
        return TextEdit(
            range: NSRange(location: start, length: end - start),
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }
}
