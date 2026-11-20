import Foundation

/// What the open editor should do when a note's stored text may have changed under it (Spec 06, "The editor
/// conflict"). The change can come from iCloud sync, from Siri or Shortcuts appending text, or from a restore.
///
/// The editor remembers `baseBody`: the text it last loaded or saved. Comparing three texts is enough to tell
/// "the user typed", "something else changed the note", and "both happened".
public enum EditorSync {
    public enum Decision: Equatable, Sendable {
        /// Nothing to do: the texts agree, or only the user has changed anything.
        case keepEditorText
        /// The user has typed nothing since the last load or save, so show the new text.
        case adoptIncoming
        /// Both sides changed. The user's text stays, and the incoming text is saved as a version so nothing is lost.
        case keepTypedTextAndSaveIncoming
    }

    /// - Parameters:
    ///   - editorText: what is in the text view now.
    ///   - baseBody: the text the editor last loaded or saved.
    ///   - incomingBody: the note's stored text now.
    public static func decide(editorText: String, baseBody: String, incomingBody: String) -> Decision {
        // Already the same, or the stored text is still what the editor started from (the user may be typing).
        if incomingBody == editorText || incomingBody == baseBody { return .keepEditorText }
        // The stored text changed. If the user has not typed, take it.
        if editorText == baseBody { return .adoptIncoming }
        return .keepTypedTextAndSaveIncoming
    }

    /// Whether saving `editorText` would silently replace stored text the editor has never seen.
    /// If so, that text must be kept as a version first.
    public static func unseenTextBeingOverwritten(editorText: String, baseBody: String, storedBody: String) -> Bool {
        storedBody != baseBody && storedBody != editorText && !storedBody.isEmpty
    }
}
