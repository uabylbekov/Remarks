import SwiftUI
import SwiftData
import NotesCore

/// Three columns: where notes live (sidebar), the notes there (list), and the editor (Spec 04).
/// On iPhone and the iPhone Duo outer display it collapses to one column at a time.
struct ContentView: View {
    @State private var scope: NoteScope? = .all
    @State private var selectedNoteID: UUID?
    @Environment(\.modelContext) private var context
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var asksNewFolder = false
    @State private var newFolderName = ""
    private let router = NavigationRouter.shared

    var body: some View {
        splitView
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $scope, isSidebarVisible: columnVisibility != .doubleColumn && columnVisibility != .detailOnly)
        } content: {
            NoteListView(scope: scope ?? .all, selectedNoteID: $selectedNoteID)
        } detail: {
            Group {
                if let selectedNoteID {
                    NoteDetailView(id: selectedNoteID)
                } else {
                    ContentUnavailableView("Select a Note", systemImage: "note.text")
                }
            }
            // Without a minimum, the other columns take their widest size and squeeze the editor.
            .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        }
        // The File menu's New Folder works even while the sidebar, and its toolbar button, is hidden.
        .focusedSceneValue(\.newFolder, $asksNewFolder)
        .onChange(of: asksNewFolder) { if asksNewFolder { newFolderName = "" } }
        .alert("New Folder", isPresented: $asksNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                if let folder = try? Library(context: context).createFolder(named: newFolderName) {
                    scope = .folder(folder.id)
                }
            }
            Button("Cancel", role: .cancel) {}
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

extension FocusedValues {
    /// Set to true to ask for a new top-level folder. Provided by the main window, used by the File menu.
    @Entry var newFolder: Binding<Bool>?
}
