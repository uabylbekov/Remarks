import Testing
import Foundation
import SwiftData
@testable import NotesCore

/// Spec 06: the operations behind the intents.
struct NotesServiceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeService() throws -> (NotesService, ModelContainer) {
        let container = try NotesStore.makeContainer(inMemory: true)
        return (NotesService(modelContainer: container), container)
    }

    // MARK: Create

    @Test func createNoteStoresTheTextAndDerivesTheTitle() async throws {
        let (service, _) = try makeService()
        let info = try await service.createNote(text: "Buy milk\nand eggs", now: t0)
        #expect(info.title == "Buy milk")
        #expect(try await service.text(of: info.id) == "Buy milk\nand eggs")
    }

    @Test func aGivenTitleBecomesAHeading() async throws {
        let (service, _) = try makeService()
        let info = try await service.createNote(text: "milk, eggs", title: "  Groceries ", now: t0)
        #expect(info.title == "Groceries")
        #expect(try await service.text(of: info.id) == "# Groceries\n\nmilk, eggs")
    }

    @Test func aTitleWithNoTextStillMakesANote() async throws {
        let (service, _) = try makeService()
        let info = try await service.createNote(text: "", title: "Ideas", now: t0)
        #expect(try await service.text(of: info.id) == "# Ideas\n")
    }

    @Test func emptyTextMakesAnEmptyNote() async throws {
        let (service, _) = try makeService()
        let info = try await service.createNote(text: "", now: t0)
        #expect(try await service.text(of: info.id) == "")
    }

    @Test func createNoteCanGoIntoAFolder() async throws {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let folder = try Library(context: context).createFolder(named: "Work")
        try context.save()

        let info = try await service.createNote(text: "plan", folderID: folder.id, now: t0)
        #expect(info.folderName == "Work")
        #expect(try await service.folders().first?.noteCount == 1)
    }

    @Test func createNoteInAMissingFolderFailsAndCreatesNothing() async throws {
        let (service, _) = try makeService()
        await #expect(throws: NotesServiceError.folderNotFound) {
            try await service.createNote(text: "x", folderID: UUID())
        }
        #expect(try await service.recentNotes().isEmpty)
    }

    // MARK: Append

    @Test func appendAtTheEndStartsANewLine() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "first", now: t0)
        try await service.append("second", to: note.id, now: t0.addingTimeInterval(1))
        #expect(try await service.text(of: note.id) == "first\nsecond")
    }

    @Test func appendDoesNotAddABlankLineAfterATrailingNewline() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "first\n", now: t0)
        try await service.append("second", to: note.id, now: t0.addingTimeInterval(1))
        #expect(try await service.text(of: note.id) == "first\nsecond")
    }

    @Test func appendAtTheStartPutsTheTextFirst() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "later", now: t0)
        try await service.append("sooner", to: note.id, at: .start, now: t0.addingTimeInterval(1))
        #expect(try await service.text(of: note.id) == "sooner\nlater")
    }

    @Test func appendToAnEmptyNoteAddsNoLeadingNewline() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "", now: t0)
        try await service.append("hello", to: note.id)
        #expect(try await service.text(of: note.id) == "hello")
    }

    @Test func appendingNothingChangesNothing() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "same", now: t0)
        let after = try await service.append("", to: note.id, now: t0.addingTimeInterval(60))
        #expect(after.modifiedAt == note.modifiedAt)
    }

    @Test func appendUpdatesTheDerivedFieldsAndModifiedDate() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "", now: t0)
        let after = try await service.append("# Now a title", to: note.id, now: t0.addingTimeInterval(5))
        #expect(after.title == "Now a title")
        #expect(after.modifiedAt == t0.addingTimeInterval(5))
    }

    @Test func appendToAMissingOrTrashedNoteFails() async throws {
        let (service, _) = try makeService()
        await #expect(throws: NotesServiceError.noteNotFound) { try await service.append("x", to: UUID()) }

        let note = try await service.createNote(text: "gone", now: t0)
        try await service.trash(note.id, now: t0)
        await #expect(throws: NotesServiceError.noteInTrash) { try await service.append("x", to: note.id) }
    }

    // MARK: Trash

    @Test func trashHidesTheNoteAndRestoreBringsItBack() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "keep me", now: t0)

        try await service.trash(note.id, now: t0)
        #expect(try await service.recentNotes().isEmpty)
        #expect(try await service.search("keep").isEmpty)
        #expect(try await service.info(for: note.id).isTrashed)

        try await service.restore(note.id, now: t0)
        #expect(try await service.recentNotes().map(\.id) == [note.id])
    }

    @Test func trashAndRestoreAreSafeToRepeat() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "x", now: t0)
        try await service.trash(note.id, now: t0)
        try await service.trash(note.id, now: t0.addingTimeInterval(99))
        try await service.restore(note.id)
        try await service.restore(note.id)
        #expect(try await service.recentNotes().count == 1)
    }

    @Test func textOfATrashedNoteIsRefused() async throws {
        let (service, _) = try makeService()
        let note = try await service.createNote(text: "secret", now: t0)
        try await service.trash(note.id, now: t0)
        await #expect(throws: NotesServiceError.noteInTrash) { try await service.text(of: note.id) }
    }

    // MARK: Read

    @Test func notesWithIDsKeepsTheRequestedOrderAndSkipsMissingOnes() async throws {
        let (service, _) = try makeService()
        let a = try await service.createNote(text: "a", now: t0)
        let b = try await service.createNote(text: "b", now: t0.addingTimeInterval(1))
        let found = try await service.notes(withIDs: [b.id, UUID(), a.id])
        #expect(found.map(\.id) == [b.id, a.id])
        #expect(try await service.notes(withIDs: []).isEmpty)
    }

    @Test func notesWithIDsOmitsTrashedNotes() async throws {
        let (service, _) = try makeService()
        let a = try await service.createNote(text: "a", now: t0)
        try await service.trash(a.id, now: t0)
        #expect(try await service.notes(withIDs: [a.id]).isEmpty)
    }

    @Test func recentNotesAreNewestFirstAndBounded() async throws {
        let (service, _) = try makeService()
        for index in 0..<5 {
            try await service.createNote(text: "note \(index)", now: t0.addingTimeInterval(Double(index)))
        }
        let recent = try await service.recentNotes(limit: 3)
        #expect(recent.map(\.title) == ["note 4", "note 3", "note 2"])
        #expect(try await service.recentNotes(limit: 0).isEmpty)
    }

    @Test func searchIgnoresCaseAndAccentsAndNeedsEveryWord() async throws {
        let (service, _) = try makeService()
        try await service.createNote(text: "Café menu\nespresso and milk", now: t0)
        try await service.createNote(text: "Tea list\nmilk only", now: t0.addingTimeInterval(1))

        #expect(try await service.search("cafe").map(\.title) == ["Café menu"])
        #expect(try await service.search("MILK").count == 2)
        #expect(try await service.search("espresso milk").count == 1)
        #expect(try await service.search("espresso tea").isEmpty)
    }

    @Test func searchRanksTitleMatchesFirstAndHonorsTheLimit() async throws {
        let (service, _) = try makeService()
        try await service.createNote(text: "Shopping\nbuy apples", now: t0.addingTimeInterval(5))
        try await service.createNote(text: "Apples\nrecipes", now: t0)
        #expect(try await service.search("apples").map(\.title) == ["Apples", "Shopping"])
        #expect(try await service.search("apples", limit: 1).count == 1)
    }

    @Test func searchCanBeLimitedToAFolder() async throws {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let work = try Library(context: context).createFolder(named: "Work")
        try context.save()

        try await service.createNote(text: "plan the week", folderID: work.id, now: t0)
        try await service.createNote(text: "plan a trip", now: t0)
        #expect(try await service.search("plan", scope: .folder(work.id)).count == 1)
        #expect(try await service.search("plan").count == 2)
    }

    @Test func foldersCountOnlyLiveNotes() async throws {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let folder = try Library(context: context).createFolder(named: "Work")
        try context.save()

        let kept = try await service.createNote(text: "a", folderID: folder.id, now: t0)
        let removed = try await service.createNote(text: "b", folderID: folder.id, now: t0)
        try await service.trash(removed.id, now: t0)

        let info = try #require(try await service.folders().first)
        #expect(info.noteCount == 1)
        #expect(try await service.folders(withIDs: [folder.id, UUID()]).map(\.id) == [folder.id])
        _ = kept
    }

    // MARK: Sharing a store with the app

    @Test func theAppSeesWhatTheServiceWrites() async throws {
        let (service, container) = try makeService()
        let info = try await service.createNote(text: "from siri", now: t0)

        let appContext = ModelContext(container)
        let notes = try appContext.fetch(FetchDescriptor<Note>())
        #expect(notes.map(\.id) == [info.id])
    }
}

