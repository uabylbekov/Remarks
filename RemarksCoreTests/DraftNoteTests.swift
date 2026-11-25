import Foundation
import Testing
@testable import RemarksCore

@Suite("DraftNote")
struct DraftNoteTests {
    private let folderID = UUID()
    private let otherFolderID = UUID()

    @Test("Moving to the place the draft was created for does not leave the draft")
    func staysWhenTheScopeIsTheOneItWasCreatedFor() {
        let draft = DraftNote(id: UUID(), scope: .folder(folderID))

        #expect(!draft.isLeft(whenScopeBecomes: .folder(folderID)))
    }

    @Test("New Note from Recently Deleted creates the draft in All Notes, so moving there keeps it")
    func newNoteFromRecentlyDeletedKeepsTheDraft() {
        // Recently Deleted cannot show a new note, so the note is created in All Notes and the window moves there.
        let draft = DraftNote(id: UUID(), scope: .all)

        #expect(!draft.isLeft(whenScopeBecomes: .all))
    }

    @Test("Moving to a different folder leaves the draft")
    func leavesWhenTheFolderChanges() {
        let draft = DraftNote(id: UUID(), scope: .folder(folderID))

        #expect(draft.isLeft(whenScopeBecomes: .folder(otherFolderID)))
    }

    @Test("Moving from a folder to All Notes leaves the draft")
    func leavesWhenMovingToAnotherKindOfPlace() {
        let draft = DraftNote(id: UUID(), scope: .folder(folderID))

        #expect(draft.isLeft(whenScopeBecomes: .all))
        #expect(draft.isLeft(whenScopeBecomes: .unfiled))
        #expect(draft.isLeft(whenScopeBecomes: .trash))
    }

    @Test("Moving to no place at all leaves the draft")
    func leavesWhenThereIsNoPlace() {
        let draft = DraftNote(id: UUID(), scope: .all)

        #expect(draft.isLeft(whenScopeBecomes: nil))
    }
}
