import Foundation
import FoundationModels

/// Why Apple Intelligence could not write a note.
public enum NoteWriterError: Error, Equatable {
    /// Apple Intelligence is off, still downloading, or this device does not have it.
    case unavailable
    /// The model refused the topic, or answered with nothing.
    case couldNotWrite
    /// The topic is in a language the model does not support.
    case unsupportedLanguage
}

/// Writes the text of a note from a topic, with the on-device model (Apple Intelligence). Nothing leaves the device.
/// The model answers from what it learned in training. It does not search the web, so facts can be wrong or out of date.
public enum NoteWriter {
    /// What the model is told. The note is Markdown, so headings and fenced code come out in the form the editor shows.
    static func instructions(locale: Locale = .current) -> String {
        var text = """
        You write notes for a Markdown notes app. Reply with the note only, no introduction and no closing remarks.
        Start with a short "# " heading, then clear, concise content.
        Use lists and short sections where they help. Put code in fenced code blocks that name the language.
        If you are not sure of a fact, leave it out instead of guessing.
        """
        // The model answers in the language of the topic. Say which locale the person uses, for better wording.
        if !Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) {
            text += "\nThe person's locale is \(locale.identifier)."
        }
        return text
    }

    /// The note's Markdown, for `topic`.
    public static func write(about topic: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw NoteWriterError.unavailable }

        let session = LanguageModelSession(model: model, instructions: instructions())
        let reply: String
        do {
            reply = try await session.respond(to: "Write a note about: \(topic)").content
        } catch let error as LanguageModelError {
            if case .unsupportedLanguageOrLocale = error { throw NoteWriterError.unsupportedLanguage }
            throw NoteWriterError.couldNotWrite
        }

        let note = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw NoteWriterError.couldNotWrite }
        return note + "\n"
    }
}
