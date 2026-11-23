import Testing
@testable import RemarksCore

/// Spec 06: an outside change must never be lost when the note is open in the editor.
struct EditorSyncTests {
    @Test func untouchedEditorFollowsAnOutsideChange() {
        #expect(EditorSync.decide(editorText: "a", baseBody: "a", incomingBody: "a\nb") == .adoptIncoming)
    }

    @Test func typingAloneIsNotAnOutsideChange() {
        // The user typed "ab"; the note still holds "a" because the save is pending.
        #expect(EditorSync.decide(editorText: "ab", baseBody: "a", incomingBody: "a") == .keepEditorText)
    }

    @Test func sameTextEverywhereChangesNothing() {
        #expect(EditorSync.decide(editorText: "a", baseBody: "a", incomingBody: "a") == .keepEditorText)
        // After the editor saved its own text, the stored text equals the editor's text.
        #expect(EditorSync.decide(editorText: "ab", baseBody: "a", incomingBody: "ab") == .keepEditorText)
    }

    @Test func typingPlusAnOutsideChangeKeepsTheTypingAndSavesTheOutsideText() {
        #expect(EditorSync.decide(editorText: "a typed", baseBody: "a", incomingBody: "a\nfrom siri")
            == .keepTypedTextAndSaveIncoming)
    }

    @Test func anOutsideChangeToEmptyIsStillAChange() {
        #expect(EditorSync.decide(editorText: "a", baseBody: "a", incomingBody: "") == .adoptIncoming)
        #expect(EditorSync.decide(editorText: "a typed", baseBody: "a", incomingBody: "") == .keepTypedTextAndSaveIncoming)
    }

    @Test func aNewEmptyNoteFollowsAnAppend() {
        #expect(EditorSync.decide(editorText: "", baseBody: "", incomingBody: "hello") == .adoptIncoming)
    }

    @Test func savingOverUnseenTextIsFlagged() {
        #expect(EditorSync.unseenTextBeingOverwritten(editorText: "mine", baseBody: "a", storedBody: "a\nfrom siri"))
    }

    @Test func savingOverTextTheEditorAlreadyKnowsIsNotFlagged() {
        #expect(!EditorSync.unseenTextBeingOverwritten(editorText: "mine", baseBody: "a", storedBody: "a"))
        #expect(!EditorSync.unseenTextBeingOverwritten(editorText: "mine", baseBody: "a", storedBody: "mine"))
        #expect(!EditorSync.unseenTextBeingOverwritten(editorText: "mine", baseBody: "a", storedBody: ""))
    }
}
