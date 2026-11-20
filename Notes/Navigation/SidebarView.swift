import SwiftUI
import SwiftData
import NotesCore

/// A question with a text field, such as a new folder name.
private struct NamePrompt {
    let title: String
    let initialText: String
    let confirmTitle: String
    let commit: (String) -> Void
}

/// Where notes live: All Notes, Unfiled, the folder tree, tags, and Recently Deleted (Spec 04).
struct SidebarView: View {
    @Binding var selection: NoteScope?

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Folder> { $0.parent == nil && $0.deletedAt == nil }, sort: \Folder.sortIndex)
    private var rootFolders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Environment(\.deviceBottomInset) private var deviceBottomInset
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    #if os(iOS)
    @State private var showsAppearance = false
    #endif

    private var library: Library { Library(context: context) }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Notes", systemImage: "note.text").tag(NoteScope.all)
                Label("Unfiled", systemImage: "tray").tag(NoteScope.unfiled)
            }

            Section("Folders") {
                OutlineGroup(rootFolders, children: \.childNodes) { folder in
                    folderRow(folder)
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        tagRow(tag)
                    }
                }
            }

            Section {
                Label("Recently Deleted", systemImage: "trash").tag(NoteScope.trash)
            }
        }
        .navigationTitle("Notes")
        // Pinned to the window's bottom edge, not the column's. The column's bottom edge moves while the note list's
        // search field slides away, which made the text jump when going back.
        .overlay(alignment: .bottom) {
            SyncStatusFooter()
                .padding(.bottom, deviceBottomInset)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .contentMargins(.bottom, 56 + deviceBottomInset, for: .scrollContent)
        #if os(iOS)
        .sheet(isPresented: $showsAppearance) {
            NavigationStack {
                AppearanceSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsAppearance = false }
                        }
                    }
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Folder", systemImage: "folder.badge.plus") { askNewFolder(in: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button("Appearance", systemImage: "textformat") { showsAppearance = true }
            }
            #endif
        }
        .alert(
            prompt?.title ?? "",
            isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
        ) {
            TextField("Name", text: $promptText)
            Button(prompt?.confirmTitle ?? "Save") {
                prompt?.commit(promptText)
                prompt = nil
            }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    // MARK: Rows

    // Split into small functions with explicit types so the compiler can check each quickly.
    private func folderRow(_ folder: Folder) -> some View {
        let name: String = folder.name.isEmpty ? "Untitled" : folder.name
        let count: Int = folder.activeNoteCount
        let scope: NoteScope = .folder(folder.id)
        return Label(name, systemImage: "folder")
            .badge(count)
            .tag(scope)
            .contextMenu { folderMenu(folder) }
    }

    private func tagRow(_ tag: Tag) -> some View {
        let count: Int = (tag.notes ?? []).filter { $0.deletedAt == nil }.count
        let scope: NoteScope = .tag(tag.id)
        return Label(tag.name, systemImage: "tag")
            .badge(count)
            .tag(scope)
            .contextMenu { tagMenu(tag) }
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Subfolder", systemImage: "folder.badge.plus") { askNewFolder(in: folder) }
        Button("Rename", systemImage: "pencil") {
            ask("Rename Folder", initial: folder.name, confirm: "Rename") { name in
                try? library.rename(folder, to: name)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            library.trash(folder)
            if selection == .folder(folder.id) { selection = .all }
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        Button("Rename", systemImage: "pencil") {
            ask("Rename Tag", initial: tag.name, confirm: "Rename") { name in
                if let result = try? library.rename(tag, to: name), selection == .tag(tag.id) {
                    selection = .tag(result.id)
                }
            }
        }
        Button("Delete Tag", systemImage: "trash", role: .destructive) {
            let id = tag.id
            library.delete(tag)
            if selection == .tag(id) { selection = .all }
        }
    }

    // MARK: Prompts

    private func ask(_ title: String, initial: String = "", confirm: String, commit: @escaping (String) -> Void) {
        promptText = initial
        prompt = NamePrompt(title: title, initialText: initial, confirmTitle: confirm, commit: commit)
    }

    private func askNewFolder(in parent: Folder?) {
        ask(parent == nil ? "New Folder" : "New Subfolder", confirm: "Create") { name in
            if let folder = try? library.createFolder(named: name, in: parent) {
                selection = .folder(folder.id)
            }
        }
    }
}
