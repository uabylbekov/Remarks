import Testing
import Foundation
import SwiftData
@testable import RemarksCore

/// Spec 01 acceptance criteria 3: dedupe, cycles, soft delete and purge, unfiled notes.
struct LibraryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

    @Test func purgingAnExpiredParentKeepsAChildWithinItsOwnRetentionPeriod() throws {
        let (library, context) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        parent.deletedAt = t0
        child.deletedAt = t0.addingTimeInterval(29 * day)
        let childID = child.id
        try context.save()

        let report = try library.purgeExpired(now: t0.addingTimeInterval(31 * day))
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<Folder>())
        #expect(report.folders == 1)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == childID)
        #expect(remaining.first?.parent == nil)
        #expect(remaining.first?.deletedAt == t0.addingTimeInterval(29 * day))
    }

    @Test func emptyTrashDoesNotCascadeIntoALiveSyncedChild() throws {
        let (library, context) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        let childID = child.id
        parent.deletedAt = t0
        try context.save()

        try library.emptyTrash()
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<Folder>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == childID)
        #expect(remaining.first?.parent == nil)
    }

    @Test func deletingAnEmptyDraftDismissesItWithoutAddingItToTrash() throws {
        let (library, context) = try makeLibrary()
        let draft = library.createNote(body: " \n\t")
        let draftID = draft.id
        let existing = library.createNote(body: "Keep me")
        try context.save()

        library.delete(draft)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Note>())
        #expect(!remaining.contains { $0.id == draftID })
        #expect(remaining.first?.id == existing.id)
        #expect(remaining.allSatisfy { $0.deletedAt == nil })
    }

    @Test func deletingANoteWithContentMovesItToRecentlyDeleted() throws {
        let (library, context) = try makeLibrary()
        let note = library.createNote(body: "Keep this recoverable")
        let noteID = note.id
        try context.save()

        library.delete(note, now: t0)
        try context.save()

        let remaining = try #require(context.fetch(FetchDescriptor<Note>()).first { $0.id == noteID })
        #expect(remaining.deletedAt == t0)
        #expect(remaining.body == "Keep this recoverable")
    }

    @Test func aBlankNoteWithAnAttachmentIsRecoverableWhenDeleted() throws {
        let (library, context) = try makeLibrary()
        let note = library.createNote()
        try AttachmentStore(context: context).add(
            data: Data([1, 2]), fileName: "Plan.pdf", typeIdentifier: "com.adobe.pdf", to: note
        )
        try context.save()

        library.delete(note, now: t0)
        try context.save()

        #expect(note.deletedAt == t0)
        #expect(note.attachments?.first?.data == Data([1, 2]))
    }

    // MARK: Tags

    @Test func tagLookupIgnoresCaseAndAccentsAndReusesTheExistingTag() throws {
        let (library, context) = try makeLibrary()
        let first = try library.tag(named: "Café", now: t0)
        let second = try library.tag(named: "  cafe ", now: t0.addingTimeInterval(10))
        #expect(first === second)
        #expect(try context.fetch(FetchDescriptor<RemarksCore.Tag>()).count == 1)
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
        let tags = try context.fetch(FetchDescriptor<RemarksCore.Tag>())
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

    @Test func recoveryCopyKeepsIndependentAttachmentsAndTags() throws {
        let (library, context) = try makeLibrary()
        let note = library.createNote(body: "Incoming", now: t0)
        try library.addTag(named: "important", to: note)
        let attachment = try AttachmentStore(context: context).add(
            data: Data([1, 2, 3]), fileName: "Plan.pdf", typeIdentifier: "com.adobe.pdf", to: note
        )
        attachment.altText = "Plan"
        note.setBody("Incoming\n" + AttachmentStore.markdown(for: attachment))
        let copy = library.createRecoveryCopy(of: note)
        try context.save()

        let cloned = try #require(copy.attachments?.first)
        #expect(copy.id != note.id)
        #expect(cloned.id != attachment.id)
        #expect(cloned.data == attachment.data)
        #expect(cloned.altText == "Plan")
        #expect(copy.tags?.first?.name == "important")
        #expect(AttachmentLine.references(in: copy.body) == [cloned.id])
        #expect(AttachmentLine.references(in: note.body) == [attachment.id])

        library.deleteForever(note)
        try context.save()
        #expect(copy.attachments?.first?.data == Data([1, 2, 3]))
    }

    @Test func dedupeKeepsAttachmentsDeliveredOnTheLosingRow() throws {
        let (library, context) = try makeLibrary()
        let stale = library.createNote(now: t0)
        let fresh = library.createNote(now: t0.addingTimeInterval(100))
        stale.id = fresh.id
        let attachment = try AttachmentStore(context: context).add(
            data: Data([4, 5]), fileName: "Plan.pdf", typeIdentifier: "com.adobe.pdf", to: stale
        )
        let attachmentID = attachment.id
        fresh.setBody(AttachmentStore.markdown(for: attachment), now: t0.addingTimeInterval(100))
        try context.save()

        #expect(try library.dedupeNotes() == 1)
        try context.save()
        #expect(fresh.attachments?.first?.id == attachmentID)
        #expect(fresh.attachments?.first?.data == Data([4, 5]))
        #expect(try context.fetch(FetchDescriptor<RemarksCore.Attachment>()).count == 1)
    }

    @Test func dedupeFillsAnAttachmentWhosePayloadHasNotArrived() throws {
        let (library, context) = try makeLibrary()
        let stale = library.createNote(now: t0)
        let fresh = library.createNote(now: t0.addingTimeInterval(100))
        stale.id = fresh.id
        let attachment = try AttachmentStore(context: context).add(
            data: Data([7, 8]), fileName: "Plan.pdf", typeIdentifier: "com.adobe.pdf", to: stale
        )
        let pending = Attachment(id: attachment.id, fileName: "Plan.pdf", typeIdentifier: "com.adobe.pdf")
        context.insert(pending)
        pending.note = fresh
        fresh.setBody(AttachmentStore.markdown(for: attachment), now: t0.addingTimeInterval(100))
        try context.save()

        #expect(try library.dedupeNotes() == 1)
        try context.save()
        #expect(fresh.attachments?.count == 1)
        #expect(pending.data == Data([7, 8]))
        #expect(pending.byteCount == 2)
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

    @Test func aFolderMovedBeforeASiblingLandsBetweenItsNeighbors() throws {
        let (library, _) = try makeLibrary()
        let a = try library.createFolder(named: "A")
        let b = try library.createFolder(named: "B")
        let c = try library.createFolder(named: "C")
        func order() -> [String] { [a, b, c].sorted { $0.sortIndex < $1.sortIndex }.map(\.name) }

        try library.move(c, to: nil, before: b)
        #expect(order() == ["A", "C", "B"])
        try library.move(c, to: nil, before: a)
        #expect(order() == ["C", "A", "B"])
        try library.move(c, to: nil, before: nil)
        #expect(order() == ["A", "B", "C"])
    }

    @Test func aFolderMovedUnderAnotherJoinsItsChildrenInPlace() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent")
        let first = try library.createFolder(named: "First", in: parent)
        let second = try library.createFolder(named: "Second", in: parent)
        let moved = try library.createFolder(named: "Moved")

        try library.move(moved, to: parent, before: second)

        #expect(moved.parent === parent)
        #expect((parent.children ?? []).sorted { $0.sortIndex < $1.sortIndex }.map(\.name) == ["First", "Moved", "Second"])
        #expect(first.sortIndex < moved.sortIndex && moved.sortIndex < second.sortIndex)
    }

    @Test func aFolderCannotBeMovedIntoItsOwnSubtreeWhenReordering() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent")
        let child = try library.createFolder(named: "Child", in: parent)
        #expect(throws: LibraryError.wouldCreateCycle) { try library.move(parent, to: child, before: nil) }
        #expect(parent.parent == nil)
    }

    @Test func manyInsertionsInTheSameGapKeepTheOrder() throws {
        let (library, _) = try makeLibrary()
        let first = try library.createFolder(named: "first")
        let last = try library.createFolder(named: "last")
        let inserted = try (0..<40).map { try library.createFolder(named: "f\($0)") }
        for folder in inserted { try library.move(folder, to: nil, before: last) }

        let order = ([first, last] + inserted).sorted { $0.sortIndex < $1.sortIndex }.map(\.name)
        #expect(order == ["first"] + (0..<40).map { "f\($0)" } + ["last"])
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

    @Test func libraryErrorsProvideHumanReadableDescriptions() {
        #expect(LibraryError.emptyName.errorDescription == "The name can’t be empty.")
        #expect(LibraryError.wouldCreateCycle.errorDescription == "A folder can’t be moved inside itself.")
        #expect(LibraryError.duplicateName.errorDescription == "A folder with that name already exists here.")
    }

    // MARK: Folders left inside the trash

    /// Another device can make a subfolder live again, or create one, after this device trashed its parent.
    @Test func aLiveFolderInsideATrashedFolderGoesToTheTopLevel() throws {
        let (library, context) = try makeLibrary()
        let other = try library.createFolder(named: "Other", now: t0)
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        library.trash(parent, now: t0)
        child.deletedAt = nil
        try context.save()

        #expect(try library.rescueOrphanedFolders() == 1)
        #expect(child.parent == nil)
        #expect(child.sortIndex > other.sortIndex)
        // Nothing is left to rescue.
        #expect(try library.rescueOrphanedFolders() == 0)
    }

    @Test func aRescuedFolderSurvivesItsParentBeingPurged() throws {
        let (library, context) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        let note = library.createNote(body: "kept", in: child, now: t0)
        library.trash(parent, now: t0)
        child.deletedAt = nil
        note.deletedAt = nil
        try context.save()

        let report = try library.runMaintenance(now: t0.addingTimeInterval(31 * day))
        try context.save()

        #expect(report.rescuedFolders == 1)
        #expect(report.purgedFolders == 1)
        #expect(!child.isDeleted)
        #expect(child.parent == nil)
        #expect(note.folder === child)
    }

    @Test func aLiveFolderInsideALiveFolderIsLeftAlone() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)

        #expect(try library.rescueOrphanedFolders() == 0)
        #expect(child.parent === parent)
    }

    // MARK: Folder names

    @Test func siblingFoldersCannotShareANameIgnoringCaseAndAccents() throws {
        let (library, _) = try makeLibrary()
        try library.createFolder(named: "Café")
        #expect(throws: LibraryError.duplicateName) { try library.createFolder(named: "  cafe ") }

        let parent = try library.createFolder(named: "Parent")
        try library.createFolder(named: "Notes", in: parent)
        #expect(throws: LibraryError.duplicateName) { try library.createFolder(named: "notes", in: parent) }
        // The same name under another parent, or at the top level, is a different place.
        try library.createFolder(named: "Notes")
        let other = try library.createFolder(named: "Other")
        try library.createFolder(named: "Notes", in: other)
    }

    @Test func aTrashedFolderDoesNotBlockItsName() throws {
        let (library, _) = try makeLibrary()
        let old = try library.createFolder(named: "Ideas", now: t0)
        library.trash(old, now: t0)
        try library.createFolder(named: "Ideas")
    }

    @Test func renamingToASiblingsNameIsRejectedButChangingCaseIsNot() throws {
        let (library, _) = try makeLibrary()
        let work = try library.createFolder(named: "Work")
        let home = try library.createFolder(named: "Home")

        #expect(throws: LibraryError.duplicateName) { try library.rename(home, to: "work") }
        #expect(home.name == "Home")
        try library.rename(work, to: "WORK")
        #expect(work.name == "WORK")
    }

    @Test func movingUnderAParentThatHasTheNameIsRejectedButReorderingIsNot() throws {
        let (library, _) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent")
        try library.createFolder(named: "Notes", in: parent)
        let first = try library.createFolder(named: "First", in: parent)
        let second = try library.createFolder(named: "Second", in: parent)
        let topLevel = try library.createFolder(named: "notes")

        #expect(throws: LibraryError.duplicateName) { try library.move(topLevel, to: parent) }
        #expect(topLevel.parent == nil)
        // Same parent: only the order changes.
        try library.move(second, to: parent, before: first)
        #expect(second.parent === parent)
    }

    @Test func emptyTrashRemovesNestedTrashedFoldersAndNotesCleanly() throws {
        let (library, context) = try makeLibrary()
        let parent = try library.createFolder(named: "Parent", now: t0)
        let child = try library.createFolder(named: "Child", in: parent, now: t0)
        let grandchild = try library.createFolder(named: "Grandchild", in: child, now: t0)
        _ = library.createNote(body: "in parent", in: parent, now: t0)
        _ = library.createNote(body: "in grandchild", in: grandchild, now: t0)
        let liveNote = library.createNote(body: "keep me", now: t0)
        library.trash(parent, now: t0)
        try context.save()

        let removed = try library.emptyTrash()
        try context.save()

        #expect(removed.notes == 2)
        #expect(removed.folders == 3)
        let remainingNotes = try context.fetch(FetchDescriptor<Note>())
        #expect(remainingNotes.count == 1)
        #expect(remainingNotes.first?.id == liveNote.id)
        #expect(try context.fetch(FetchDescriptor<Folder>()).isEmpty)
    }
}
