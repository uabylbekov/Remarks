import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import NotesCore

@MainActor
struct AttachmentTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try NotesStore.makeContainer(inMemory: true))
    }

    /// A solid-colour PNG of the given size, with or without an alpha channel.
    private func pngData(width: Int, height: Int, opaque: Bool = false) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: Markdown

    @Test func parsesAnImageLineAndAFileLine() throws {
        let id = UUID()
        let image = try #require(AttachmentLine.parse("![Beach](attachment://\(id.uuidString))"))
        #expect(image == AttachmentLine(id: id, isImage: true, label: "Beach"))

        let file = try #require(AttachmentLine.parse("  [Plan.pdf](attachment://\(id.uuidString))  "))
        #expect(file == AttachmentLine(id: id, isImage: false, label: "Plan.pdf"))
    }

    @Test func aLineWithOtherTextIsNotAnAttachmentLine() {
        let id = UUID().uuidString
        #expect(AttachmentLine.parse("see ![x](attachment://\(id))") == nil)
        #expect(AttachmentLine.parse("![x](https://example.com/a.png)") == nil)
        #expect(AttachmentLine.parse("![x](attachment://not-a-uuid)") == nil)
    }

    @Test func findsEveryReferenceInABody() {
        let a = UUID(), b = UUID()
        let body = "Intro\n![one](attachment://\(a.uuidString))\ntext [two](attachment://\(b.uuidString)) more"
        #expect(AttachmentLine.references(in: body) == [a, b])
        #expect(AttachmentLine.references(in: "nothing here").isEmpty)
    }

    @Test func markdownRoundTripsThroughTheParser() throws {
        let id = UUID()
        let text = AttachmentLine.markdown(id: id, name: "Q1 [draft].pdf", isImage: false)
        let parsed = try #require(AttachmentLine.parse(text))
        #expect(parsed.id == id)
        #expect(!parsed.isImage)
        #expect(!text.contains("[draft]"))
    }

    @Test func aTitleAndSnippetShowTheAttachmentNameNotTheLink() {
        let id = UUID().uuidString
        let derived = NoteText.derive(from: "Trip\n![Beach](attachment://\(id))\nSunny")
        #expect(derived.title == "Trip")
        #expect(derived.snippet == "Beach Sunny")
    }

    @Test func aTitleAndSnippetShowTableCellsNotPipesOrTheSeparatorRow() {
        let derived = NoteText.derive(from: "| Name | Age |\n| --- | :-: |\n| Ann | 31 |\n|  |  |")
        #expect(derived.title == "Name Age")
        #expect(derived.snippet == "Ann 31")
    }

    @Test func aTitleAndSnippetShowTextNotInlineMarks() {
        let derived = NoteText.derive(from: "**Plan** for `code`\nSee [docs](https://x.dev), _soon_ and ~~not~~ https://y.dev")
        #expect(derived.title == "Plan for code")
        #expect(derived.snippet == "See docs, soon and not https://y.dev")
    }

    @Test func insertingAtTheStartOfALineAddsOnlyATrailingNewline() {
        let edit = MarkdownEditing.insertBlock("![x](attachment://A)", in: "Hello\n", selection: NSRange(location: 6, length: 0))
        #expect(edit.replacement == "![x](attachment://A)\n")
        #expect(edit.range == NSRange(location: 6, length: 0))
        #expect(edit.selection == NSRange(location: 6 + edit.replacement.utf16.count, length: 0))
    }

    @Test func insertingMidLineStartsANewLineAndReplacesTheSelection() {
        let edit = MarkdownEditing.insertBlock("[f](attachment://A)", in: "Hello world", selection: NSRange(location: 5, length: 6))
        #expect(edit.replacement == "\n[f](attachment://A)\n")
        #expect(edit.range == NSRange(location: 5, length: 6))
    }

    // MARK: Adding

    @Test func addingALinkedFileStoresItAndLinksTheNote() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let data = Data(repeating: 7, count: 1000)

        let attachment = try AttachmentStore(context: context).add(
            data: data, fileName: "Plan.pdf", typeIdentifier: UTType.pdf.identifier, to: note
        )

        #expect(attachment.byteCount == 1000)
        #expect(attachment.note?.id == note.id)
        #expect(note.attachments?.count == 1)
        #expect(!AttachmentStore.isImage(attachment))
        #expect(AttachmentStore.markdown(for: attachment) == "[Plan.pdf](attachment://\(attachment.id.uuidString))")
    }

    @Test func anImageUsesItsNameWithoutExtensionAsAltText() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let attachment = try AttachmentStore(context: context).add(
            data: try pngData(width: 40, height: 20), fileName: "Beach.png", typeIdentifier: UTType.png.identifier, to: note
        )
        #expect(attachment.pixelWidth == 40)
        #expect(attachment.pixelHeight == 20)
        #expect(AttachmentStore.markdown(for: attachment) == "![Beach](attachment://\(attachment.id.uuidString))")
    }

    @Test func aLargeImageIsDownscaled() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let attachment = try AttachmentStore(context: context).add(
            data: try pngData(width: 4000, height: 1000, opaque: true), fileName: "Wide.png", typeIdentifier: UTType.png.identifier, to: note
        )
        #expect(attachment.pixelWidth == AttachmentLimits.maxImagePixels)
        #expect(attachment.pixelHeight == AttachmentLimits.maxImagePixels / 4)
        #expect(attachment.typeIdentifier == UTType.jpeg.identifier)
    }

    @Test func aLargeImageWithTransparencyStaysPNG() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let attachment = try AttachmentStore(context: context).add(
            data: try pngData(width: 4000, height: 1000), fileName: "Logo.png", typeIdentifier: UTType.png.identifier, to: note
        )
        #expect(attachment.pixelWidth == AttachmentLimits.maxImagePixels)
        #expect(attachment.typeIdentifier == UTType.png.identifier)
    }

    @Test func aFileOverTheLimitIsRefusedAndNothingIsAdded() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let tooBig = Data(count: AttachmentLimits.maxFileBytes + 1)

        #expect(throws: AttachmentError.tooLarge) {
            try AttachmentStore(context: context).add(data: tooBig, fileName: "big.bin", typeIdentifier: UTType.data.identifier, to: note)
        }
        #expect((note.attachments ?? []).isEmpty)
    }

    @Test func emptyDataIsUnreadable() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        #expect(throws: AttachmentError.unreadable) {
            try AttachmentStore(context: context).add(data: Data(), fileName: "x", typeIdentifier: UTType.data.identifier, to: note)
        }
    }

    @Test func aNoteHoldsAtMostTwentyAttachments() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let store = AttachmentStore(context: context)
        for index in 0..<AttachmentLimits.maxPerNote {
            try store.add(data: Data([1]), fileName: "f\(index)", typeIdentifier: UTType.data.identifier, to: note)
        }
        #expect(throws: AttachmentError.tooMany) {
            try store.add(data: Data([1]), fileName: "extra", typeIdentifier: UTType.data.identifier, to: note)
        }
    }

    // MARK: Export

    @Test func exportRewritesLinksToRelativePathsAndKeepsTheStoredBody() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote()
        let attachment = try AttachmentStore(context: context).add(
            data: Data([1, 2, 3]), fileName: "Q1 plan.pdf", typeIdentifier: UTType.pdf.identifier, to: note
        )
        let markdown = AttachmentStore.markdown(for: attachment)
        note.setBody("# Plan\n\(markdown)\n")

        let exported = NoteExporter.export(note)
        let prefix = attachment.id.uuidString.prefix(8)
        #expect(exported.markdown.contains("(attachments/\(prefix)-Q1%20plan.pdf)"))
        #expect(!exported.markdown.contains("attachment://"))
        #expect(exported.files.map(\.path) == ["attachments/\(prefix)-Q1 plan.pdf"])
        #expect(exported.files.first?.data == Data([1, 2, 3]))
        #expect(exported.name == "Plan")
        #expect(note.body.contains("attachment://"))
    }

    @Test func exportCleansUnsafeCharactersInNames() throws {
        let context = try makeContext()
        let note = Library(context: context).createNote(body: "a/b: c?")
        #expect(NoteExporter.export(note).name == "a-b- c-")
    }

    // MARK: Cleanup

    @Test func onlyOldUnreferencedAttachmentsArePurged() throws {
        let context = try makeContext()
        let library = Library(context: context)
        let store = AttachmentStore(context: context)
        let now = Date.now
        let old = now.addingTimeInterval(-AttachmentLimits.unreferencedGracePeriod - 60)

        let note = library.createNote()
        let kept = try store.add(data: Data([1]), fileName: "kept", typeIdentifier: UTType.data.identifier, to: note, now: old)
        let orphanOld = try store.add(data: Data([2]), fileName: "old", typeIdentifier: UTType.data.identifier, to: note, now: old)
        let orphanNew = try store.add(data: Data([3]), fileName: "new", typeIdentifier: UTType.data.identifier, to: note, now: now)
        note.setBody("Text\n\(AttachmentStore.markdown(for: kept))")

        #expect(try store.purgeUnreferenced(now: now) == 1)
        try context.save()

        let remaining = Set((note.attachments ?? []).map(\.id))
        #expect(remaining == [kept.id, orphanNew.id])
        #expect(!remaining.contains(orphanOld.id))
    }

    @Test func maintenanceReportsPurgedAttachments() throws {
        let context = try makeContext()
        let library = Library(context: context)
        let note = library.createNote()
        let old = Date.now.addingTimeInterval(-AttachmentLimits.unreferencedGracePeriod - 60)
        try AttachmentStore(context: context).add(data: Data([1]), fileName: "x", typeIdentifier: UTType.data.identifier, to: note, now: old)

        let report = try library.runMaintenance()
        #expect(report.purgedAttachments == 1)
        #expect(report.changedAnything)
    }

    @Test func deletingANoteForeverDeletesItsAttachments() throws {
        let context = try makeContext()
        let library = Library(context: context)
        let note = library.createNote()
        try AttachmentStore(context: context).add(data: Data([1]), fileName: "x", typeIdentifier: UTType.data.identifier, to: note)
        try context.save()

        library.deleteForever(note)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<NotesCore.Attachment>()).isEmpty)
    }
}
