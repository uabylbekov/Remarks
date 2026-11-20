import SwiftUI
import SwiftData
import AppIntents
import NotesCore

@main struct MyApp: App {
    /// One container for the whole app. Built once, with CloudKit sync on (Spec 01 and Spec 02).
    private let store: Result<ModelContainer, Error>
    /// Local-only note versions (Spec 02). Nil if it cannot open, and the app then works without version history.
    private let history: HistoryRecorder?
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
        history = (try? HistoryStore.makeContainer()).map { HistoryRecorder(container: $0) }

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
                    .modelContainer(container)
                    .environment(monitor)
                    .environment(\.history, history)
            case .failure(let error):
                ContentUnavailableView(
                    "Notes could not open its data",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        #if os(macOS)
        Settings {
            AppearanceSettingsView()
        }
        #endif
    }
}

/// Keeps the library tidy and starts watching sync (Spec 02, Y3 and Y4):
/// - after every finished iCloud import, merges duplicate tags and notes that two devices created at once;
/// - at launch and once a day, also permanently deletes notes that have been in Recently Deleted for 30 days.
private struct LibraryMaintenance: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(SyncMonitor.self) private var monitor

    func body(content: Content) -> some View {
        content.task {
            monitor.onImportFinished = { tidy(purging: false) }
            monitor.start()
            while !Task.isCancelled {
                tidy(purging: true)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    private func tidy(purging: Bool) {
        let library = Library(context: context)
        let report = purging ? try? library.runMaintenance() : try? library.dedupe()
        if report?.changedAnything == true { try? context.save() }
    }
}
