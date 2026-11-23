import AppIntents
import RemarksCore

/// The phrases people can say to Siri or find in Spotlight and Shortcuts. Every phrase names the app
/// (`\(.applicationName)`), or the system ignores it. After release, add phrases but never rename or remove them.
nonisolated struct RemarksShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New note in \(.applicationName)",
                "Make a note in \(.applicationName)",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: WriteNoteIntent(),
            phrases: [
                "Write a note in \(.applicationName)",
                "Write me a note in \(.applicationName)",
                "Generate a note in \(.applicationName)",
            ],
            shortTitle: "Write Note",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AppendToNoteIntent(),
            phrases: [
                "Add to a note in \(.applicationName)",
                "Append to a note in \(.applicationName)",
            ],
            shortTitle: "Add to Note",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: UpdateNoteIntent(),
            phrases: [
                "Update a note in \(.applicationName)",
                "Pin a note in \(.applicationName)",
                "Rename a note in \(.applicationName)",
                "Move a note in \(.applicationName)",
            ],
            shortTitle: "Update Note",
            systemImageName: "pencil"
        )
        AppShortcut(
            intent: FindNotesIntent(),
            phrases: [
                "Find notes in \(.applicationName)",
                "Search notes in \(.applicationName)",
            ],
            shortTitle: "Find Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)",
                "Show a note in \(.applicationName)",
            ],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
    }
}

/// The app's side of `RemarksCorePackage`: says that the intents defined in `RemarksCore` belong to this app.
struct RemarksAppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [RemarksCorePackage.self]
    }
}
