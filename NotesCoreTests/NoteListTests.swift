import Testing
import Foundation
import SwiftData
@testable import NotesCore

/// The logic behind the note list: remembering the place, where a new note goes, search that matches what is visible,
/// a stable order, loading without bodies, and the picture at the start of a note.
struct NoteListTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

    // MARK: Remembering the place

    @Test(arguments: [NoteScope.all, .unfiled, .trash, .folder(UUID()), .tag(UUID())])
    func aScopeSurvivesItsStorageKey(scope: NoteScope) {
        #expect(NoteScope(storageKey: scope.storageKey) == scope)
    }

    @Test func anUnreadableStorageKeyIsNotAScope() {
        for key in ["", "folder", "folder:not-a-uuid", "tag:", "elsewhere"] {
            #expect(NoteScope(storageKey: key) == nil, "\(key)")
        }
    }

    // MARK: Where a new note goes

    @Test func aNewNoteGoesWhereTheScopeSays() throws {
        let (library, context) = try makeLibrary()
        let folder = try library.createFolder(named: "Work", now: t0)
        let tag = try library.tag(named: "swift", now: t0)
        try context.save()

        let filed = try library.createNote(in: .folder(folder.id), now: t0)
        #expect(filed.folder === folder)

        let tagged = try library.createNote(in: .tag(tag.id), now: t0)
        #expect(tagged.tags?.contains { $0 === tag } == true)
        #expect(tagged.folder == nil)

        for scope in [NoteScope.all, .unfiled, .trash] {
            let note = try library.createNote(in: scope, now: t0)
            #expect(note.folder == nil)
            #expect(note.tags?.isEmpty ?? true)
            #expect(note.deletedAt == nil)
        }
    }

    @Test func aNewNoteForAFolderOrTagThatIsGoneStaysAMereNote() throws {
        let (library, _) = try makeLibrary()
        let trashed = try library.createFolder(named: "Old", now: t0)
        library.trash(trashed, now: t0)

        #expect(try library.createNote(in: .folder(trashed.id), now: t0).folder == nil)
        #expect(try library.createNote(in: .folder(UUID()), now: t0).folder == nil)
        #expect(try library.createNote(in: .tag(UUID()), now: t0).tags?.isEmpty ?? true)
    }

    // MARK: Search

    @Test func searchMatchesWhatYouCanSeeNotMarkdownSyntax() throws {
        let (library, _) = try makeLibrary()
        let id = UUID()
        let note = library.createNote(
            body: "Trip\n![Beach photo](attachment://\(id.uuidString))\nSee [the docs](https://example.com/secret-path)",
            now: t0
        )
        func finds(_ query: String) -> Bool { !NoteFilter.apply(to: [note], scope: .all, query: query).isEmpty }

        #expect(finds("beach"))
        #expect(finds("docs"))
        #expect(finds("trip"))
        #expect(!finds("secret"))
        #expect(!finds("attachment"))
        #expect(!finds(String(id.uuidString.prefix(8))))
    }

    @Test func searchStillFindsBodyTextAndTags() throws {
        let (library, _) = try makeLibrary()
        let note = library.createNote(body: "Groceries\nbuy **oat milk** today", now: t0)
        try library.addTag(named: "errands", to: note, now: t0)

        #expect(!NoteFilter.apply(to: [note], scope: .all, query: "oat milk").isEmpty)
        #expect(!NoteFilter.apply(to: [note], scope: .all, query: "errands").isEmpty)
        #expect(NoteFilter.apply(to: [note], scope: .all, query: "oat butter").isEmpty)
    }

    // MARK: Order

    @Test func notesEditedAtTheSameInstantKeepAStableOrder() throws {
        let (library, context) = try makeLibrary()
        let older = library.createNote(body: "older", now: t0)
        let newer = library.createNote(body: "newer", now: t0.addingTimeInterval(1))
        let edited = t0.addingTimeInterval(10)
        older.setBody("older, edited", now: edited)
        newer.setBody("newer, edited", now: edited)
        try context.save()

        let fetched = try context.fetch(NoteScope.all.fetchDescriptor(isPinned: false)).map(\.id)
        #expect(fetched == [newer.id, older.id])
        // The same rule when the list sorts in memory, whatever order the notes arrive in.
        #expect(NoteFilter.apply(to: [older, newer], scope: .all).map(\.id) == fetched)
    }

    // MARK: Loading

    @Test func theListCanLoadNotesWithoutTheirBodies() throws {
        let (library, context) = try makeLibrary()
        let body = "Title\n" + String(repeating: "some text ", count: 300)
        let note = library.createNote(body: body, now: t0)
        note.setPinned(true, now: t0)
        try context.save()

        // A fresh context, so nothing is already in memory.
        let fresh = ModelContext(context.container)
        let loaded = try fresh.fetch(NoteScope.all.fetchDescriptor(isPinned: true, includesBody: false))
        let first = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(first.title == "Title")
        #expect(first.isPinned)
        // The body is still there when something asks for it.
        #expect(first.body == body)
    }

    /// Every place must load the same notes whether or not the bodies come with them. Recently Deleted once showed
    /// nothing while its counter said 2.
    @Test func everyScopeLoadsTheSameNotesWithOrWithoutBodies() throws {
        let (library, context) = try makeLibrary()
        let folder = try library.createFolder(named: "Work", now: t0)
        let tag = try library.tag(named: "swift", now: t0)
        let loose = library.createNote(body: "Loose\ntext", now: t0)
        let filed = library.createNote(body: "Filed\ntext", in: folder, now: t0.addingTimeInterval(1))
        let pinned = library.createNote(body: "Pinned\ntext", now: t0.addingTimeInterval(2))
        pinned.setPinned(true, now: t0.addingTimeInterval(2))
        let tagged = library.createNote(body: "Tagged\ntext", now: t0.addingTimeInterval(3))
        tagged.tags = [tag]
        let gone = library.createNote(body: "Gone\ntext", now: t0.addingTimeInterval(4))
        let alsoGone = library.createNote(body: "Also gone\ntext", in: folder, now: t0.addingTimeInterval(5))
        library.trash(gone, now: t0.addingTimeInterval(10))
        library.trash(alsoGone, now: t0.addingTimeInterval(11))
        _ = (loose, filed)
        try context.save()

        let fresh = ModelContext(context.container)
        for scope in [NoteScope.all, .unfiled, .folder(folder.id), .tag(tag.id), .trash] {
            for isPinned in [true, false] {
                let withBodies = try fresh.fetch(scope.fetchDescriptor(isPinned: isPinned, includesBody: true)).map(\.id)
                let without = try fresh.fetch(scope.fetchDescriptor(isPinned: isPinned, includesBody: false)).map(\.id)
                #expect(without == withBodies, "\(scope) pinned: \(isPinned)")
            }
        }
        let trashed = try fresh.fetch(NoteScope.trash.fetchDescriptor(isPinned: false, includesBody: false))
        #expect(trashed.count == 2)
    }

    // MARK: The picture at the start of a note

    @Test func aNoteStartingWithAnImageNamesIt() {
        let id = UUID()
        let image = "![Beach](attachment://\(id.uuidString))"

        #expect(NoteText.leadingImageID(in: image) == id)
        #expect(NoteText.leadingImageID(in: "\n  \n\(image)\nTrip") == id)
        #expect(NoteText.leadingImageID(in: "Trip\n\(image)") == nil)
        #expect(NoteText.leadingImageID(in: "[Report.pdf](attachment://\(id.uuidString))") == nil)
        #expect(NoteText.leadingImageID(in: "# Heading") == nil)
        #expect(NoteText.leadingImageID(in: "") == nil)
    }

    @Test func theTrashIsKeptForThirtyDays() {
        #expect(Library.trashRetentionDays == 30)
    }
}
