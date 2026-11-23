import Foundation
import Observation

/// Lets an intent (Open Note) ask the running UI to show a note, even when the app was launched cold by Siri
/// and no view exists yet. `ContentView` watches `pendingNoteID` and clears it once it has acted on it.
@MainActor
@Observable
public final class NavigationRouter {
    public static let shared = NavigationRouter()

    public private(set) var pendingNoteID: UUID?

    public func open(_ noteID: UUID) {
        pendingNoteID = noteID
    }

    public func didOpen() {
        pendingNoteID = nil
    }
}
