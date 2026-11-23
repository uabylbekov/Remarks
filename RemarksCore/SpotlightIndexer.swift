import AppIntents
import CoreSpotlight
import Foundation

/// The "Show notes in Spotlight" switch (Spec 06, D1). On by default, like Apple Notes.
public enum SpotlightSettings {
    public static let key = "indexNotesInSpotlight"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Adds notes to the system's search (Spotlight, Siri, Apple Intelligence) and takes them out again.
/// Only titles, previews, and tags are indexed, never the full text.
public enum SpotlightIndexer {
    private static let indexName = "Remarks"

    public static func index(_ notes: [NoteInfo]) async throws {
        guard !notes.isEmpty else { return }
        try await CSSearchableIndex(name: indexName).indexAppEntities(notes.map { NoteEntity($0) })
    }

    public static func remove(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await CSSearchableIndex(name: indexName).deleteAppEntities(identifiedBy: ids, ofType: NoteEntity.self)
    }

    public static func removeAll() async throws {
        try await CSSearchableIndex(name: indexName).deleteAllSearchableItems()
    }
}
