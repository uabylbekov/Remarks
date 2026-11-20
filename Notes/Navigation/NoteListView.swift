import SwiftUI
import SwiftData
import NotesCore

/// The middle column: the notes in the selected place, with search (Spec 04).
struct NoteListView: View {
    let scope: NoteScope
    @Binding var selectedNoteID: UUID?

    @Environment(\.modelContext) private var context
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]
    @Query private var folders: [Folder]
    @Query private var tags: [Tag]
    @State private var searchText = ""
    @State private var searchEverywhere = true
    @State private var tagTarget: Note?
    @State private var historyTarget: Note?
    @State private var confirmsEmptyTrash = false

    private var library: Library { Library(context: context) }
    private var isSearching: Bool { !NoteSearch.words(in: searchText).isEmpty }

    private var results: [Note] {
        NoteFilter.apply(to: allNotes, scope: scope, query: searchText, searchEverywhere: searchEverywhere)
    }

    private var title: String {
        switch scope {
        case .all: "All Notes"
        case .unfiled: "Unfiled"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        case .tag(let id): tags.first { $0.id == id }?.name ?? "Tag"
        case .trash: "Recently Deleted"
        }
    }

    /// The scope switch only makes sense when the list is narrower than everything.
    private var showsSearchScopes: Bool {
        switch scope {
        case .unfiled, .folder, .tag: true
        case .all, .trash: false
        }
    }

    /// Where the editor sits beside the list, an empty editor column looks different from a full one. Showing the first
    /// note keeps the toolbar the same. On a phone the editor replaces the list, so nothing is opened on its own.
    private var opensFirstNote: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    private func selectFirstNoteIfNeeded() {
        guard opensFirstNote, !results.contains(where: { $0.id == selectedNoteID }), let first = results.first else { return }
        selectedNoteID = first.id
    }

    var body: some View {
        let list = noteList
            .searchable(text: $searchText, prompt: "Search notes")
        if showsSearchScopes {
            list.searchScopes($searchEverywhere) {
                Text("All Notes").tag(true)
                Text(title).tag(false)
            }
        } else {
            list
        }
    }

    private var noteList: some View {
        List(selection: $selectedNoteID) {
            ForEach(results) { note in
                NoteRow(note: note, query: searchText, showsFolder: scope == .all || isSearching)
                    .tag(note.id)
                    .swipeActions(edge: .leading) {
                        if note.deletedAt != nil {
                            Button("Restore", systemImage: "arrow.uturn.backward") { library.restore(note) }.tint(.blue)
                        } else {
                            Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                                note.setPinned(!note.isPinned)
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if note.deletedAt != nil {
                            Button("Delete Forever", systemImage: "trash", role: .destructive) { deleteForever(note) }
                        } else {
                            Button("Delete", systemImage: "trash", role: .destructive) { trash(note) }
                        }
                    }
                    .contextMenu {
                        NoteActionsMenu(note: note, onNewTag: { tagTarget = note }, onShowHistory: { historyTarget = note })
                    }
            }
        }
        #if os(iOS)
        // The same rounded, divider-free rows as the folder list in the sidebar. (On the Mac, a middle-column list
        // already looks like that, and the sidebar style crashes SwiftUI there.)
        .listStyle(.sidebar)
        #endif
        .onChange(of: results.map(\.id), initial: true) { selectFirstNoteIfNeeded() }
        .onChange(of: selectedNoteID) { selectFirstNoteIfNeeded() }
        .navigationTitle(title)
        .toolbar {
            if scope == .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", systemImage: "trash.slash") { confirmsEmptyTrash = true }
                        .disabled(results.isEmpty)
                }
            } else {
                #if os(macOS)
                // At the list column's leading edge, not the window's trailing edge, which is over the editor.
                ToolbarItem(placement: .navigation) {
                    Button("New Note", systemImage: "square.and.pencil", action: addNote)
                        .keyboardShortcut("n")
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button("New Note", systemImage: "square.and.pencil", action: addNote)
                        .keyboardShortcut("n")
                }
                #endif
            }
        }
        .overlay { emptyState }
        .newTagPrompt(for: $tagTarget)
        .versionHistorySheet(for: $historyTarget)
        .confirmationDialog("Delete all notes in Recently Deleted forever?", isPresented: $confirmsEmptyTrash, titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) {
                _ = try? library.emptyTrash()
                selectedNoteID = nil
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let note = results.first(where: { $0.id == selectedNoteID }) { trash(note) }
        }
        #endif
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if results.isEmpty {
            if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                switch scope {
                case .trash:
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash", description: Text("Deleted notes stay here for 30 days."))
                case .all, .unfiled, .folder, .tag:
                    ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Tap New Note to start."))
                }
            }
        }
    }

    // MARK: Actions

    private func addNote() {
        var folder: Folder?
        var tag: Tag?
        switch scope {
        case .folder(let id): folder = folders.first { $0.id == id }
        case .tag(let id): tag = tags.first { $0.id == id }
        case .all, .unfiled, .trash: break
        }
        let note = library.createNote(in: folder)
        if let tag { note.tags = [tag] }
        selectedNoteID = note.id
    }

    private func trash(_ note: Note) {
        library.trash(note)
        if selectedNoteID == note.id { selectedNoteID = nil }
    }

    private func deleteForever(_ note: Note) {
        if selectedNoteID == note.id { selectedNoteID = nil }
        library.deleteForever(note)
    }
}

private struct NoteRow: View {
    let note: Note
    let query: String
    let showsFolder: Bool

    private var detail: String {
        if let match = NoteSearch.snippet(in: note.body, query: query) { return match }
        return note.snippet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                }
                Text(note.title.isEmpty ? "New note" : note.title).font(.headline).lineLimit(1)
            }
            if !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                    .layoutPriority(1)
                if showsFolder, let folder = note.folder {
                    Label(folder.name.isEmpty ? "Untitled" : folder.name, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("With a selected note") {
    let container: ModelContainer
    do { container = try NotesStore.makeContainer(inMemory: true) } catch { fatalError("\(error)") }
    let library = Library(context: container.mainContext)
    let work = try? library.createFolder(named: "Work")
    let plan = library.createNote(body: "# Launch plan\nShip the editor and the sidebar.", in: work)
    plan.setPinned(true)
    library.createNote(body: "# Ideas\nA notes app with code blocks.")
    library.createNote(body: "# Groceries\nmilk eggs")
    return NavigationStack {
        NoteListView(scope: .all, selectedNoteID: .constant(plan.id))
    }
    .modelContainer(container)
}
