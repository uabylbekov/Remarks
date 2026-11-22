import Testing
import Foundation
@testable import NotesCore

struct TextEditTransactionTests {
    @Test(arguments: MarkdownCommand.allCases)
    func formattingRestoresTextAndSelectionThroughUndoAndRedo(_ command: MarkdownCommand) throws {
        let text = "😀 hello\nworld\n"
        let selection = (text as NSString).range(of: "hello")
        let edit = MarkdownEditing.edit(command, in: text, selection: selection)
        let transaction = try #require(edit.transaction(in: text, selectionBefore: selection))
        let undo = try #require(transaction.inverse.transaction(in: transaction.result, selectionBefore: edit.selection))
        #expect(undo.result == text)
        #expect(undo.edit.selection == selection)
        let redo = try #require(undo.inverse.transaction(in: undo.result, selectionBefore: selection))
        #expect(redo.result == transaction.result)
        #expect(redo.edit.selection == edit.selection)
    }

    @Test func checklistToggleAndAttachmentInsertionAreReversible() throws {
        let text = "- [ ] 😀 task\n"
        let selection = NSRange(location: text.utf16.count, length: 0)
        let toggle = try #require(MarkdownEditing.toggleChecklist(in: text, atLine: 0, keepingSelection: selection))
        let toggled = try #require(toggle.transaction(in: text, selectionBefore: selection))
        let insertion = MarkdownEditing.insertBlock("![Image](attachment://example)", in: toggled.result, selection: toggle.selection)
        let inserted = try #require(insertion.transaction(in: toggled.result, selectionBefore: toggle.selection))
        let undoInsertion = try #require(inserted.inverse.transaction(in: inserted.result, selectionBefore: insertion.selection))
        #expect(undoInsertion.result == toggled.result)
        let undoToggle = try #require(toggled.inverse.transaction(in: undoInsertion.result, selectionBefore: toggle.selection))
        #expect(undoToggle.result == text)
        #expect(undoToggle.edit.selection == selection)
    }

    @Test func invalidOrStaleRangesAndSelectionsAreRejected() {
        let text = "😀abc"
        let caret = NSRange(location: 0, length: 0)
        let invalid = [
            TextEdit(range: NSRange(location: NSNotFound, length: 1), replacement: "", selection: caret),
            TextEdit(range: NSRange(location: 0, length: Int.max), replacement: "", selection: caret),
            TextEdit(range: NSRange(location: 1, length: 1), replacement: "", selection: caret),
            TextEdit(range: caret, replacement: "x", selection: NSRange(location: 99, length: 0))
        ]
        for edit in invalid {
            #expect(edit.transaction(in: text, selectionBefore: caret) == nil)
        }
    }

    @Test func selectionOnlyEditDoesNotCreateATextChange() throws {
        let edit = TextEdit(range: NSRange(location: 0, length: 3), replacement: "abc", selection: NSRange(location: 3, length: 0))
        let transaction = try #require(edit.transaction(in: "abc", selectionBefore: NSRange(location: 0, length: 0)))
        #expect(!transaction.changesText)
        #expect(transaction.result == "abc")
    }
}
