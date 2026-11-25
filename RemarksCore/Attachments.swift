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
    /// An attachment that no text refers to is removed after this long, so undo keeps working.
    public static let unreferencedGracePeriod: TimeInterval = 30 * 24 * 60 * 60
}

public enum AttachmentError: Error, Equatable, LocalizedError {
    case tooLarge
    case tooMany
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "That file is larger than 25 MB.", bundle: #bundle)
        case .tooMany: String(localized: "A note can have up to 20 attachments.", bundle: #bundle)
        case .unreadable: String(localized: "That file could not be read.", bundle: #bundle)
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
        pattern: #"^[ \t]*(!?)\[([^\]\r\n]*)\]\(attachment://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)[ \t]*$"#
    )
    private static let anywhere = try? NSRegularExpression(
        pattern: #"attachment://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
    )

    /// - Returns: nil unless the whole line is an attachment reference.
    public static func parse(_ line: String) -> AttachmentLine? {
        var trimmed = line
        while trimmed.last?.isNewline == true { trimmed.removeLast() }
        guard !trimmed.contains(where: \.isNewline) else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = expression?.firstMatch(in: trimmed, range: range),
              let id = UUID(uuidString: ns.substring(with: match.range(at: 3)))
        else { return nil }
        let marker = ns.substring(with: match.range(at: 1))
        return AttachmentLine(id: id, isImage: marker == "!", label: ns.substring(with: match.range(at: 2)))
    }

    /// Every attachment id that the text refers to, anywhere in it.
    public static func references(in body: String) -> Set<UUID> {
        guard let anywhere else { return [] }
        let text = body as NSString
        let matches = anywhere.matches(in: body, range: NSRange(location: 0, length: text.length))
        return Set(matches.compactMap { UUID(uuidString: text.substring(with: $0.range(at: 1))) })
    }

    /// The Markdown for an attachment. Brackets and line breaks are removed from the name so the reference stays on one line.
    public static func markdown(id: UUID, name: String, isImage: Bool) -> String {
        let singleLine = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        let clean = singleLine.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
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
            // EXIF orientations 5–8 rotate 90°/270° and transpose display width and height.
            let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
                ?? (properties[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
                ?? 1
            let isTransposed = (5...8).contains(orientation)
            return PreparedImage(
                data: data,
                typeIdentifier: typeIdentifier,
                pixelWidth: isTransposed ? height : width,
                pixelHeight: isTransposed ? width : height
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentLimits.maxImagePixels,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // JPEG has no transparency, so an image with an alpha channel stays PNG.
        // shortcut: opaque screenshots also carry an alpha channel and stay PNG, so they sync larger. Scan for real transparency if sync gets slow.
        let outputType: UTType = (properties[kCGImagePropertyHasAlpha] as? Bool) == true ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(
            data: output as Data,
            typeIdentifier: outputType.identifier,
            pixelWidth: scaled.width,
            pixelHeight: scaled.height
        )
    }
}

// MARK: - Store

/// Remembers when unlinked attachments were first noticed so the undo grace period survives relaunches
/// without modifying the synced database schema.
public protocol UnreferencedAttachmentTracker {
    func dates() -> [UUID: Date]
    func saveDates(_ dates: [UUID: Date])
}

/// Persists unreferenced attachment timestamps in `UserDefaults`.
public struct UserDefaultsUnreferencedTracker: UnreferencedAttachmentTracker {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "unreferencedAttachmentDates") {
        self.defaults = defaults
        self.key = key
    }

    public func dates() -> [UUID: Date] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: TimeInterval] else { return [:] }
        var result: [UUID: Date] = [:]
        result.reserveCapacity(raw.count)
        for (idString, interval) in raw {
            guard let id = UUID(uuidString: idString) else { continue }
            result[id] = Date(timeIntervalSince1970: interval)
        }
        return result
    }

    public func saveDates(_ dates: [UUID: Date]) {
        if dates.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        var raw: [String: TimeInterval] = [:]
        raw.reserveCapacity(dates.count)
        for (id, date) in dates {
            raw[id.uuidString] = date.timeIntervalSince1970
        }
        defaults.set(raw, forKey: key)
    }
}

/// Keeps unreferenced attachment timestamps in memory for isolated tests.
public final class InMemoryUnreferencedTracker: UnreferencedAttachmentTracker {
    private var storage: [UUID: Date]

    public init(_ initial: [UUID: Date] = [:]) {
        self.storage = initial
    }

    public func dates() -> [UUID: Date] { storage }
    public func saveDates(_ dates: [UUID: Date]) { storage = dates }
}

/// Adds attachments to notes and cleans up the ones no text refers to (Spec 07). Like `Library`, it works on any
/// `ModelContext`.
public struct AttachmentStore {
    public let context: ModelContext
    private let tracker: any UnreferencedAttachmentTracker

