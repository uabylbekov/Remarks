import Testing
import Foundation
@testable import RemarksCore

/// The parts of "Write note with Apple Intelligence" that do not need the model.
struct NoteWriterTests {
    @Test func theInstructionsAskForMarkdownWithAHeading() {
        let text = NoteWriter.instructions(locale: Locale(identifier: "en_US"))
        #expect(text.contains("# "))
        #expect(text.contains("fenced code blocks"))
    }

    @Test func englishUSAddsNoLocaleLine() {
        #expect(!NoteWriter.instructions(locale: Locale(identifier: "en_US")).contains("locale"))
    }

    @Test func otherLocalesAreNamedForTheModel() {
        #expect(NoteWriter.instructions(locale: Locale(identifier: "de_DE")).contains("The person's locale is de_DE."))
    }

    @Test func aNoteEntityWithTextTransfersAsItsText() {
        let note = Note(body: "Plan\nShip it", now: Date(timeIntervalSince1970: 1))
        let entity = NoteEntity(NoteInfo(note), content: "Plan\nShip it")
        #expect(entity.plainText == "Plan\nShip it")
    }

    @Test func aNoteEntityWithoutTextTransfersTitleAndPreview() {
        let note = Note(body: "Plan\nShip it", now: Date(timeIntervalSince1970: 1))
        #expect(NoteEntity(NoteInfo(note)).plainText == "Plan\nShip it")
    }
}
