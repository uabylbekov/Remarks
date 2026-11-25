import Foundation

/// Which note formats this version of the app can read (Spec 01). A later version that writes a format older apps cannot
/// render raises the note's `minimumReaderVersion`, and this app then leaves that note alone instead of corrupting it.
public enum NoteFormat {
    /// The highest `minimumReaderVersion` this version of the app understands. Raise it only together with the code that
    /// reads the new format.
    public static let supportedReaderVersion = 1
}

extension Note {
    /// Whether this version of the app understands the note well enough to show, search, and change its text.
    public var isReadable: Bool {
        minimumReaderVersion <= NoteFormat.supportedReaderVersion
    }
}
