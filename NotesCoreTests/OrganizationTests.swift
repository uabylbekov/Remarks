import Testing
import Foundation
import SwiftData
@testable import NotesCore

/// Spec 04: scopes, search, ranking, snippets, and folder and tag management.
struct OrganizationTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

    private func titles(_ notes: [Note]) -> [String] { notes.map(\.title) }

    // MARK: Scopes

    /// The list loads its notes with `NoteScope.predicate`. With no search text it must pick the same notes, in the
    /// same order (pinned first, then newest), as `NoteFilter.apply`.
    @Test func scopePredicatesMatchTheFilterAndItsOrder() throws {
        let (library, context) = try makeLibrary()
        let work = try library.createFolder(named: "Work", now: t0)
        let trashedFolder = try library.createFolder(named: "Old", now: t0)
        var notes: [Note] = []
        for index in 0..<12 {
            let note = library.createNote(body: "Note \(index)", in: index % 3 == 0 ? work : (index % 5 == 0 ? trashedFolder : nil), now: t0.addingTimeInterval(Double(index)))
            if index % 4 == 0 { note.setPinned(true, now: t0.addingTimeInterval(Double(index))) }
            if index % 2 == 0 { try library.addTag(named: "swift", to: note, now: t0) }
            if index % 6 == 5 { library.trash(note, now: t0) }
            notes.append(note)
        }
        try context.save()
        let swiftTag = try #require(notes[0].tags?.first)

        for scope in [NoteScope.all, .unfiled, .folder(work.id), .folder(trashedFolder.id), .tag(swiftTag.id), .trash] {
            let expected = NoteFilter.apply(to: notes, scope: scope).map(\.id)
            func fetch(pinned: Bool) throws -> [UUID] {
                try context.fetch(FetchDescriptor<Note>(
                    predicate: scope.predicate(isPinned: pinned),
                    sortBy: scope.sortDescriptors
                )).map(\.id)
            }
            #expect(try fetch(pinned: true) + fetch(pinned: false) == expected, "\(scope)")
        }
    }

    @Test func trashSortsNewestDeletedFirstWithoutSplittingPinnedNotes() throws {
        let (library, context) = try makeLibrary()
        let olderEdited = library.createNote(body: "Older edited", now: t0)
        let newerEditedPinned = library.createNote(body: "Newer edited pinned", now: t0.addingTimeInterval(100))
        newerEditedPinned.setPinned(true, now: t0.addingTimeInterval(100))
        // Trash the pinned note first, then the older note later.
        library.trash(newerEditedPinned, now: t0.addingTimeInterval(200))
        library.trash(olderEdited, now: t0.addingTimeInterval(300))
        try context.save()

        let filtered = NoteFilter.apply(to: [olderEdited, newerEditedPinned], scope: .trash)
        #expect(titles(filtered) == ["Older edited", "Newer edited pinned"])

        let pinnedInTrash = try context.fetch(FetchDescriptor<Note>(
            predicate: NoteScope.trash.predicate(isPinned: true),
            sortBy: NoteScope.trash.sortDescriptors
        ))
        let unpinnedInTrash = try context.fetch(FetchDescriptor<Note>(
            predicate: NoteScope.trash.predicate(isPinned: false),
            sortBy: NoteScope.trash.sortDescriptors
        ))
        #expect(pinnedInTrash.isEmpty)
        #expect(titles(unpinnedInTrash) == ["Older edited", "Newer edited pinned"])
    }

    @Test func aWidenedPredicateSelectsEveryLiveNote() throws {
        let (library, context) = try makeLibrary()
        let work = try library.createFolder(named: "Work", now: t0)
        let inWork = library.createNote(body: "In work", in: work, now: t0)
        let loose = library.createNote(body: "Loose", now: t0)
        let trashed = library.createNote(body: "Trashed", now: t0)
        library.trash(trashed, now: t0)
        try context.save()
        let found = try context.fetch(FetchDescriptor<Note>(predicate: NoteScope.folder(work.id).predicate(isPinned: false, widenedToAllNotes: true)))
        #expect(Set(found.map(\.id)) == [inWork.id, loose.id])
    }

    @Test func scopesSelectTheRightNotes() throws {
        let (library, _) = try makeLibrary()
        let work = try library.createFolder(named: "Work", now: t0)
        let inWork = library.createNote(body: "In work", in: work, now: t0)
        let loose = library.createNote(body: "Loose", now: t0.addingTimeInterval(1))
        let tagged = library.createNote(body: "Tagged", now: t0.addingTimeInterval(2))
        try library.addTag(named: "swift", to: tagged, now: t0)
        let trashed = library.createNote(body: "Trashed", now: t0.addingTimeInterval(3))
        library.trash(trashed, now: t0)
        let tagID = try #require(tagged.tags?.first?.id)
        let all = [inWork, loose, tagged, trashed]

        #expect(Set(titles(NoteFilter.apply(to: all, scope: .all))) == ["In work", "Loose", "Tagged"])
        #expect(Set(titles(NoteFilter.apply(to: all, scope: .unfiled))) == ["Loose", "Tagged"])
        #expect(titles(NoteFilter.apply(to: all, scope: .folder(work.id))) == ["In work"])
        #expect(titles(NoteFilter.apply(to: all, scope: .tag(tagID))) == ["Tagged"])
        #expect(titles(NoteFilter.apply(to: all, scope: .trash)) == ["Trashed"])
    }

    @Test func pinnedNotesComeFirstThenNewestModified() throws {
        let (library, _) = try makeLibrary()
        let old = library.createNote(body: "Old", now: t0)
        let new = library.createNote(body: "New", now: t0.addingTimeInterval(100))
        let pinned = library.createNote(body: "Pinned old", now: t0.addingTimeInterval(-100))
        pinned.setPinned(true, now: t0.addingTimeInterval(-100))

        let result = NoteFilter.apply(to: [old, new, pinned], scope: .all)
        #expect(titles(result) == ["Pinned old", "New", "Old"])
    }

    // MARK: Search

    @Test func searchMatchesTitleBodyAndTagNamesIgnoringCaseAndAccents() throws {
        let (library, _) = try makeLibrary()
        let inTitle = library.createNote(body: "Café plans", now: t0)
        let inBody = library.createNote(body: "Notes\nremember the CAFE trip", now: t0.addingTimeInterval(1))
        let viaTag = library.createNote(body: "Unrelated", now: t0.addingTimeInterval(2))
        try library.addTag(named: "café", to: viaTag, now: t0)
        let miss = library.createNote(body: "Nothing here", now: t0.addingTimeInterval(3))

        let found = NoteFilter.apply(to: [inTitle, inBody, viaTag, miss], scope: .all, query: "cafe")
        #expect(Set(titles(found)) == ["Café plans", "Notes", "Unrelated"])
    }

    @Test func everyWordMustMatchInAnyOrder() throws {
        let (library, _) = try makeLibrary()
        let both = library.createNote(body: "Alpha\nbeta gamma", now: t0)
        let one = library.createNote(body: "Alpha only", now: t0)

        let found = NoteFilter.apply(to: [both, one], scope: .all, query: "gamma  alpha")
        #expect(titles(found) == ["Alpha"])
        #expect(found.first === both)
    }

    @Test func titleMatchesRankAboveBodyMatches() throws {
        let (library, _) = try makeLibrary()
        let body = library.createNote(body: "Shopping\nbuy a ladder", now: t0.addingTimeInterval(100))
        let title = library.createNote(body: "Ladder safety", now: t0)

        let found = NoteFilter.apply(to: [body, title], scope: .all, query: "ladder")
        #expect(titles(found) == ["Ladder safety", "Shopping"])
    }

    @Test func pinningDoesNotReorderSearchResults() throws {
        let (library, _) = try makeLibrary()
        let newer = library.createNote(body: "Match newer", now: t0.addingTimeInterval(10))
        let pinnedOlder = library.createNote(body: "Match older", now: t0)
        pinnedOlder.setPinned(true, now: t0)

        let found = NoteFilter.apply(to: [pinnedOlder, newer], scope: .all, query: "match")
        #expect(titles(found) == ["Match newer", "Match older"])
    }

    @Test func searchEverywhereIgnoresTheSelectedFolderButHereDoesNot() throws {
        let (library, _) = try makeLibrary()
        let work = try library.createFolder(named: "Work", now: t0)
        let inWork = library.createNote(body: "Budget in work", in: work, now: t0)
        let elsewhere = library.createNote(body: "Budget elsewhere", now: t0)

        let everywhere = NoteFilter.apply(to: [inWork, elsewhere], scope: .folder(work.id), query: "budget", searchEverywhere: true)
        #expect(Set(titles(everywhere)) == ["Budget in work", "Budget elsewhere"])

        let here = NoteFilter.apply(to: [inWork, elsewhere], scope: .folder(work.id), query: "budget", searchEverywhere: false)
        #expect(titles(here) == ["Budget in work"])
    }

    @Test func searchSkipsTheTrashUnlessTheTrashIsSelected() throws {
        let (library, _) = try makeLibrary()
        let live = library.createNote(body: "Report live", now: t0)
        let gone = library.createNote(body: "Report gone", now: t0)
        library.trash(gone, now: t0)

        #expect(titles(NoteFilter.apply(to: [live, gone], scope: .all, query: "report")) == ["Report live"])
        #expect(titles(NoteFilter.apply(to: [live, gone], scope: .trash, query: "report")) == ["Report gone"])
    }

    @Test func blankQueryBehavesLikeNoSearch() throws {
        let (library, _) = try makeLibrary()
        let note = library.createNote(body: "A", now: t0)
        #expect(NoteFilter.apply(to: [note], scope: .all, query: "   ").count == 1)
    }

    // MARK: Snippets

    @Test func snippetShowsContextAroundTheFirstMatchWithEllipses() {
        let body = String(repeating: "word ", count: 40) + "needle" + String(repeating: " tail", count: 40)
        let snippet = NoteSearch.snippet(in: body, query: "NEEDLE", radius: 10)
        #expect(snippet?.contains("needle") == true)
        #expect(snippet?.hasPrefix("…") == true)
        #expect(snippet?.hasSuffix("…") == true)
    }

    @Test func snippetIsNilWhenNothingMatches() {
        #expect(NoteSearch.snippet(in: "hello world", query: "zzz") == nil)
    }

    @Test func snippetOfAShortBodyHasNoEllipses() {
        #expect(NoteSearch.snippet(in: "one two", query: "two") == "one two")
    }

    @Test func snippetStripsMarkdownAndCanSkipTheTitleLine() {
        let body = "# **Budget** Plan\n- [ ] Check [quarterly report](https://example.com)"
        #expect(NoteSearch.snippet(in: body, query: "report", skippingTitleLine: true) == "Check quarterly report")
        #expect(NoteSearch.snippet(in: body, query: "budget", skippingTitleLine: true) == nil)
        #expect(NoteSearch.snippet(in: body, query: "budget", skippingTitleLine: false) == "Budget Plan Check quarterly report")
    }

    // MARK: Folder and tag management

    @Test func renamingAFolderTrimsAndRejectsEmptyNames() throws {
        let (library, _) = try makeLibrary()
        let folder = try library.createFolder(named: "Old", now: t0)
        try library.rename(folder, to: "  New  ")
        #expect(folder.name == "New")
        #expect(throws: LibraryError.emptyName) { try library.rename(folder, to: "  ") }
        #expect(folder.name == "New")
    }

    @Test func removingATagLeavesTheNoteAndTheTag() throws {
        let (library, context) = try makeLibrary()
        let note = library.createNote(body: "n", now: t0)
        try library.addTag(named: "x", to: note, now: t0)
        let tag = try #require(note.tags?.first)

        library.remove(tag, from: note)
        #expect(note.tags?.isEmpty == true)
        #expect(try context.fetch(FetchDescriptor<NotesCore.Tag>()).count == 1)
    }

    @Test func renamingATagToAnExistingNameMergesThem() throws {
        let (library, context) = try makeLibrary()
        let a = library.createNote(body: "a", now: t0)
        let b = library.createNote(body: "b", now: t0)
        try library.addTag(named: "Swift", to: a, now: t0)
        try library.addTag(named: "code", to: b, now: t0.addingTimeInterval(1))
        let code = try #require(b.tags?.first)

        let result = try library.rename(code, to: "swift")
        try context.save()

        #expect(result.name == "Swift")
        #expect(try context.fetch(FetchDescriptor<NotesCore.Tag>()).count == 1)
        #expect(b.tags?.first === result)
        #expect(a.tags?.first === result)
    }

    @Test func renamingATagToAFreshNameJustRenames() throws {
        let (library, _) = try makeLibrary()
        let note = library.createNote(body: "n", now: t0)
        try library.addTag(named: "old", to: note, now: t0)
        let tag = try #require(note.tags?.first)
        let result = try library.rename(tag, to: " newer ")
        #expect(result === tag)
        #expect(tag.name == "newer")
    }

    @Test func deletingATagRemovesItFromNotesButKeepsTheNotes() throws {
        let (library, context) = try makeLibrary()
        let note = library.createNote(body: "n", now: t0)
        try library.addTag(named: "x", to: note, now: t0)
        let tag = try #require(note.tags?.first)

        library.delete(tag)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<NotesCore.Tag>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Note>()).count == 1)
        #expect(note.tags?.isEmpty ?? true)
    }

    @Test func deleteForeverAndEmptyTrash() throws {
        let (library, context) = try makeLibrary()
        let keep = library.createNote(body: "keep", now: t0)
        let drop = library.createNote(body: "drop", now: t0)
        let trashed = library.createNote(body: "trashed", now: t0)
        library.trash(trashed, now: t0)
        let folder = try library.createFolder(named: "F", now: t0)
        library.trash(folder, now: t0)

        library.deleteForever(drop)
        let emptied = try library.emptyTrash()
        try context.save()

        #expect(emptied.notes == 1)
        #expect(emptied.folders == 1)
        let remaining = try context.fetch(FetchDescriptor<Note>())
        #expect(remaining.count == 1)
        #expect(remaining.first === keep)
    }

    // MARK: Empty notes

    @Test func noteIsEmptyRequiresBlankBodyAndNoAttachments() throws {
        let (library, context) = try makeLibrary()
        let blank = library.createNote(body: "", now: t0)
        let whitespace = library.createNote(body: "   \n\t\n  ", now: t0)
        let markdownOnly = library.createNote(body: "# ", now: t0)
        let titled = library.createNote(body: "Hello", now: t0)
        let attached = library.createNote(body: "", now: t0)
        let file = Attachment(fileName: "photo.png", typeIdentifier: "public.png", data: Data([0x89]), now: t0)
        context.insert(file)
        file.note = attached
        try context.save()

        #expect(blank.isEmpty)
        #expect(whitespace.isEmpty)
        #expect(!markdownOnly.isEmpty)
        #expect(!titled.isEmpty)
        #expect(!attached.isEmpty)
    }

    @Test func untitledPredicateSelectsOnlyEmptyTitleNotesInScope() throws {
        let (library, context) = try makeLibrary()
        let work = try library.createFolder(named: "Work", now: t0)
        let personal = try library.createFolder(named: "Personal", now: t0)

        let emptyInWork = library.createNote(body: "", in: work, now: t0)
        let whitespaceUnfiled = library.createNote(body: " \n ", now: t0)
        let markdownOnlyInPersonal = library.createNote(body: "# ", in: personal, now: t0)
        let titledInWork = library.createNote(body: "Sprint", in: work, now: t0)
        let emptyTrashed = library.createNote(body: "", now: t0)
        library.trash(emptyTrashed, now: t0)
        try library.addTag(named: "swift", to: emptyInWork, now: t0)
        try context.save()

        let swiftTag = try #require(emptyInWork.tags?.first)
        func fetchEmpty(_ scope: NoteScope) throws -> Set<UUID> {
            let candidates = try context.fetch(FetchDescriptor<Note>(predicate: scope.untitledPredicate))
            #expect(!candidates.contains { $0.id == titledInWork.id })
            return Set(candidates.filter(\.isEmpty).map(\.id))
        }

        #expect(try fetchEmpty(.all) == [emptyInWork.id, whitespaceUnfiled.id])
        #expect(try fetchEmpty(.unfiled) == [whitespaceUnfiled.id])
        #expect(try fetchEmpty(.folder(work.id)) == [emptyInWork.id])
        #expect(try fetchEmpty(.folder(personal.id)).isEmpty)
        #expect(try fetchEmpty(.tag(swiftTag.id)) == [emptyInWork.id])
        #expect(try fetchEmpty(.trash) == [emptyTrashed.id])
        #expect(NoteScope.folder(personal.id).contains(markdownOnlyInPersonal))
        #expect(!NoteScope.folder(work.id).contains(whitespaceUnfiled))
        #expect(!NoteScope.all.contains(emptyTrashed))
    }
}
