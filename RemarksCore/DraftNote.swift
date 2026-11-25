import Foundation

/// A note the user has just created and not typed into yet. While it is the open note, leaving it empty deletes it
/// outright, so it never reaches Recently Deleted.
public struct DraftNote: Equatable, Sendable {
    public let id: UUID
    /// The place the window shows the draft in. A draft cannot be created in Recently Deleted, so this is never `.trash`.
    public let scope: NoteScope

    public init(id: UUID, scope: NoteScope) {
        self.id = id
        self.scope = scope
    }

    /// Moving the window to `newScope` leaves the draft behind unless that is the place the draft lives in. Creating a
    /// draft can itself move the window (New Note from Recently Deleted opens All Notes), and that move must keep it.
    public func isLeft(whenScopeBecomes newScope: NoteScope?) -> Bool {
        newScope != scope
    }
}
