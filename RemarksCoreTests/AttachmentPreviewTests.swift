import Testing
import Foundation
import CoreGraphics
import SwiftData
import RemarksCore
@testable import Remarks

@MainActor
struct AttachmentPreviewTests {
    @Test func aPDFGetsASmallDocumentPreview() async throws {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var page = CGRect(x: 0, y: 0, width: 300, height: 400)
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(page)
        pdf.setFillColor(CGColor(gray: 0.2, alpha: 1))
        pdf.fill(CGRect(x: 30, y: 300, width: 240, height: 30))
        pdf.endPDFPage()
        pdf.closePDF()

        let id = UUID()
        defer {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true))
        }
        let preview = try #require(await DocumentThumbnails.generate(id: id, fileName: "Preview.pdf", data: output as Data))
        #expect(preview.width > 0 && preview.height > 0)
        #expect(preview.width <= 168 && preview.height <= 192)
    }

    @Test func archivesKeepTheirIconWithoutRequestingAPreview() throws {
        let store = try NotesStore.makeContainer(inMemory: true)
        let note = Library(context: store.mainContext).createNote()
        let archive = try AttachmentStore(context: store.mainContext).add(
            data: Data([1, 2, 3]), fileName: "Archive.zip", typeIdentifier: "public.zip-archive", to: note
        )
        let catalog = AttachmentCatalog(note: { note })
        catalog.refreshSnapshot()
        let display = try #require(catalog.display(for: archive.id))
        #expect(display.hasData)
        #expect(display.image == nil)
        #expect(!display.isImage)
        catalog.reset()
    }
}
