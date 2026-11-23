import SwiftUI
import SwiftData
import RemarksCore

/// A question with a text field, such as a new folder name.
private struct NamePrompt {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let commit: (String) throws -> Void
}

private struct FolderHierarchyKey: Equatable {
    let id: UUID
    let parentID: UUID?
}

private struct ScopeCounts: Equatable {
    var all = 0
    var unfiled = 0
}

private struct FolderDeletionTarget: Identifiable {
    let id: UUID
    let name: String
    let hasSubfolders: Bool
}

private struct TagDeletionTarget: Identifiable {
    let id: UUID
    let name: String
}

/// Where notes live: All Notes, the folder tree, tags, and Recently Deleted (Spec 04).
struct SidebarView: View {
    @Binding var selection: NoteScope?
    /// Set to true to ask for a new top-level folder. The window shows the question, so the File menu and this
    /// button share it.
    @Binding var asksNewFolder: Bool
    /// Shows a note that was just created here. The window owns the selection.
    var openNote: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Folder> { $0.deletedAt == nil }, sort: \Folder.sortIndex)
    private var activeFolders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(filter: #Predicate<Note> { $0.deletedAt != nil })
    private var deletedNotes: [Note]
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var folderToDelete: FolderDeletionTarget?
    @State private var tagToDelete: TagDeletionTarget?
    @State private var counts = ScopeCounts()
    @State private var errorMessage: String?
    @SceneStorage("sidebar.showsFolders") private var showsFoldersSection = true
    @SceneStorage("sidebar.showsTags") private var showsTagsSection = true
    @SceneStorage("sidebar.expandedFolders") private var expandedFolderIDsStorage = ""
    #if os(iOS)
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil && $0.title == "" })
    private var untitledNotes: [Note]
    @State private var showsSettings = false
    #endif

    private var library: Library { Library(context: context) }

    private var liveFolders: [Folder] {
        activeFolders.filter { !$0.isDeleted && $0.modelContext != nil && $0.deletedAt == nil }
    }

    private var liveTags: [Tag] {
        tags.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var deletedNoteCount: Int {
        deletedNotes.filter { !$0.isDeleted && $0.modelContext != nil }.count
    }

    private var rootFolders: [Folder] {
        liveFolders.filter(\.isTopLevel)
    }

    private var folderHierarchy: [FolderHierarchyKey] {
        liveFolders.map { FolderHierarchyKey(id: $0.id, parentID: $0.parent?.id) }
    }

    private var expandedFolderIDs: Set<UUID> {
        Set(expandedFolderIDsStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    var body: some View {
        List(selection: $selection) {
            // The list selects by `tag`, so every selectable row is a plain label that carries its place as one. The window
            // columns follow the selection; there is nothing for a `NavigationLink` to push. (A `NavigationLink(value:)`
            // that is followed by `.badge` loses its implicit selection value, so choosing it selected nothing.)
            Section {
                Label("All Notes", systemImage: "square.stack")
                    .badge(counts.all)
                    .tag(NoteScope.all)

                Label("Unfiled", systemImage: "tray")
                    .badge(counts.unfiled)
                    .dropDestination(for: NoteReference.self) { references, _ in
                        _ = moveNotes(references, to: nil)
                    }
                    .tag(NoteScope.unfiled)
            }

            if !rootFolders.isEmpty {
                Section("Folders", isExpanded: $showsFoldersSection) {
                    FolderTree(
                        folders: rootFolders,
                        expandedIDs: expandedFolderIDs,
                        onToggleExpanded: setFolderExpanded,
                        row: folderRow,
                        move: reorderFolders
                    )
                }
            }

            if !liveTags.isEmpty {
                Section("Tags", isExpanded: $showsTagsSection) {
                    ForEach(liveTags, id: \.persistentModelID) { tag in
                        TagRow(
                            tag: tag,
                            onRename: { askRename(tag) },
                            onDelete: { confirmDelete(tag) },
                            onDropNotes: { references in
                                _ = tagNotes(references, with: tag)
                            }
                        )
                    }
                }
            }

            if deletedNoteCount > 0 {
                Section {
                    Label("Recently Deleted", systemImage: "trash")
                        .badge(deletedNoteCount)
                        .dropDestination(for: NoteReference.self) { references, _ in
                            _ = trashNotes(references)
                        }
                        .tag(NoteScope.trash)
                }
            }
        }
        .task {
            refreshCounts()
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                refreshCounts()
            }
        }
        .onChange(of: deletedNoteCount, initial: true) {
            if deletedNoteCount == 0, selection == .trash { selection = .all }
        }
        .onChange(of: selection, initial: true) { revealSelection() }
        .onChange(of: folderHierarchy) { reconcileSelection() }
        .onChange(of: liveTags.map(\.id)) { reconcileSelection() }
        #if os(macOS)
        .onDeleteCommand {
            switch selection {
            case .folder(let id):
                if let folder = folder(withID: id) { confirmDelete(folder) }
            case .tag(let id):
                if let tag = liveTags.first(where: { $0.id == id }) { confirmDelete(tag) }
            case .all, .unfiled, .trash, nil:
                break
            }
        }
        #endif
        .confirmationDialog(
            folderToDelete.map { Text("Delete “\($0.name)”?") } ?? Text("Delete this folder?"),
            item: $folderToDelete,
            titleVisibility: .visible
        ) { target in
            Button("Delete", role: .destructive) { deleteFolder(withID: target.id) }
        } message: { target in
            if target.hasSubfolders {
                Text("The folder, its subfolders, and the notes inside move to Recently Deleted.")
            } else {
                Text("The folder and the notes in it move to Recently Deleted.")
            }
        }
        .confirmationDialog(
            tagToDelete.map { Text("Delete “\($0.name)”?") } ?? Text("Delete this tag?"),
            item: $tagToDelete,
            titleVisibility: .visible
        ) { target in
            Button("Delete", role: .destructive) { deleteTag(withID: target.id) }
        } message: { _ in
            Text("This tag will be removed from all notes. Your notes won’t be deleted.")
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
        #if os(macOS)
        .safeAreaBar(edge: .bottom, alignment: .leading) {
            Button {
                asksNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("New Folder")
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        #else
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(liveFolders.isEmpty)
            }
            // As in Apple Notes: New Folder on the left of the bottom bar and a new note on the right. On the iPhone this
            // is the first screen, so a note can be started without opening a list first.
            ToolbarItem(placement: .bottomBar) {
                Button("New Folder", systemImage: "folder.badge.plus") { asksNewFolder = true }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Note", systemImage: "square.and.pencil", action: addNote)
                    .disabled(hasEmptyNote)
            }
        }
        #endif
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
    /// Where New Note puts a note: in the selected folder or tag, and otherwise among all notes. The same on every platform.
    private var newNoteTarget: NoteScope {
        switch selection {
        case .trash, nil: .all
        case let scope?: scope
        }
    }

    /// Whether the destination where New Note would create a note already has an empty note.
    private var hasEmptyNote: Bool {
        let target = newNoteTarget
        return untitledNotes.contains { !$0.isDeleted && $0.modelContext != nil && target.contains($0) && $0.isEmpty }
    }

    /// A new note in the folder or tag that is selected.
    private func addNote() {
        guard !hasEmptyNote else { return }
        var noteID: UUID?
        if perform({ noteID = try library.createNote(in: newNoteTarget).id }), let noteID {
            openNote(noteID)
        }
    }
    #endif

    // MARK: Rows

    private func folderRow(_ folder: Folder) -> some View {
        FolderRow(
            folder: folder,
            // Worked out when the menu opens, not for every row on every redraw.
            movableDestinations: { movableDestinations(for: folder) },
            onNewSubfolder: { askNewSubfolder(in: folder) },
            onRename: { askRename(folder) },
            onMoveToParent: { parent in
                moveFolders([folder.id], to: parent, before: nil)
            },
            onDelete: { confirmDelete(folder) },
            onDropNotes: { references in
                _ = moveNotes(references, to: folder)
            }
        )
    }

    private func movableDestinations(for folder: Folder) -> [Folder] {
        liveFolders
            .filter { $0.id != folder.parent?.id && canMove(folder, to: $0) }
            // `path` walks up the tree, so it is read once per folder, not on every comparison.
            .map { (folder: $0, path: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map(\.folder)
    }

    // MARK: Counts

    private func refreshCounts() {
        let all = (try? context.fetchCount(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))) ?? counts.all
        let unfiled = (try? context.fetchCount(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil && $0.folder == nil }))) ?? counts.unfiled
        let updated = ScopeCounts(all: all, unfiled: unfiled)
        if updated != counts {
            counts = updated
        }
    }

    // MARK: Expanded State

    private func setFolderExpanded(_ id: UUID, isExpanded: Bool) {
        var ids = expandedFolderIDs
        if isExpanded {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        storeExpandedFolderIDs(ids)
    }

    private func expandFolderIDs(_ additions: [UUID]) {
        guard !additions.isEmpty else { return }
        var ids = expandedFolderIDs
        let previousCount = ids.count
        for id in additions { ids.insert(id) }
        if ids.count != previousCount {
            storeExpandedFolderIDs(ids)
        }
    }

    private func storeExpandedFolderIDs(_ ids: Set<UUID>) {
        let encoded = ids.map(\.uuidString).sorted().joined(separator: ",")
        if encoded != expandedFolderIDsStorage {
            expandedFolderIDsStorage = encoded
        }
    }

    // MARK: Changes

    private func folder(withID id: UUID) -> Folder? {
        liveFolders.first { $0.id == id }
    }

    private func confirmDelete(_ folder: Folder) {
        guard !folder.isDeleted, folder.modelContext != nil else { return }
        folderToDelete = FolderDeletionTarget(
            id: folder.id,
            name: folder.displayName,
            hasSubfolders: folder.hasActiveSubfolders
        )
    }

    private func confirmDelete(_ tag: Tag) {
        guard !tag.isDeleted, tag.modelContext != nil else { return }
        tagToDelete = TagDeletionTarget(id: tag.id, name: tag.name)
    }

    private func deleteFolder(withID id: UUID) {
        guard let folder = folder(withID: id) else { return }
        _ = perform { library.trash(folder) }
        reconcileSelection()
    }

    private func deleteTag(withID id: UUID) {
        if selection == .tag(id) {
            selection = .all
        }
        guard let tag = liveTags.first(where: { $0.id == id }) else { return }
        _ = perform { library.delete(tag) }
    }

    /// Deleted notes stay in Recently Deleted; moving is only for active notes.
    private func moveNotes(_ references: [NoteReference], to folder: Folder?) -> Bool {
        if let folder, folder.isDeleted || folder.modelContext == nil || folder.deletedAt != nil {
            return false
        }
        let ids = references.map(\.id)
        guard !ids.isEmpty else { return false }
        return perform {
            let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
                ids.contains($0.id) && $0.deletedAt == nil
            }))
            for note in notes { note.move(to: folder) }
        }
    }

    private func trashNotes(_ references: [NoteReference]) -> Bool {
        let ids = references.map(\.id)
        guard !ids.isEmpty else { return false }
        return perform {
            let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
                ids.contains($0.id) && $0.deletedAt == nil
            }))
            for note in notes { library.delete(note) }
        }
    }

    private func tagNotes(_ references: [NoteReference], with tag: Tag) -> Bool {
        guard !tag.isDeleted, tag.modelContext != nil else { return false }
        let ids = references.map(\.id)
        guard !ids.isEmpty else { return false }
        let tagName = tag.name
        return perform {
            let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
                ids.contains($0.id) && $0.deletedAt == nil
            }))
            for note in notes {
                try library.addTag(named: tagName, to: note)
            }
        }
    }

    private func canMove(_ folder: Folder, to parent: Folder?) -> Bool {
        guard !folder.isDeleted, folder.modelContext != nil, folder.deletedAt == nil else { return false }
        guard let parent else { return true }
        return !parent.isDeleted && parent.modelContext != nil && parent.deletedAt == nil
            && parent.id != folder.id
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
        if let parent {
            showsFoldersSection = true
            setFolderExpanded(parent.id, isExpanded: true)
        }
        revealSelection()
    }

    /// Preserve the system's selection behavior while keeping deleted scopes out of navigation.
    private func reconcileSelection() {
        switch selection {
        case .folder(let id):
            if folder(withID: id) == nil { selection = .all }
        case .tag(let id):
            if !liveTags.contains(where: { $0.id == id }) { selection = .all }
        default:
            break
        }
        revealSelection()
    }

    private func revealSelection() {
        switch selection {
        case .folder(let id):
            showsFoldersSection = true
            var ancestor = folder(withID: id)?.parent
            var visited: Set<UUID> = []
            var toExpand: [UUID] = []
            while let folder = ancestor, !folder.isDeleted, folder.modelContext != nil, visited.insert(folder.id).inserted {
                toExpand.append(folder.id)
                ancestor = folder.parent
            }
            expandFolderIDs(toExpand)
        case .tag:
            showsTagsSection = true
        default:
            break
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
            showsFoldersSection = true
            setFolderExpanded(parent.id, isExpanded: true)
            selection = .folder(folder.id)
        }
    }

    private func askRename(_ folder: Folder) {
        guard !folder.isDeleted, folder.modelContext != nil else { return }
        ask("Rename Folder", initial: folder.name, confirm: "Rename") { name in
            try library.rename(folder, to: name)
        }
    }

    private func askRename(_ tag: Tag) {
        guard !tag.isDeleted, tag.modelContext != nil else { return }
        let previousID = tag.id
        ask("Rename Tag", initial: tag.name, confirm: "Rename") { name in
            let result = try library.rename(tag, to: name)
            if selection == .tag(previousID) {
                selection = .tag(result.id)
            }
        }
    }
}

