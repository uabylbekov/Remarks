import SwiftUI
import SwiftData
import NotesCore

/// Three columns: where notes live (sidebar), the notes there (list), and the editor (Spec 04).
/// On iPhone and the iPhone Duo outer display it collapses to one column at a time.
struct ContentView: View {
    @State private var scope: NoteScope? = .all
    @State private var selectedNoteID: UUID?
    private let router = NavigationRouter.shared

    var body: some View {
        // Measured outside the navigation container, so it is the window's own inset (see `deviceBottomInset`).
        GeometryReader { proxy in
            splitView.environment(\.deviceBottomInset, proxy.safeAreaInsets.bottom)
        }
        // Only the container area. The keyboard must still push the editor up.
        .ignoresSafeArea(.container)
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(selection: $scope)
        } content: {
            NoteListView(scope: scope ?? .all, selectedNoteID: $selectedNoteID)
        } detail: {
            if let selectedNoteID {
                NoteDetailView(id: selectedNoteID)
            } else {
                ContentUnavailableView("Select a Note", systemImage: "note.text")
            }
        }
        .onChange(of: scope) { selectedNoteID = nil }
        // "Open Note" from Siri or Shortcuts. `initial: true` also catches a request made before this view existed.
        .onChange(of: router.pendingNoteID, initial: true) { _, noteID in
            guard let noteID else { return }
            if scope != .all { scope = .all }
            // Wait one turn, so the scope change above does not clear the selection we are about to make.
            Task { @MainActor in
                selectedNoteID = noteID
                router.didOpen()
            }
        }
    }
}

#Preview {
    let container = (try? NotesStore.makeContainer(inMemory: true)) ?? { fatalError("in-memory container failed") }()
    let library = Library(context: container.mainContext)
    let work = try? library.createFolder(named: "Work")
    _ = try? library.createFolder(named: "Projects", in: work)
    let a = library.createNote(body: "# Launch plan\nShip the editor and the **sidebar**.", in: work)
    try? library.addTag(named: "swift", to: a)
    a.setPinned(true)
    library.createNote(body: "# Groceries\n- [ ] milk\n- [x] eggs")
    library.createNote(body: "# Ideas\nA notes app with code blocks.")
    return ContentView().modelContainer(container).environment(SyncMonitor())
}
