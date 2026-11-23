import SwiftUI
import SwiftData
import AppIntents
import NotesCore

@main struct MyApp: App {
    /// One container for the whole app. Built once, with CloudKit sync on (Spec 01 and Spec 02).
    private let store: Result<ModelContainer, Error>
    @State private var monitor = SyncMonitor()

    init() {
        // Before anything is styled: makes the code fonts that ship inside the app usable by name.
        BundledFonts.register()

        #if DEBUG
        // Release checklist step (specs/02-sync.md): creates every CloudKit field in the development
        // environment. It must run before the container below exists.
        if CommandLine.arguments.contains("-InitializeCloudKitSchema") {
            do {
                try CloudKitSchema.initialize()
                print("CloudKit schema initialized.")
            } catch {
                print("CloudKit schema initialization failed: \(error)")
            }
        }
        #endif
        store = Result { try NotesStore.makeContainer() }

        // Siri and Shortcuts can start the app with no window and run an intent straight away, so everything an
        // intent needs is registered here, not in a view (an unregistered dependency crashes).
        if case .success(let container) = store {
            AppDependencyManager.shared.add(dependency: NotesService(modelContainer: container))
        }
        let router = NavigationRouter.shared
        AppDependencyManager.shared.add(dependency: router)
    }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                ContentView()
                    .modifier(LibraryMaintenance())
                    .modifier(SpotlightSync())
                    .modelContainer(container)
                    .environment(monitor)
                    .task { await RichPreviewRenderer.shared.prepare() }
            case .failure(let error):
                ContentUnavailableView(
                    "Remarks could not open its data",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        #if os(macOS)
        .commands {
            FileCommands()
            FormatCommands()
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

/// Keeps the library tidy and starts watching sync (Spec 02, Y3 and Y4):
/// - after every finished iCloud import, merges duplicate tags and notes that two devices created at once;
/// - after the first import (or 60 seconds after launch) and then once a day, also permanently deletes notes that have
///   been in Recently Deleted for 30 days.
private struct LibraryMaintenance: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(SyncMonitor.self) private var monitor

    func body(content: Content) -> some View {
        content.task {
            // The first purge waits for an import, so a note restored on another device is not deleted from stale
            // local state. Without iCloud no import comes, so it also runs 60 seconds after launch. Later imports
            // only merge duplicates, because a purge reads every note and snapshot.
            var didPurge = false
            let purgeOnce: @MainActor @Sendable () -> Void = {
                tidy(purging: !didPurge)
                didPurge = true
            }
            monitor.onImportFinished = purgeOnce
            monitor.start()
            tidy(purging: false)
            do {
                try await Task.sleep(for: .seconds(60))
                try Task.checkCancellation()
                purgeOnce()
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(24 * 60 * 60))
                    try Task.checkCancellation()
                    tidy(purging: true)
                }
            } catch {
                // Closing a window must not trigger an immediate purge by skipping its delay.
                return
            }
        }
    }

    private func tidy(purging: Bool) {
        let library = Library(context: context)
        let report = purging ? try? library.runMaintenance() : try? library.dedupe()
        if report?.changedAnything == true { try? context.save() }
    }
}

/// Keeps Spotlight in step with the library while the app runs (Spec 06). The system can also ask for a reindex
/// through `NoteEntityQuery`. Turning the setting off removes everything from the index.
private struct SpotlightSync: ViewModifier {
    @Environment(\.modelContext) private var context
    @AppStorage(SpotlightSettings.key) private var isEnabled = true

    func body(content: Content) -> some View {
        content.task(id: isEnabled) {
            // Start from an empty index, so notes trashed or deleted while the app was closed do not linger.
            try? await SpotlightIndexer.removeAll()
            guard isEnabled else { return }
            let service = NotesService(modelContainer: context.container)
            let indexed = IndexedNotes()
            await sync(service, indexed)
            var pending: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                // Saves come in bursts while typing, so every save restarts the wait.
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await sync(service, indexed)
                }
            }
            pending?.cancel()
        }
    }

    /// What Spotlight has now. Whole values, not dates, so a new tag or folder name is noticed too.
    @MainActor private final class IndexedNotes {
        var byID: [UUID: NoteInfo] = [:]
    }

    /// Indexes what is new or changed, and removes what was trashed or deleted.
    private func sync(_ service: NotesService, _ indexed: IndexedNotes) async {
        guard let live = try? await service.liveNotes() else { return }
        let changed = live.filter { indexed.byID[$0.id] != $0 }
        let liveIDs = Set(live.map(\.id))
        let gone = indexed.byID.keys.filter { !liveIDs.contains($0) }
        guard (try? await SpotlightIndexer.index(changed)) != nil, (try? await SpotlightIndexer.remove(gone)) != nil else { return }
        for note in changed { indexed.byID[note.id] = note }
        for id in gone { indexed.byID[id] = nil }
    }
}

#if os(macOS)
/// New Note and New Folder in the File menu, active even while the sidebar or note list is hidden.
private struct FileCommands: Commands {
    @FocusedValue(\.newNote) private var newNote
    @FocusedValue(\.newFolder) private var newFolder

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { newNote?.run() }
                .keyboardShortcut("n")
                .disabled(newNote?.isDisabled ?? true)
            Button("New Folder") { newFolder?.wrappedValue = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newFolder == nil)
        }
    }
}

/// The Format menu. The items act on the editor that has focus, and are dimmed when there is none or the note is read-only.
private struct FormatCommands: Commands {
    @FocusedValue(\.editorCommands) private var editor

    private var isDisabled: Bool {
        editor == nil || editor?.isEditingTableCell == true || editor?.isReadOnly == true
    }

    var body: some Commands {
        CommandMenu("Format") {
            Group {
                Button("Bold") { editor?.perform(.bold) }.keyboardShortcut("b")
                Button("Italic") { editor?.perform(.italic) }.keyboardShortcut("i")
                Button("Strikethrough") { editor?.perform(.strikethrough) }
                Button("Inline Code") { editor?.perform(.inlineCode) }.keyboardShortcut("e")
                Button("Link") { editor?.perform(.link) }.keyboardShortcut("k")
                Divider()
                Button("Heading") { editor?.perform(.heading) }
                Button("Bulleted List") { editor?.perform(.bulletList) }
                Button("Numbered List") { editor?.perform(.numberedList) }
                Button("Checklist") { editor?.perform(.checklist) }
                Button("Table") { editor?.perform(.table) }
                Button("Quote") { editor?.perform(.quote) }
                Button("Equation") { editor?.perform(.math) }
                Button("Diagram") { editor?.perform(.diagram) }
                Button("Code Block") { editor?.perform(.codeBlock) }.keyboardShortcut("c", modifiers: [.command, .option])
            }
            .disabled(isDisabled)
        }
    }
}
#endif