// MARK: - Subviews

private struct FolderRow: View {
    let folder: Folder
    let movableDestinations: () -> [Folder]
    let onNewSubfolder: () -> Void
    let onRename: () -> Void
    let onMoveToParent: (Folder?) -> Void
    let onDelete: () -> Void
    let onDropNotes: ([NoteReference]) -> Void

    var body: some View {
        if !folder.isDeleted, folder.modelContext != nil {
            Label {
                Text(verbatim: folder.displayName)
            } icon: {
                Image(systemName: "folder")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .badge(folder.activeNoteCount)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                Button("Rename", systemImage: "pencil", action: onRename)
                    .labelStyle(.iconOnly)
            }
            .contextMenu {
                FolderMenu(
                    folder: folder,
                    movableDestinations: movableDestinations(),
                    onNewSubfolder: onNewSubfolder,
                    onRename: onRename,
                    onMoveToParent: onMoveToParent,
                    onDelete: onDelete
                )
            }
            .dropDestination(for: NoteReference.self) { references, _ in
                onDropNotes(references)
            }
            .tag(folder.sidebarScope)
        }
    }
}

private struct FolderMenu: View {
    let folder: Folder
    let movableDestinations: [Folder]
    let onNewSubfolder: () -> Void
    let onRename: () -> Void
    let onMoveToParent: (Folder?) -> Void
    let onDelete: () -> Void

