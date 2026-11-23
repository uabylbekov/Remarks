import SwiftUI
import SwiftData
import ImageIO
import NotesCore

/// Small pictures for the rows of the note list, kept by attachment id so scrolling back does not read and decode the
/// file again.
@MainActor
enum NoteThumbnails {
    private static let cache: NSCache<NSUUID, CGImage> = {
        let cache = NSCache<NSUUID, CGImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// The longest side of the kept copy, in pixels: enough for a small square on a 3x screen.
    private static let pixels = 160

    static func cached(_ id: UUID) -> CGImage? {
        cache.object(forKey: id as NSUUID)
    }

    /// The thumbnail for an image attached to `note`. Nil when the attachment is missing, is not a picture, or its data has
    /// not arrived from iCloud yet. The file is read here, on the main actor, because the model must not leave it; the
    /// decoding, which is the slow part, runs off it.
    static func load(_ id: UUID, from note: Note) async -> CGImage? {
        if let cached = cached(id) { return cached }
        guard !note.isDeleted, note.modelContext != nil,
              let attachment = note.attachments?.first(where: { $0.id == id }),
              AttachmentStore.isImage(attachment),
              let data = attachment.data
        else { return nil }

        let maxPixels = pixels
        let image = await Task.detached(priority: .utility) { decode(data, maxPixels: maxPixels) }.value
        if let image {
            cache.setObject(image, forKey: id as NSUUID, cost: image.width * image.height * 4)
        }
        return image
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

/// The picture a note starts with, as a small rounded square at the end of its row. A gray square holds the place while
/// the picture loads, so the row keeps one height.
struct NoteThumbnail: View {
    static let side: CGFloat = 48

    let note: Note
    let imageID: UUID
    @State private var image: CGImage?

    init(note: Note, imageID: UUID) {
        self.note = note
        self.imageID = imageID
        _image = State(initialValue: NoteThumbnails.cached(imageID))
    }

    private var hasImageData: Bool {
        guard !note.isDeleted, note.modelContext != nil else { return false }
        return note.attachments?.first(where: { $0.id == imageID })?.data != nil
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(.rect(cornerRadius: 6))
        // The row already reads the picture's name as its title, so this is only for the eyes.
        .accessibilityHidden(true)
        // Sync may deliver the note before its image payload. Retry when that payload arrives.
        .task(id: hasImageData) {
            guard image == nil, hasImageData else { return }
            let loaded = await NoteThumbnails.load(imageID, from: note)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
