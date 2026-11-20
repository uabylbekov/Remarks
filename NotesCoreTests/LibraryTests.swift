import Testing
import Foundation
import SwiftData
@testable import NotesCore

/// Spec 01 acceptance criteria 3: dedupe, cycles, soft delete and purge, unfiled notes.
struct LibraryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

    // MARK: Tags

    @Test func tagLookupIgnoresCaseAndAccentsAndReusesTheExistingTag() throws {
        let (library, context) = try makeLibrary()
        let first = try library.tag(named: "Café", now: t0)
        let second = try library.tag(named: "  cafe ", now: t0.addingTimeInterval(10))
        #expect(first === second)
        #expect(try context.fetch(FetchDescriptor<NotesCore.Tag>()).count == 1)
    }

    @Test func emptyTagAndFolderNamesAreRejected() throws {
        let (library, _) = try makeLibrary()
        #expect(throws: LibraryError.emptyName) { try library.tag(named: "   ") }
        #expect(throws: LibraryError.emptyName) { try library.createFolder(named: "") }
    }

    @Test func dedupeMergesDuplicateTagsIntoTheOldestAndRelinksNotes() throws {
        let (library, context) = try makeLibrary()
        let older = Tag(name: "swift", now: t0)
        let newer = Tag(name: "Swift", now: t0.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        let a = library.createNote(body: "a", now: t0)
        let b = library.createNote(body: "b", now: t0)
        a.tags = [older]
        b.tags = [newer]
        try context.save()

        let removed = try library.dedupeTags()
        try context.save()

        #expect(removed == 1)
        let tags = try context.fetch(FetchDescriptor<NotesCore.Tag>())
        #expect(tags.count == 1)
        #expect(tags.first?.id == older.id)
        #expect(a.tags?.count == 1)
        #expect(b.tags?.first?.id == older.id)
    }

    @Test func dedupeKeepsOneLinkWhenANoteHadBothDuplicates() throws {
        let (library, context) = try makeLibrary()
        let one = Tag(name: "x", now: t0)
        let two = Tag(name: "X", now: t0.addingTimeInterval(1))
        context.insert(one)
        context.insert(two)
        let note = library.createNote(body: "n", now: t0)
        note.tags = [one, two]

        try library.dedupeTags()
        #expect(note.tags?.count == 1)
        #expect(note.tags?.first?.id == one.id)
    }

    @Test func dedupeKeepsTheMostRecentlyModifiedNoteWhenIDsCollide() throws {
        let (library, context) = try makeLibrary()
        let stale = Note(body: "stale", now: t0)
        let fresh = Note(body: "fresh", now: t0.addingTimeInterval(100))
        context.insert(stale)
        context.insert(fresh)
        // Simulate a sync race: two rows with the same id.
        stale.id = fresh.id

        let removed = try library.dedupeNotes()
        try context.save()

        #expect(removed == 1)
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.body == "fresh")
    }

    // MARK: Folders

    @Test func newFoldersGetIncreasingSortIndexesAmongSiblings() throws {
        let (library, _) = try makeLibrary()
        let a = try library.createFolder(named: "A")
        let b = try library.createFolder(named: "B")
        let child = try library.createFolder(named: "Child", in: a)
        #expect(b.sortIndex > a.sortIndex)
        #expect(child.sortIndex == 0)
        #expect(child.parent === a)
    }

    @Test func movingAFolderUnderItselfOrADescendantIsRejected() throws {
        let (library, _) = try makeLibrary()
        let a = try library.createFolder(named: "A")
        let b = try library.createFolder(named: "B", in: a)
        let c = try library.createFolder(named: "C", in: b)

        #expect(throws: LibraryError.wouldCreateCycle) { try library.move(a, to: a) }
        #expect(throws: LibraryError.wouldCreateCycle) { try library.move(a, to: c) }
        try library.move(c, to: a)
        #expect(c.parent === a)
        try library.move(c, to: nil)
        #expect(c.parent == nil)
    }

    @Test func treeWalkTerminatesEvenIfSyncDeliversACycle() throws {
        let (library, context) = try makeLibrary()
        let a = Folder(name: "A", now: t0)
        let b = Folder(name: "B", now: t0)
        context.insert(a)
        context.insert(b)
        a.parent = b
        b.parent = a

        #expect(Library.isDescendant(a, of: b))
        let outsider = Folder(name: "Z", now: t0)
        context.insert(outsider)
        #expect(!Library.isDescendant(a, of: outsider))
        library.trash(a, now: t0)
        #expect(a.deletedAt == t0)
        #expect(b.deletedAt == t0)
    }

    // MARK: Trash, restore, purge

    @Test func trashAndRestoreANote() throws {
        let (library, _) = try makeLibrary()
        let note = library.createNote(body: "x", now: t0)
        library.trash(note, now: t0.addingTimeInterval(5))
        #expect(note.deletedAt == t0.addingTimeInterval(5))
        library.restore(note, now: t0.addingTimeInterval(9))
        #expect(note.deletedAt == nil)
    }

    @Test func restoringANoteWhoseFolderIsTrashedMovesItToUnfiled() throws {
        let (library, _) = try makeLibrary()
        let folder = try library.createFolder(named: "F", now: t0)
        let note = library.createNote(body: "x", in: folder, now: t0)
        library.trash(folder, now: t0)

        library.restore(note, now: t0.addingTimeInterval(1))
        #expect(note.deletedAt == nil)
        #expect(note.folder == nil)
    }

    @Test func trashingAFolderTrashesTheSubtreeAndRestoreUndoesOnlyThatOperation() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        let inParent = library.createNote(body: "p", in: parent, now: t0)
        let inChild = library.createNote(body: "c", in: child, now: t0)
        let earlier = library.createNote(body: "e", in: parent, now: t0)
        let earlierStamp = t0.addingTimeInterval(-day)
        library.trash(earlier, now: earlierStamp)

        let stamp = t0.addingTimeInterval(60)
        library.trash(parent, now: stamp)
        #expect(parent.deletedAt == stamp)
        #expect(child.deletedAt == stamp)
        #expect(inParent.deletedAt == stamp)
        #expect(inChild.deletedAt == stamp)
        #expect(earlier.deletedAt == earlierStamp)

        library.restore(parent)
        #expect(parent.deletedAt == nil)
        #expect(child.deletedAt == nil)
        #expect(inParent.deletedAt == nil)
        #expect(inChild.deletedAt == nil)
        #expect(earlier.deletedAt == earlierStamp)
    }

    @Test func restoringAChildFolderWhoseParentIsTrashedMovesItToTheTopLevel() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "P", now: t0)
        let child = try library.createFolder(named: "C", in: parent, now: t0)
        library.trash(parent, now: t0)
        library.restore(child)
        #expect(child.deletedAt == nil)
        #expect(child.parent == nil)
        #expect(parent.deletedAt == t0)
    }

    @Test func purgeRemovesItemsTrashedThirtyDaysAgoAndKeepsNewerOnes() throws {
        let (library, context) = try makeLibrary()
        let now = t0.addingTimeInterval(100 * day)
        let expired = library.createNote(body: "old", now: t0)
        let almost = library.createNote(body: "almost", now: t0)
        let live = library.createNote(body: "live", now: t0)
        library.trash(expired, now: now.addingTimeInterval(-30 * day))
        library.trash(almost, now: now.addingTimeInterval(-29 * day))
        let oldFolder = try library.createFolder(named: "gone", now: t0)
        library.trash(oldFolder, now: now.addingTimeInterval(-31 * day))
        try context.save()

        let purged = try library.purgeExpired(now: now)
        try context.save()

        #expect(purged.notes == 1) // only `expired`: `oldFolder` is empty
        #expect(purged.folders == 1)
        let remaining = Set(try context.fetch(FetchDescriptor<Note>()).map(\.body))
        #expect(remaining == ["almost", "live"])
        #expect(live.deletedAt == nil)
    }

    @Test func unfiledNotesExcludeTrashedAndFiledNotes() throws {
        let (library, _) = try makeLibrary()
        let folder = try library.createFolder(named: "F", now: t0)
        library.createNote(body: "filed", in: folder, now: t0)
        let loose = library.createNote(body: "loose", now: t0)
        let trashed = library.createNote(body: "trashed", now: t0)
        library.trash(trashed, now: t0)

        let unfiled = try library.unfiledNotes()
        #expect(unfiled.count == 1)
        #expect(unfiled.first === loose)
    }
}
