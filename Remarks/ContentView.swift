import SwiftUI
import SwiftData
import RemarksCore

/// Three columns: where notes live (sidebar), the notes there (list), and the editor (Spec 04).
/// On iPhone and the iPhone Duo outer display it collapses to one column at a time.
struct ContentView: View {
    /// Nothing is selected at first. On a one-column layout a selected place opens its notes at once, so the app would not
    /// start on the folder list. `restorePlace()` selects one where the columns show side by side.
    @State private var scope: NoteScope?
    @State private var selectedNoteID: UUID?
    @State private var draft: DraftNote?
    @State private var didRestorePlace = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var asksNewFolder = false
    @State private var newFolderName = ""
    #if os(macOS)
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil && $0.title == "" })
    private var untitledNotes: [Note]
    #endif
    private let router = NavigationRouter.shared

    /// Puts the window back where it was, once, unless a request to open a note got there first.
    /// When the layout is one column at a time, it starts on the folder list instead: restoring a folder or note would
    /// open straight into it.
    private func restorePlace(storedScope: NoteScope, storedNoteID: UUID?) {
        guard !didRestorePlace else { return }
        didRestorePlace = true
        guard horizontalSizeClass != .compact else {
            preferredColumn = .sidebar
            return
        }
        scope = storedScope
        selectedNoteID = storedNoteID
    }

    private func draftNote(withID id: UUID) -> Note? {
        let matches = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))) ?? []
        guard let note = matches.first, !note.isDeleted, note.modelContext != nil, note.deletedAt == nil else {
            return nil
        }
        return note
    }

    /// Dismisses the active draft permanently (never sending it to Recently Deleted) if it is still empty,
    /// or graduates it to a committed note once it holds content. Returns true when the draft was deleted.
    @discardableResult
    private func settleDraftNote(ifMatching outgoingID: UUID?) -> Bool {
        guard let draftID = draft?.id, outgoingID == draftID else { return false }
        draft = nil
        guard let note = draftNote(withID: draftID), note.isEmpty else { return false }
        withAnimation {
            context.delete(note)
            try? context.save()
        }
        return true
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(
                selection: $scope,
                asksNewFolder: $asksNewFolder,
                openNote: { id in
                    settleDraftNote(ifMatching: draft?.id)
                    let place: NoteScope
                    switch scope {
                    case .folder, .unfiled, .all, .tag:
                        place = scope ?? .all
                    case .trash, nil:
                        place = .all
                    }
                    scope = place
                    draft = DraftNote(id: id, scope: place)
                    selectedNoteID = id
                    preferredColumn = .detail
                },
                onWillTrashFolder: { folder in
                    if let draftID = draft?.id,
                       draftNote(withID: draftID).flatMap(\.folder).map({ $0.id == folder.id || Library.isDescendant($0, of: folder) }) == true,
                       settleDraftNote(ifMatching: draftID),
                       selectedNoteID == draftID {
                        selectedNoteID = nil
                    }
                }
            )
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            #endif
        } content: {
            #if os(iOS)
            Group {
                if let scope {
                    NoteListView(
                        scope: scope,
                        selectedNoteID: $selectedNoteID,
                        onWillCreateNote: { settleDraftNote(ifMatching: draft?.id) },
                        onCreatedNote: { draft = DraftNote(id: $0, scope: scope ?? .all) }
                    )
                    .id(scope)
                } else {
                    Color.clear
                }
            }
            #else
            NoteListView(
                scope: scope ?? .all,
                selectedNoteID: $selectedNoteID,
                onWillCreateNote: { settleDraftNote(ifMatching: draft?.id) },
                onCreatedNote: { draft = DraftNote(id: $0, scope: scope ?? .all) }
            )
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
            settleDraftNote(ifMatching: draft?.id)
            didRestorePlace = true
            scope = .all
            selectedNoteID = noteID
            preferredColumn = .detail
            router.didOpen()
        }
        .background {
            ScenePlaceStorage(scope: scope, selectedNoteID: selectedNoteID, onRestore: restorePlace)
        }
        // A window that starts one column wide has no place selected. When it widens (Split View, Stage Manager, rotation)
        // the sidebar would have nothing selected next to the list, so it gets the default place.
        .onChange(of: horizontalSizeClass) {
            if horizontalSizeClass != .compact, scope == nil { scope = .all }
        }
        .onChange(of: scope) { oldScope, newScope in
            guard oldScope != nil, oldScope != newScope else { return }
            if let draft, draft.isLeft(whenScopeBecomes: newScope), settleDraftNote(ifMatching: draft.id),
               selectedNoteID == draft.id {
                selectedNoteID = nil
            }
        }
        .onChange(of: selectedNoteID) { oldID, newID in
            guard oldID != newID else { return }
            settleDraftNote(ifMatching: oldID)
        }
        .onChange(of: preferredColumn) { oldColumn, newColumn in
            if horizontalSizeClass == .compact, oldColumn == .detail, newColumn != .detail,
               let draftID = draft?.id, settleDraftNote(ifMatching: draftID), selectedNoteID == draftID {
                selectedNoteID = nil
            }
        }
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
            settleDraftNote(ifMatching: draft?.id)
            let note = try withAnimation {
                try Library(context: context).createNote(in: target)
            }
            try context.save()
            draft = DraftNote(id: note.id, scope: target)
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

/// Persists the active window's folder and note selection in `@SceneStorage` without invalidating `ContentView` on
/// every selection change during navigation transitions.
private struct ScenePlaceStorage: View {
    @SceneStorage("window.scope") private var storedScope = NoteScope.all.storageKey
    @SceneStorage("window.note") private var storedNoteID = ""
    let scope: NoteScope?
    let selectedNoteID: UUID?
    let onRestore: (NoteScope, UUID?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                onRestore(NoteScope(storageKey: storedScope) ?? .all, UUID(uuidString: storedNoteID))
            }
            .onChange(of: scope) { _, newScope in
                storedScope = newScope?.storageKey ?? ""
            }
            .onChange(of: selectedNoteID) { _, newNoteID in
                storedNoteID = newNoteID?.uuidString ?? ""
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
