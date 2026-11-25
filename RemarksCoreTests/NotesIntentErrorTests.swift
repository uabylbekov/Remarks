import Testing
import Foundation
@testable import RemarksCore

/// What Siri and Shortcuts say when the notes service refuses something.
@Suite("Messages for notes service errors")
struct NotesIntentErrorTests {
    @Test("Each notes service error has its own spoken message")
    func everyServiceErrorMapsToItsMessage() {
        #expect(NotesIntentError(NotesServiceError.noteNotFound) == .noteNotFound)
        #expect(NotesIntentError(NotesServiceError.noteInTrash) == .noteInTrash)
        #expect(NotesIntentError(NotesServiceError.noteNeedsNewerVersion) == .noteNeedsNewerVersion)
        #expect(NotesIntentError(NotesServiceError.folderNotFound) == .folderNotFound)
        #expect(NotesIntentError(NotesServiceError.attachmentFailed(.tooLarge)) == .attachmentTooLarge)
        #expect(NotesIntentError(NotesServiceError.attachmentFailed(.tooMany)) == .tooManyAttachments)
        #expect(NotesIntentError(NotesServiceError.attachmentFailed(.unreadable)) == .attachmentUnreadable)
    }

    private func english(_ error: NotesIntentError) -> String {
        var resource = error.localizedStringResource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    @Test("A note that needs a newer version says so instead of a generic failure")
    func newerVersionMessageIsSpecific() {
        #expect(english(.noteNeedsNewerVersion) == "That note needs a newer version of the app.")
    }

    @Test("An unreadable file has a message of its own")
    func unreadableFileMessageIsSpecific() {
        #expect(english(.attachmentUnreadable) == "That file couldn’t be read.")
    }

    /// Siri already says which app is answering, so its messages leave the name out (Apple's Siri guidelines).
    @Test("When the notes cannot be opened, the message says so and points to the app")
    func dataUnavailableMessageIsSpecific() {
        #expect(english(.dataUnavailable) == "Your notes couldn’t be opened. Open the app to see why.")
    }

    @Test("Spoken messages leave out the app name", arguments: [
        NotesIntentError.noteNeedsNewerVersion, .attachmentUnreadable, .dataUnavailable,
    ])
    func messagesLeaveOutTheAppName(error: NotesIntentError) {
        #expect(!english(error).contains("Remarks"))
    }
}
