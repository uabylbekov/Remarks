import AppIntents
import NotesCore

/// The phrases people can say to Siri or find in Spotlight and Shortcuts. Every phrase names the app
/// (`\(.applicationName)`), or the system ignores it. After release, add phrases but never rename or remove them.
nonisolated struct NotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AppendToNoteIntent(),
            phrases: ["Add to a note in \(.applicationName)"],
            shortTitle: "Add to Note",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: FindNotesIntent(),
            phrases: ["Find notes in \(.applicationName)"],
            shortTitle: "Find Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: ["Open a note in \(.applicationName)"],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
    }
}

/// The app's side of `NotesCorePackage`: says that the intents defined in `NotesCore` belong to this app.
struct NotesAppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [NotesCorePackage.self]
    }
}
