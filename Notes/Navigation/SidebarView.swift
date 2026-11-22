import SwiftUI
import SwiftData
import NotesCore

/// A question with a text field, such as a new folder name.
private struct NamePrompt {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let commit: (String) throws -> Void
}

/// Where notes live: All Notes, the folder tree, tags, and Recently Deleted (Spec 04).
struct SidebarView: View {
    @Binding var selection: NoteScope?
    /// Set to true to ask for a new top-level folder. The window shows the question, so the File menu and this
    /// button share it.
    @Binding var asksNewFolder: Bool
    /// Whether the sidebar is open. A closed sidebar has no toolbar button, even when the window has room for one.
    let showsNewFolderButton: Bool
    /// Shows a note that was just created here. The window owns the selection.
    var openNote: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Folder> { $0.deletedAt == nil }, sort: \Folder.sortIndex)
    private var activeFolders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var folderToDelete: Folder?
    @State private var expandedFolders: [UUID: Bool] = [:]
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var showsSettings = false
    #endif

    private var library: Library { Library(context: context) }
    private var rootFolders: [Folder] { activeFolders.filter { $0.parent == nil } }

    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: NoteScope.all) {
                    Label("All Notes", systemImage: "note.text")
                }
                NavigationLink(value: NoteScope.unfiled) {
                    Label("Unfiled", systemImage: "tray")
                }
                .dropDestination(for: NoteReference.self) { references, _ in
                    _ = moveNotes(references, to: nil)
                }
            }

            Section("Folders") {
                FolderTree(
                    folders: rootFolders,
                    expandedFolders: $expandedFolders,
                    row: folderRow,
                    move: reorderFolders
                )
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        tagRow(tag)
                    }
                }
            }

            Section {
                NavigationLink(value: NoteScope.trash) {
                    Label("Recently Deleted", systemImage: "trash")
                }
            }
        }
        .onChange(of: selection, initial: true) { revealSelection() }
        .onChange(of: activeFolders.map { [$0.id, $0.parent?.id] }) { reconcileSelection() }
        .onChange(of: tags.map(\.id)) { reconcileSelection() }
        #if os(macOS)
        .onDeleteCommand {
            switch selection {
            case .folder(let id): folderToDelete = folder(withID: id)
            case .tag(let id): if let tag = tags.first(where: { $0.id == id }) { deleteTag(tag) }
            case .all, .unfiled, .trash, nil: break
            }
        }
        #endif
        .confirmationDialog("Delete this folder?", item: $folderToDelete, titleVisibility: .visible) { folder in
            Button("Delete", role: .destructive) { delete(folder) }
        } message: { _ in
            Text("The folder and the notes in it move to Recently Deleted.")
        }
        .navigationTitle("Notes")
        #if os(iOS)
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }
                        }
                    }
            }
        }
        #endif
        .toolbar {
            #if os(macOS)
            // Hidden rather than left out, so the system fades the button in and out instead of building it when the
            // sidebar opens, which is when its icon used to draw late.
            ToolbarItem {
                Button("New Folder", systemImage: "folder.badge.plus") { asksNewFolder = true }
            }
            .hidden(!showsNewFolderButton)
            #else
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            // As in Apple Notes: New Folder on the left of the bottom bar and a new note on the right. On the iPhone this
            // is the first screen, so a note can be started without opening a list first.
            ToolbarItem(placement: .bottomBar) {
                Button("New Folder", systemImage: "folder.badge.plus") { asksNewFolder = true }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Note", systemImage: "square.and.pencil", action: addNote)
            }
            #endif
        }
        .alert(prompt?.title ?? "", item: $prompt) { prompt in
            TextField("Name", text: $promptText)
            Button(prompt.confirmTitle) { _ = perform { try prompt.commit(promptText) } }
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unable to Complete Action", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
    }

    #if os(iOS)
    /// A new note in the folder that is selected.
    private func addNote() {
        var folder: Folder?
        if case .folder(let id) = selection {
            folder = self.folder(withID: id)
            guard folder != nil else { reconcileSelection(); return }
        }
        var noteID: UUID?
        if perform({ noteID = library.createNote(in: folder).id }), let noteID {
            openNote(noteID)
        }
    }
    #endif

    // MARK: Rows

    // Split into small functions with explicit types so the compiler can check each quickly.
    private func folderRow(_ folder: Folder) -> some View {
        let count: Int = folder.activeNoteCount
        let scope: NoteScope = .folder(folder.id)
        return NavigationLink(value: scope) {
            Label {
                if folder.name.isEmpty { Text("Untitled") } else { Text(verbatim: folder.name) }
            } icon: {
                Image(systemName: "folder")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .badge(count)
        .contextMenu { folderMenu(folder) }
        .dropDestination(for: NoteReference.self) { references, _ in
            _ = moveNotes(references, to: folder)
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        let count: Int = (tag.notes ?? []).filter { $0.deletedAt == nil }.count
        let scope: NoteScope = .tag(tag.id)
        return NavigationLink(value: scope) {
            Label { Text(verbatim: tag.name) } icon: { Image(systemName: "tag") }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .badge(count)
        .contextMenu { tagMenu(tag) }
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Subfolder", systemImage: "folder.badge.plus") { askNewSubfolder(in: folder) }
        Button("Rename", systemImage: "pencil") {
            ask("Rename Folder", initial: folder.name, confirm: "Rename") { name in
                try library.rename(folder, to: name)
            }
        }
        Menu("Move To", systemImage: "folder") {
            Button("Top Level", systemImage: "tray") {
                moveFolders([folder.id], to: nil, before: nil)
            }
            .disabled(folder.parent == nil)
            Divider()
            ForEach(activeFolders) { destination in
                if destination.id != folder.parent?.id, canMove(folder, to: destination) {
                    Button {
                        moveFolders([folder.id], to: destination, before: nil)
                    } label: {
                        Text(verbatim: destination.path)
                    }
                }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { folderToDelete = folder }
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        Button("Rename", systemImage: "pencil") {
            ask("Rename Tag", initial: tag.name, confirm: "Rename") { name in
                let result = try library.rename(tag, to: name)
                if selection == .tag(tag.id) {
                    selection = .tag(result.id)
                }
            }
        }
        Button("Delete Tag", systemImage: "trash", role: .destructive) { deleteTag(tag) }
    }

    // MARK: Changes

    private func folder(withID id: UUID) -> Folder? {
        activeFolders.first { $0.id == id && $0.deletedAt == nil }
    }

    private func delete(_ folder: Folder) {
        _ = perform { library.trash(folder) }
        reconcileSelection()
    }

    private func deleteTag(_ tag: Tag) {
        let id = tag.id
        if perform({ library.delete(tag) }), selection == .tag(id) { selection = .all }
    }

    /// Deleted notes stay in Recently Deleted; moving is only for active notes.
    private func moveNotes(_ references: [NoteReference], to folder: Folder?) -> Bool {
        guard folder?.deletedAt == nil else { return false }
        let ids = references.map(\.id)
        return perform {
            let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
                ids.contains($0.id) && $0.deletedAt == nil
            }))
            for note in notes { note.move(to: folder) }
        }
    }

    private func canMove(_ folder: Folder, to parent: Folder?) -> Bool {
        guard folder.deletedAt == nil else { return false }
        guard let parent else { return true }
        return parent.deletedAt == nil && parent.id != folder.id
            && !Library.isDescendant(parent, of: folder)
    }

    private func reorderFolders(_ siblings: [Folder], from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ siblings.indices.contains($0) }),
              (0...siblings.count).contains(destination) else { return }
        var ordered = siblings
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let moved = offsets.map { siblings[$0] }
        let movedIDs = Set(moved.map(\.id))
        guard let lastMoved = ordered.lastIndex(where: { movedIDs.contains($0.id) }) else { return }
        let following = ordered.dropFirst(lastMoved + 1).first
        moveFolders(moved.map(\.id), to: moved.first?.parent, before: following)
    }

    private func moveFolders(_ ids: [UUID], to parent: Folder?, before sibling: Folder?) {
        let folders = ids.compactMap { folder(withID: $0) }
        guard folders.count == ids.count, !folders.isEmpty,
              folders.allSatisfy({ canMove($0, to: parent) }),
              !ids.contains(where: { $0 == sibling?.id }) else { return }
        guard perform({
            for folder in folders {
                try library.move(folder, to: parent, before: sibling)
            }
        }) else { return }
        if let parent { expandedFolders[parent.id] = true }
        revealSelection()
    }

    /// Preserve the system's selection behavior while keeping deleted scopes out of navigation.
    private func reconcileSelection() {
        switch selection {
        case .folder(let id):
            if folder(withID: id) == nil { selection = .all }
        case .tag(let id):
            if !tags.contains(where: { $0.id == id }) { selection = .all }
        default:
            break
        }
        revealSelection()
    }

    private func revealSelection() {
        guard case .folder(let id) = selection else { return }
        var ancestor = folder(withID: id)?.parent
        var visited: Set<UUID> = []
        while let folder = ancestor, visited.insert(folder.id).inserted {
            expandedFolders[folder.id] = true
            ancestor = folder.parent
        }
    }

    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        do {
            try withAnimation { try action() }
            try context.save()
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Prompts

    private func ask(_ title: LocalizedStringKey, initial: String = "", confirm: LocalizedStringKey, commit: @escaping (String) throws -> Void) {
        promptText = initial
        prompt = NamePrompt(title: title, confirmTitle: confirm, commit: commit)
    }

    private func askNewSubfolder(in parent: Folder) {
        ask("New Subfolder", confirm: "Create") { name in
            let folder = try library.createFolder(named: name, in: parent)
            expandedFolders[parent.id] = true
            selection = .folder(folder.id)
        }
    }
}

/// A native disclosure tree. List's onMove preserves separate child rows;
/// reorderable currently combines expanded subtrees into a single selectable cell.
private struct FolderTree<Row: View>: View {
    let folders: [Folder]
    @Binding var expandedFolders: [UUID: Bool]
    let row: (Folder) -> Row
    let move: ([Folder], IndexSet, Int) -> Void

    var body: some View {
        ForEach(folders, id: \.sidebarScope) { folder in
            if let subfolders = folder.childNodes {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedFolders[folder.id] ?? false },
                    set: { expandedFolders[folder.id] = $0 }
                )) {
                    FolderTree(
                        folders: subfolders,
                        expandedFolders: $expandedFolders,
                        row: row,
                        move: move
                    )
                } label: {
                    row(folder)
                }
            } else {
                row(folder)
            }
        }
        .onMove { offsets, destination in
            move(folders, offsets, destination)
        }
    }
}

#Preview("Sidebar") {
    let container: ModelContainer
    do { container = try NotesStore.makeContainer(inMemory: true) } catch { fatalError("\(error)") }
    let library = Library(context: container.mainContext)
    _ = try? library.createFolder(named: "Work")
    return NavigationStack {
        SidebarView(selection: .constant(.all), asksNewFolder: .constant(false), showsNewFolderButton: true)
    }
    .modelContainer(container)
}