/// Spec 06: "Find Notes where…".
struct NoteFindTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeService() throws -> (NotesService, ModelContainer) {
        let container = try NotesStore.makeContainer(inMemory: true)
        return (NotesService(modelContainer: container), container)
    }

    /// Three notes: "Trip plan" (Work, tagged), "Trip photos" (pinned), "Groceries".
    private func seed() async throws -> NotesService {
        let (service, container) = try makeService()
        let context = ModelContext(container)
        let library = Library(context: context)
        let work = try library.createFolder(named: "Work")
        let plan = library.createNote(body: "Trip plan", in: work, now: t0)
        try library.addTag(named: "Travel", to: plan)
        let photos = library.createNote(body: "Trip photos", now: t0.addingTimeInterval(10))
        photos.setPinned(true, now: t0.addingTimeInterval(10))
        library.createNote(body: "Groceries", now: t0.addingTimeInterval(20))
        try context.save()
        return service
    }

    @Test func noConditionsReturnsEverythingNewestFirst() async throws {
        let service = try await seed()
        #expect(try await service.find(matching: []).map(\.title) == ["Groceries", "Trip photos", "Trip plan"])
    }

    @Test func titleConditionsIgnoreCaseAndAccents() async throws {
        let service = try await seed()
        #expect(try await service.find(matching: [.titleContains("TRIP")]).count == 2)
        #expect(try await service.find(matching: [.titleEquals("groceries")]).count == 1)
        #expect(try await service.find(matching: [.titleHasPrefix("trip p")]).count == 2)
        #expect(try await service.find(matching: [.titleHasPrefix("plan")]).isEmpty)
    }

    @Test func andRequiresEveryConditionAndOrRequiresAny() async throws {
        let service = try await seed()
        let conditions: [NoteCondition] = [.titleContains("trip"), .isPinned(true)]
        #expect(try await service.find(matching: conditions, matchAll: true).map(\.title) == ["Trip photos"])
        #expect(try await service.find(matching: conditions, matchAll: false).count == 2)
    }

    @Test func dateFolderAndTagConditions() async throws {
        let service = try await seed()
        #expect(try await service.find(matching: [.modifiedAfter(t0.addingTimeInterval(5))]).count == 2)
        #expect(try await service.find(matching: [.modifiedBefore(t0.addingTimeInterval(5))]).map(\.title) == ["Trip plan"])
        #expect(try await service.find(matching: [.folderNameEquals("work")]).map(\.title) == ["Trip plan"])
        #expect(try await service.find(matching: [.folderNameContains("or")]).count == 1)
        #expect(try await service.find(matching: [.hasTag("travel")]).map(\.title) == ["Trip plan"])
        #expect(try await service.find(matching: [.hasTag("nothing")]).isEmpty)
    }

    @Test func sortingAndLimitAreHonored() async throws {
        let service = try await seed()
        #expect(try await service.find(matching: [], sortedBy: [NoteSort(.title, ascending: true)]).map(\.title)
            == ["Groceries", "Trip photos", "Trip plan"])
        #expect(try await service.find(matching: [], sortedBy: [NoteSort(.modifiedAt, ascending: true)], limit: 2).map(\.title)
            == ["Trip plan", "Trip photos"])
        #expect(try await service.find(matching: [], sortedBy: [NoteSort(.isPinned, ascending: false)]).first?.title == "Trip photos")
        #expect(try await service.find(matching: [], limit: 0).isEmpty)
    }

    @Test func trashedNotesAreNeverFound() async throws {
        let service = try await seed()
        let gone = try #require(try await service.find(matching: [.titleEquals("Groceries")]).first)
        try await service.trash(gone.id, now: t0)
        #expect(try await service.find(matching: [.titleEquals("Groceries")]).isEmpty)
    }
}

/// Spec 06, step 7: what Spotlight is given.
struct SpotlightTests {
    @Test func liveNotesLeavesOutTrashedOnes() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let service = NotesService(modelContainer: container)
        let keep = try await service.createNote(text: "Keep me")
        let drop = try await service.createNote(text: "Drop me")
        try await service.trash(drop.id)

        let live = try await service.liveNotes()
        #expect(live.map(\.id) == [keep.id])
    }

    @Test func indexingIsOnUnlessTheSettingSaysOtherwise() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SpotlightSettings.key)
        defer { defaults.set(saved, forKey: SpotlightSettings.key) }

        defaults.removeObject(forKey: SpotlightSettings.key)
        #expect(SpotlightSettings.isEnabled)
        defaults.set(false, forKey: SpotlightSettings.key)
        #expect(!SpotlightSettings.isEnabled)
    }

    @Test func theEntityKeepsTheTitlePreviewAndTags() {
        let note = Note(body: "Plan\nShip the editor")
        let entity = NoteEntity(NoteInfo(note))
        #expect(entity.title == "Plan")
        #expect(entity.snippet == "Ship the editor")
    }
}
