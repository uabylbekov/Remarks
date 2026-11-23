import SwiftUI
import SwiftData
import NotesCore

/// Three columns: where notes live (sidebar), the notes there (list), and the editor (Spec 04).
/// On iPhone and the iPhone Duo outer display it collapses to one column at a time.
struct ContentView: View {
    @State private var scope: NoteScope? = .all
    @State private var selectedNoteID: UUID?
    /// Where this window was looking and which note it had open, kept per window so a relaunch comes back to them. These
    /// only remember: `scope` and `selectedNoteID` are the live values. A list selection reads its binding straight after
    /// setting it, and `@SceneStorage` does not give the new value back at once, so the selection would snap back. A note
    /// or folder that has since gone is dropped by the list and the sidebar when they load.
    @SceneStorage("window.scope") private var storedScope = NoteScope.all.storageKey
    @SceneStorage("window.note") private var storedNoteID = ""
    @State private var didRestorePlace = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.modelContext) private var context
    @State private var asksNewFolder = false
    @State private var newFolderName = ""
    #if os(macOS)
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil && $0.title == "" })
    private var untitledNotes: [Note]
    #endif
    private let router = NavigationRouter.shared

    /// Puts the window back where it was, once, unless a request to open a note got there first.
    private func restorePlace() {
        guard !didRestorePlace else { return }
        didRestorePlace = true
        if let restored = NoteScope(storageKey: storedScope) { scope = restored }
        selectedNoteID = UUID(uuidString: storedNoteID)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(
                selection: $scope,
                asksNewFolder: $asksNewFolder
            ) { id in
                switch scope {
                case .folder, .unfiled, .all, .tag:
                    break
                case .trash, nil:
                    scope = .all
                }
                selectedNoteID = id
                preferredColumn = .detail
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            #endif
        } content: {
            NoteListView(scope: scope ?? .all, selectedNoteID: $selectedNoteID)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                #endif
        } detail: {
            Group {
                if let selectedNoteID {
                    NoteDetailView(id: selectedNoteID) {
                        self.selectedNoteID = nil
                    }
                } else {
                    Color.clear
                        #if os(macOS)
                        // The editor's toolbar stays, switched off, so the window does not change shape between notes.
                        .toolbar {
                            FormattingToolbarContent(commands: nil, isEnabled: false)
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
        .focusedSceneValue(\.newNote, NewNoteCommand(isDisabled: hasEmptyNoteInNewNoteTarget, run: createNoteFromMenu))
        #endif
        // The File menu's New Folder works even while the sidebar, and its toolbar button, is hidden.
        .focusedSceneValue(\.newFolder, $asksNewFolder)
        .onChange(of: asksNewFolder) { if asksNewFolder { newFolderName = "" } }
        .alert("New Folder", isPresented: $asksNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                do {
                    let folder = try withAnimation {
                        try Library(context: context).createFolder(named: newFolderName)
                    }
                    try context.save()
                    scope = .folder(folder.id)
                    preferredColumn = .content
                } catch {
                    context.rollback()
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
            didRestorePlace = true
            scope = .all
            selectedNoteID = noteID
            preferredColumn = .detail
            router.didOpen()
        }
        .task { restorePlace() }
        .onChange(of: scope) { storedScope = scope?.storageKey ?? "" }
        .onChange(of: selectedNoteID) { storedNoteID = selectedNoteID?.uuidString ?? "" }
    }

    #if os(macOS)
    private var newNoteTargetScope: NoteScope {
        switch scope {
        case .folder(let id): .folder(id)
        case .tag(let id): .tag(id)
        case .unfiled: .unfiled
        case .all, .trash, nil: .all
        }
    }

    private var hasEmptyNoteInNewNoteTarget: Bool {
        let target = newNoteTargetScope
        return untitledNotes.contains { !$0.isDeleted && $0.modelContext != nil && target.contains($0) && $0.isEmpty }
    }

    private func createNoteFromMenu() {
        guard !hasEmptyNoteInNewNoteTarget else { return }
        let target = newNoteTargetScope
        do {
            let note = try Library(context: context).createNote(in: target)
            try context.save()
            scope = target
            selectedNoteID = note.id
            preferredColumn = .detail
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }
    #endif
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

#if os(macOS)
/// Action behind macOS `File > New Note` (`⌘N`), active even when the list column is collapsed.
struct NewNoteCommand {
    let isDisabled: Bool
    let run: () -> Void
}
#endif

extension FocusedValues {
    /// Set to true to ask for a new top-level folder. Provided by the main window, used by the File menu.
    @Entry var newFolder: Binding<Bool>?
    #if os(macOS)
    /// Runs `File > New Note` (`⌘N`) for the focused window.
    @Entry var newNote: NewNoteCommand?
    #endif
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
