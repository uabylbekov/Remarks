import Testing
import Foundation
import SwiftData
@testable import RemarksCore

/// Spec 01: a note written in a newer format must stay untouched by an app that cannot read it.
@Suite("Notes that need a newer version of the app")
struct NoteReaderVersionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A service and a note that a newer app has marked as needing a newer reader. `other` is a normal note.
    private func makeServiceWithNewerNote() async throws -> (service: NotesService, newer: NoteInfo, other: NoteInfo) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let service = NotesService(modelContainer: container)
        let newer = try await service.createNote(text: "# Newer\nbody", now: t0)
        let other = try await service.createNote(text: "# Other\nbody", now: t0)

        let context = ModelContext(container)
        let id = newer.id
        let note = try #require(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first)
        note.minimumReaderVersion = NoteFormat.supportedReaderVersion + 1
        try context.save()
        return (service, newer, other)
    }

    @Test("A note is readable when it needs this version of the format or an older one")
    func readableUpToTheSupportedVersion() {
        let note = Note()
        note.minimumReaderVersion = NoteFormat.supportedReaderVersion
        #expect(note.isReadable)
        note.minimumReaderVersion = 0
        #expect(note.isReadable)
    }

    @Test("A note is not readable when it needs a newer version of the format")
    func notReadableAboveTheSupportedVersion() {
        let note = Note()
        note.minimumReaderVersion = NoteFormat.supportedReaderVersion + 1
        #expect(!note.isReadable)
    }

    @Test("Lists, search and lookups leave out a note that needs a newer version")
    func readsLeaveItOut() async throws {
        let (service, newer, other) = try await makeServiceWithNewerNote()

        #expect(try await service.recentNotes().map(\.id) == [other.id])
        #expect(try await service.liveNotes().map(\.id) == [other.id])
        #expect(try await service.search("body").map(\.id) == [other.id])
        #expect(try await service.find(matching: []).map(\.id) == [other.id])
        #expect(try await service.notes(withIDs: [newer.id, other.id]).map(\.id) == [other.id])
        #expect(try await service.texts(withIDs: [newer.id, other.id]).keys.sorted { $0.uuidString < $1.uuidString } == [other.id])
    }

    @Test("The recent notes limit counts only notes the app can read")
    func recentLimitSkipsUnreadableNotes() async throws {
        let (service, _, other) = try await makeServiceWithNewerNote()
        #expect(try await service.recentNotes(limit: 1).map(\.id) == [other.id])
    }

    @Test("A folder's note count leaves out a note that needs a newer version")
    func folderCountSkipsUnreadableNotes() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let library = Library(context: context)
        let folder = try library.createFolder(named: "Work")
        library.createNote(body: "readable", in: folder)
        library.createNote(body: "newer", in: folder).minimumReaderVersion = NoteFormat.supportedReaderVersion + 1
        try context.save()

        let folders = try await NotesService(modelContainer: container).folders()
        #expect(folders.first?.noteCount == 1)
    }

    @Test("Reading or changing a note that needs a newer version is refused and changes nothing")
    func changesAreRefused() async throws {
        let (service, newer, _) = try await makeServiceWithNewerNote()

        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.info(for: newer.id) }
        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.text(of: newer.id) }
        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.append("x", to: newer.id) }
        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.update(newer.id, title: "x") }
        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.trash(newer.id) }
        await #expect(throws: NotesServiceError.noteNeedsNewerVersion) { try await service.restore(newer.id) }
    }

    @Test("In-app list keeps unreadable notes visible without search, and skips them when searching")
    func listFilterSkipsUnreadableNotesWhenSearching() {
        let newer = Note(body: "# Secret Future Feature\ncontains searchable keyword", now: t0)
        newer.minimumReaderVersion = NoteFormat.supportedReaderVersion + 1
        let readable = Note(body: "# Normal Note\ncontains searchable keyword", now: t0)

        let browsed = NoteFilter.apply(to: [newer, readable], scope: .all)
        #expect(browsed.map(\.id) == [newer.id, readable.id])

        let searched = NoteFilter.apply(to: [newer, readable], scope: .all, query: "searchable")
        #expect(searched.map(\.id) == [readable.id])
    }
}
