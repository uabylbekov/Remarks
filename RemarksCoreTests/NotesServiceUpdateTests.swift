import Testing
import Foundation
import SwiftData
@testable import RemarksCore

/// The operations behind the Siri "update note" and "create note" schemas.
struct NotesServiceUpdateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeService() throws -> (NotesService, ModelContainer) {
        let container = try NotesStore.makeContainer(inMemory: true)
        return (NotesService(modelContainer: container), container)
    }

    // MARK: Retitling

    @Test func retitleReplacesAPlainFirstLine() {
        #expect(NotesService.body("Old\nrest", retitledTo: "New") == "New\nrest")
    }

    @Test func retitleKeepsTheHeadingMarker() {
        #expect(NotesService.body("## Old\n\nrest", retitledTo: "New") == "## New\n\nrest")
    }

    @Test func retitleOfAnEmptyNoteMakesAHeading() {
        #expect(NotesService.body("  \n", retitledTo: "New") == "# New\n")
    }

    @Test func aHashWithoutASpaceIsNotAHeading() {
        #expect(NotesService.body("#tag stuff\nrest", retitledTo: "New") == "New\nrest")
    }

    @Test func aTitleWithLineBreaksBecomesOneLine() {
        #expect(NotesService.singleLine("  Plan\nfor  the week\r\n\n") == "Plan for  the week")
        #expect(NotesService.singleLine(" \n ") == "")
    }

    @Test func aMultiLineTitleStaysOnTheFirstLineOfTheNote() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "body", title: "Plan\nfor the week", now: t0)
        let renamed = try await service.update(note.id, title: "New\nname", now: t0.addingTimeInterval(1))

        #expect(note.title == "Plan for the week")
        #expect(try await service.text(of: note.id) == "# New name\n\nbody")
        #expect(renamed.title == "New name")
    }

    // MARK: Failed saves

    private struct DiskFull: Error {}

    @Test func aFailedSaveDoesNotLeakIntoTheNextSuccessfulSave() async throws {
        let (service, _) = try makeService()
        let first = try await service.createNote(text: "original", now: t0)
        let second = try await service.createNote(text: "other", now: t0)

        await service.setSaveForTesting { _ in throw DiskFull() }
        await #expect(throws: DiskFull.self) {
            try await service.append(" lost", to: first.id, now: t0.addingTimeInterval(1))
        }
        await service.setSaveForTesting(nil)

        // A later, unrelated call saves the shared context. The failed edit must not ride along.
        try await service.update(second.id, isPinned: true, now: t0.addingTimeInterval(2))
        #expect(try await service.text(of: first.id) == "original")
    }

    // MARK: Update

    @Test func updateRenamesPinsAndMoves() async throws {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let folder = try Library(context: context).createFolder(named: "Work")
        try context.save()

        let note = try await service.createNote(text: "Draft\nbody", now: t0)
        let info = try await service.update(note.id, title: "Plan", isPinned: true, folderID: folder.id, now: t0.addingTimeInterval(1))

        #expect(info.title == "Plan")
        #expect(info.isPinned)
        #expect(info.folderName == "Work")
        #expect(try await service.text(of: note.id) == "Plan\nbody")
    }

    @Test func updateWithNothingChangesNothing() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "same", now: t0)
        let info = try await service.update(note.id, now: t0.addingTimeInterval(1))
        #expect(info.modifiedAt == note.modifiedAt)
    }

    @Test func updateRefusesANoteInTheTrash() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "gone", now: t0)
        try await service.trash(note.id, now: t0)
        await #expect(throws: NotesServiceError.noteInTrash) {
            try await service.update(note.id, isPinned: true)
        }
    }

    @Test func updateToAMissingFolderFailsAndChangesNothing() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "stay", now: t0)
        await #expect(throws: NotesServiceError.folderNotFound) {
            try await service.update(note.id, title: "Renamed", isPinned: true, folderID: UUID())
        }
        let after = try await service.info(for: note.id)
        #expect(after.title == "stay")
        #expect(!after.isPinned)
    }

    // MARK: Create with extras

    @Test func createNoteCanStartPinned() async throws {
        let (service, _) = try makeService()
        let info = try await service.createNote(text: "important", isPinned: true, now: t0)
        #expect(info.isPinned)
    }

    @Test func createNoteStoresAnAttachmentAndLinksIt() async throws {
        let (service, _) = try makeService()
        let file = IncomingFile(data: Data("hello".utf8), fileName: "hello.txt", typeIdentifier: "public.plain-text")
        let info = try await service.createNote(text: "see file", attachments: [file], now: t0)
        let text = try await service.text(of: info.id)
        #expect(text.hasPrefix("see file\n\n[hello.txt](attachment://"))
    }

    @Test func anUnreadableAttachmentCreatesNothing() async throws {
        let (service, _) = try makeService()
        let empty = IncomingFile(data: Data(), fileName: "empty.txt", typeIdentifier: "public.plain-text")
        await #expect(throws: NotesServiceError.attachmentFailed(.unreadable)) {
            try await service.createNote(text: "x", attachments: [empty])
        }
        #expect(try await service.recentNotes().isEmpty)
    }

    // MARK: Entities

    @Test func theEntityCarriesTheSchemaProperties() {
        let note = Note(body: "Plan\nShip it", now: t0)
        let entity = NoteEntity(NoteInfo(note), content: "Plan\nShip it")
        #expect(String(entity.name.characters) == "Plan")
        #expect(entity.content.map { String($0.characters) } == "Plan\nShip it")
        #expect(entity.creationDate == t0)
        #expect(entity.attachments.isEmpty)
    }

    @Test func theIndexedEntityHasNoFullText() {
        // Spotlight gets entities built without text (Spec 06, D1).
        let entity = NoteEntity(NoteInfo(Note(body: "Plan\nSecret details", now: t0)))
        #expect(entity.content == nil)
    }

    @Test func foldersKnowTheirParent() async throws {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let library = Library(context: context)
        let parent = try library.createFolder(named: "Work")
        try library.createFolder(named: "Plans", in: parent)
        try context.save()

        let plans = try await service.folders().first { $0.name == "Plans" }
        #expect(plans?.parentName == "Work")
        #expect(FolderEntity(try #require(plans)).parentFolder?.id == parent.id)
    }
}