    public init(context: ModelContext, tracker: (any UnreferencedAttachmentTracker)? = nil) {
        self.context = context
        if let tracker {
            self.tracker = tracker
        } else if context.container.configurations.first?.isStoredInMemoryOnly == true {
            self.tracker = InMemoryUnreferencedTracker()
        } else {
            self.tracker = UserDefaultsUnreferencedTracker()
        }
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
        if isImage {
            guard let prepared = ImagePreparation.prepare(data, typeIdentifier: typeIdentifier) else {
                throw AttachmentError.unreadable
            }
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

    /// Attachments that no text refers to: those of live notes, and orphans with no note. Those of trashed notes are left
    /// out, because the trash keeps them. So are those of notes that need a newer version of the app: their text may refer
    /// to attachments in a way this version cannot see.
    public func unreferenced() throws -> [Attachment] {
        let supported = NoteFormat.supportedReaderVersion
        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
            $0.deletedAt == nil && $0.minimumReaderVersion <= supported
        }))
        var result: [Attachment] = []
        for note in notes {
            guard let attachments = note.attachments, !attachments.isEmpty else { continue }
            let referenced = AttachmentLine.references(in: note.body)
            result += attachments.filter { !referenced.contains($0.id) }
        }
        result += try context.fetch(FetchDescriptor<Attachment>(predicate: #Predicate { $0.note == nil }))
        return result
    }

    /// Runs the grace period for attachments that no text refers to, so removing a link can be undone:
    /// - the first time one is seen unreferenced, it is recorded with `now` and kept;
    /// - once it has been recorded for the whole grace period, it is deleted;
    /// - one that is referenced again, or whose note is in the trash, loses its mark, so the period starts over.
    /// - Returns: how many attachments were deleted, and how many marks were set or cleared.
    @discardableResult
    public func purgeUnreferenced(now: Date = .now) throws -> (purged: Int, marked: Int) {
        let cutoff = now.addingTimeInterval(-AttachmentLimits.unreferencedGracePeriod)
        let unlinked = try unreferenced()
        var tracked = tracker.dates()
        var purged = 0
        var marked = 0
        for attachment in unlinked {
            guard let since = tracked[attachment.id] else {
                tracked[attachment.id] = now
                marked += 1
                continue
            }
            if since <= cutoff {
                context.delete(attachment)
                tracked.removeValue(forKey: attachment.id)
                purged += 1
            }
        }

        let unlinkedIDs = Set(unlinked.map(\.id))
        for id in Array(tracked.keys) where !unlinkedIDs.contains(id) {
            tracked.removeValue(forKey: id)
            marked += 1
        }
        if marked > 0 || purged > 0 {
            tracker.saveDates(tracked)
        }
        return (purged, marked)
    }
}

// MARK: - Inserting into the text

extension MarkdownEditing {
    /// Puts `markdown` on a line of its own at the selection (replacing the selection), with the caret on the line after.
    public static func insertBlock(_ markdown: String, in text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        let start = min(max(selection.location, 0), source.length)
        let length = min(max(selection.length, 0), source.length - start)
        let startsLine: Bool
        if start == 0 {
            startsLine = true
        } else {
            let previous = source.character(at: start - 1)
            startsLine = previous == 10 || previous == 13 || previous == 0x2029
        }
        let replacement = (startsLine ? "" : "\n") + markdown + "\n"
        let caret = start + (replacement as NSString).length
        return TextEdit(
            range: NSRange(location: start, length: length),
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }
}

// MARK: - Export

/// One attachment file in an export, with its path relative to the note's Markdown file.
public struct ExportedFile: Sendable {
    public let path: String
    public let data: Data
}

/// A note ready to be written to disk: standard Markdown, plus the files it points at.
public struct ExportedNote: Sendable {
    /// A name safe to use for the folder and the `.md` file.
    public let name: String
    /// The body with every `attachment://id` replaced by a relative path such as `attachments/1A2B3C4D-Beach.png`.
    public let markdown: String
    public let files: [ExportedFile]
    /// How many attachments the text links to that could not be exported, because this device has no record of them or
    /// has not downloaded their file yet. Their `attachment://` links are left as they are.
    public let missingAttachmentCount: Int
}

public enum NoteExporter {
    private static let markdownPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()#%")
        return allowed
    }()

    /// The stored body is never changed. The returned copy uses relative links, so any Markdown app can open it.
    public static func export(_ note: Note) -> ExportedNote {
        var markdown = note.body
        let referenced = AttachmentLine.references(in: markdown)
        var files: [ExportedFile] = []
        var exportedIDs: Set<UUID> = []
        for attachment in note.attachments ?? [] where referenced.contains(attachment.id) {
            guard let data = attachment.data else { continue }
            exportedIDs.insert(attachment.id)
            let fileName = "\(attachment.id.uuidString.prefix(8))-\(safeName(attachment.fileName.isEmpty ? "Attachment" : attachment.fileName))"
            let path = "attachments/\(fileName)"
            let encoded = path.addingPercentEncoding(withAllowedCharacters: markdownPathAllowed) ?? path
            markdown = markdown.replacingOccurrences(of: "attachment://\(attachment.id.uuidString)", with: encoded, options: .caseInsensitive)
            files.append(ExportedFile(path: path, data: data))
        }
        let title = note.title.isEmpty ? "Note" : note.title
        return ExportedNote(
            name: safeName(String(title.prefix(60))),
            markdown: markdown,
            files: files,
            missingAttachmentCount: referenced.subtracting(exportedIDs).count
        )
    }

    private static func safeName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Note" }
        return cleaned
    }
}