    private var canMoveAnywhere: Bool {
        folder.parent != nil || !movableDestinations.isEmpty
    }

    var body: some View {
        Button("New Subfolder", systemImage: "folder.badge.plus", action: onNewSubfolder)
        Button("Rename", systemImage: "pencil", action: onRename)
        if canMoveAnywhere {
            Menu("Move to", systemImage: "folder") {
                if folder.parent != nil {
                    Button("Top Level", systemImage: "arrow.up.to.line") {
                        onMoveToParent(nil)
                    }
                    if !movableDestinations.isEmpty {
                        Divider()
                    }
                }
                ForEach(movableDestinations, id: \.persistentModelID) { destination in
                    Button {
                        onMoveToParent(destination)
                    } label: {
                        Text(verbatim: destination.path)
                    }
                }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

private struct TagRow: View {
    let tag: Tag
    let onRename: () -> Void
    let onDelete: () -> Void
    let onDropNotes: ([NoteReference]) -> Void

    var body: some View {
        if !tag.isDeleted, tag.modelContext != nil {
            Label {
                Text(verbatim: tag.name)
            } icon: {
                Image(systemName: "tag")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .badge(tag.activeNoteCount)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                Button("Rename", systemImage: "pencil", action: onRename)
                    .labelStyle(.iconOnly)
            }
            .contextMenu {
                TagMenu(onRename: onRename, onDelete: onDelete)
            }
            .dropDestination(for: NoteReference.self) { references, _ in
                onDropNotes(references)
            }
            .tag(NoteScope.tag(tag.id))
        }
    }
}

private struct TagMenu: View {
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Rename", systemImage: "pencil", action: onRename)
        Button("Delete Tag", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

/// A native disclosure tree. List's onMove preserves separate child rows;
/// reorderable currently combines expanded subtrees into a single selectable cell.
private struct FolderTree<Row: View>: View {
    let folders: [Folder]
    let expandedIDs: Set<UUID>
    let onToggleExpanded: (UUID, Bool) -> Void
    let row: (Folder) -> Row
    let move: ([Folder], IndexSet, Int) -> Void

    var body: some View {
        ForEach(folders, id: \.sidebarScope) { folder in
            if let subfolders = folder.childNodes {
                let folderID = folder.id
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedIDs.contains(folderID) },
                    set: { onToggleExpanded(folderID, $0) }
                )) {
                    FolderTree(
                        folders: subfolders,
                        expandedIDs: expandedIDs,
                        onToggleExpanded: onToggleExpanded,
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
        SidebarView(selection: .constant(.all), asksNewFolder: .constant(false))
    }
    .modelContainer(container)
}
