import SwiftUI
import SwiftData
import NotesCore

/// Three columns: where notes live (sidebar), the notes there (list), and the editor (Spec 04).
/// On iPhone and the iPhone Duo outer display it collapses to one column at a time.
struct ContentView: View {
    @State private var scope: NoteScope? = .all
    @State private var selectedNoteID: UUID?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.modelContext) private var context
    @State private var asksNewFolder = false
    @State private var newFolderName = ""
    private let router = NavigationRouter.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(
                selection: $scope,
                asksNewFolder: $asksNewFolder,
                showsNewFolderButton: columnVisibility == .all
            ) { id in
                scope = .all
                selectedNoteID = id
                preferredColumn = .detail
            }
        } content: {
            NoteListView(scope: scope ?? .all, selectedNoteID: $selectedNoteID)
        } detail: {
            Group {
                if let selectedNoteID {
                    NoteDetailView(id: selectedNoteID)
                } else {
                    ContentUnavailableView("Select a Note", systemImage: "note.text")
                        #if os(macOS)
                        // The editor's toolbar stays, switched off, so the window does not change shape between notes.
                        .toolbar {
                            FormattingToolbarContent(commands: EditorCommands(), isEnabled: false)
                            ToolbarItem(placement: .primaryAction) {
                                Button("Note", systemImage: "ellipsis.circle") {}.disabled(true)
                            }
                        }
                        #endif
                }
            }
            // Without a minimum, the other columns take their widest size and squeeze the editor.
            .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        }
        #if os(macOS)
        .keepsSidebarThroughFullScreen($columnVisibility)
        #endif
        // The File menu's New Folder works even while the sidebar, and its toolbar button, is hidden.
        .focusedSceneValue(\.newFolder, $asksNewFolder)
        .onChange(of: asksNewFolder) { if asksNewFolder { newFolderName = "" } }
        .alert("New Folder", isPresented: $asksNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                do {
                    let folder = try Library(context: context).createFolder(named: newFolderName)
                    try context.save()
                    scope = .folder(folder.id)
                    preferredColumn = .content
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unable to Create Folder", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
        // "Open Note" from Siri or Shortcuts. `initial: true` also catches a request made before this view existed.
        // The list keeps a selection only if that note is in the list, so changing the scope here is enough.
        .onChange(of: router.pendingNoteID, initial: true) { _, noteID in
            guard let noteID else { return }
            scope = .all
            selectedNoteID = noteID
            preferredColumn = .detail
            router.didOpen()
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

#if os(macOS)
import AppKit

private extension View {
    /// Entering or leaving full screen resizes the window through sizes of its own, and the system opens or closes the
    /// sidebar to suit them. Whatever the person chose stays: the visibility is noted before the change and put back after.
    func keepsSidebarThroughFullScreen(_ visibility: Binding<NavigationSplitViewVisibility>) -> some View {
        modifier(KeepsSidebarThroughFullScreen(visibility: visibility))
    }
}

private struct KeepsSidebarThroughFullScreen: ViewModifier {
    @Binding var visibility: NavigationSplitViewVisibility
    @State private var chosen: NavigationSplitViewVisibility?

    func body(content: Content) -> some View {
        content.task {
            await withTaskGroup(of: Void.self) { group in
                for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                    group.addTask { @MainActor in
                        for await _ in NotificationCenter.default.notifications(named: name) { chosen = visibility }
                    }
                }
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    group.addTask { @MainActor in
                        for await _ in NotificationCenter.default.notifications(named: name) {
                            if let chosen { visibility = chosen }
                            chosen = nil
                        }
                    }
                }
            }
        }
    }
}
#endif
