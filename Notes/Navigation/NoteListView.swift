import SwiftUI
import SwiftData
import NotesCore

/// The middle column: the notes in the selected place, with search (Spec 04).
/// This view owns the search field. The notes themselves are loaded by `NoteResultsList`, which is rebuilt with a
/// new query whenever the place or the reach of the search changes.
struct NoteListView: View {
    let scope: NoteScope
    @Binding var selectedNoteID: UUID?

    @Query private var folders: [Folder]
    @Query private var tags: [Tag]
    @State private var searchText = ""
    @State private var searchEverywhere = true

    private var title: Text {
        switch scope {
        case .all: Text("All Notes")
        case .unfiled: Text("Unfiled")
        case .folder(let id):
            if let folder = folders.first(where: { $0.id == id }) {
                Text(verbatim: folder.name)
            } else {
                Text("Folder")
            }
        case .tag(let id):
            if let tag = tags.first(where: { $0.id == id }) {
                Text(verbatim: tag.name)
            } else {
                Text("Tag")
            }
        case .trash: Text("Recently Deleted")
        }
    }

    /// The scope switch only makes sense when the list is narrower than everything.
    private var showsSearchScopes: Bool {
        switch scope {
        case .unfiled, .folder, .tag: true
        case .all, .trash: false
        }
    }

    var body: some View {
        NoteResultsList(
            scope: scope,
            selectedNoteID: $selectedNoteID,
            title: title,
            searchText: $searchText,
            searchEverywhere: searchEverywhere
        )
        .searchable(text: $searchText, prompt: "Search notes")
        .searchScopes($searchEverywhere) {
            if showsSearchScopes {
                Text("All Notes").tag(true)
                title.tag(false)
            }
        }
    }
}

/// The list of notes. The database does the filtering and ordering: one query for the pinned notes and one for the
/// rest, each limited to the scope, newest first. Without a search nothing here scans the notes, so a save while typing
/// does not cost more as the library grows. Only a search ranks the loaded notes in memory.
private struct NoteResultsList: View {
    let scope: NoteScope
    @Binding var selectedNoteID: UUID?
    let title: Text
    @Binding var searchText: String
    let searchEverywhere: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.calendar) private var calendar
    @Query private var pinned: [Note]
    @Query private var unpinned: [Note]
    @Query private var folders: [Folder]
    @Query private var tags: [Tag]
    @State private var tagTarget: Note?
    @State private var exportTarget: Note?
    @State private var deleteForeverTarget: Note?
    @State private var confirmsEmptyTrash = false
    @State private var errorMessage: String?
    @State private var now = Date.now

    private var library: Library { Library(context: context) }
    private var isSearching: Bool { !NoteSearch.words(in: searchText).isEmpty }

    init(scope: NoteScope, selectedNoteID: Binding<UUID?>, title: Text, searchText: Binding<String>, searchEverywhere: Bool) {
        self.scope = scope
        self._selectedNoteID = selectedNoteID
        self.title = title
        self._searchText = searchText
        self.searchEverywhere = searchEverywhere
        // A search that looks everywhere needs every live note, whatever the scope is.
        let widened = searchEverywhere && !NoteSearch.words(in: searchText.wrappedValue).isEmpty
        _pinned = Query(filter: scope.predicate(isPinned: true, widenedToAllNotes: widened), sort: \Note.modifiedAt, order: .reverse)
        _unpinned = Query(filter: scope.predicate(isPinned: false, widenedToAllNotes: widened), sort: \Note.modifiedAt, order: .reverse)
    }

    /// What the list shows: pinned notes first, then the rest, or the ranked matches while searching.
    private var results: [Note] {
        let loaded = pinned + unpinned
        guard isSearching else { return loaded }
        return NoteFilter.apply(to: loaded, scope: scope, query: searchText, searchEverywhere: searchEverywhere)
    }

    var body: some View {
        let results = results
        noteList(results, now: now)
        // The headings and the dates in the rows are by calendar day, so the list only has to be rebuilt at midnight.
        // Rebuilding it on a timer has the table lay its rows out again while the notes are being edited.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) { now = .now }
        }
        .onChange(of: ResultsKey(count: results.count, scope: scope, query: searchText, everywhere: searchEverywhere), initial: true) {
            // A note that left the list (trashed, moved, no longer matching) cannot stay selected.
            if let selectedNoteID, !results.contains(where: { $0.id == selectedNoteID }) {
                self.selectedNoteID = nil
            }
        }
    }

    private func noteList(_ results: [Note], now: Date) -> some View {
        List(selection: $selectedNoteID) {
            if isSearching {
                // Ranked matches, not grouped: the order says how well each note matches.
                ForEach(results) { row($0, now: now) }
            } else {
                if !pinned.isEmpty {
                    headedSection(Label("Pinned", systemImage: "pin.fill")) {
                        ForEach(pinned) { row($0, now: now) }
                    }
                }
                dateSections(now: now)
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        // As in Apple Notes, the title carries the number of notes under it.
        .navigationSubtitle(Text("^[\(results.count) note](inflect: true)"))
        #endif
        .toolbar {
            if scope == .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", systemImage: "trash.slash") { confirmsEmptyTrash = true }
                        .disabled(pinned.isEmpty && unpinned.isEmpty && !folders.contains { $0.deletedAt != nil })
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
        .overlay { emptyState(results) }
        .newTagPrompt(for: $tagTarget)
        .noteExport(for: $exportTarget)
        .deleteForeverConfirmation(for: $deleteForeverTarget)
        .confirmationDialog("Delete all notes and folders in Recently Deleted forever?", isPresented: $confirmsEmptyTrash, titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) {
                do {
                    _ = try library.emptyTrash()
                    try context.save()
                    selectedNoteID = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Unable to Complete Action", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
        #if os(macOS)
        .onDeleteCommand {
            if let note = results.first(where: { $0.id == selectedNoteID }) {
                if note.deletedAt != nil {
                    deleteForeverTarget = note
                } else {
                    trash(note)
                }
            }
        }
        #endif
    }

    /// One section per date heading. The notes arrive newest first, so each heading takes a run of neighbors.
    @ViewBuilder
    private func dateSections(now: Date) -> some View {
        let runs: [NoteDateGroup.Run] = NoteDateGroup.runs(of: unpinned, date: { $0.modifiedAt }, now: now, calendar: calendar)
        ForEach(runs, id: \.group) { run in
            headedSection(run.group.title(calendar: calendar)) {
                ForEach(unpinned[run.range]) { row($0, now: now) }
            }
        }
    }

    /// A heading and the notes under it. On the Mac the heading is a plain row: a real section header floats at the top
    /// of the list, and the table draws a divider line under it that no separator setting removes.
    @ViewBuilder
    private func headedSection<Heading: View, Rows: View>(_ heading: Heading, @ViewBuilder rows: () -> Rows) -> some View {
        #if os(macOS)
        Section {
            heading
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .accessibilityAddTraits(.isHeader)
            rows()
        }
        #else
        Section {
            rows()
        } header: {
            heading
        }
        .headerProminence(.increased)
        .listSectionSeparator(.hidden)
        #endif
    }

    private func row(_ note: Note, now: Date) -> some View {
        NavigationLink(value: note.id) {
            NoteRow(note: note, now: now, query: searchText, showsFolder: scope == .all || isSearching, showsPin: isSearching)
        }
        // The date headings already group the notes, so no lines between rows, as in Apple Notes.
        .listRowSeparator(.hidden)
        // Dragged onto a folder in the sidebar, the note moves there.
        .draggable(NoteReference(id: note.id))
        .swipeActions(edge: .leading) {
            if note.deletedAt != nil {
                Button("Restore", systemImage: "arrow.uturn.backward") { perform { library.restore(note) } }
            } else {
                Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                    perform { note.setPinned(!note.isPinned) }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if note.deletedAt != nil {
                Button("Delete Forever", systemImage: "trash", role: .destructive) { deleteForeverTarget = note }
            } else {
                Button("Delete", systemImage: "trash", role: .destructive) { trash(note) }
            }
        }
        .contextMenu {
            NoteActionsMenu(note: note, onNewTag: { tagTarget = note }, onExport: { exportTarget = note }, onDeleteForever: { deleteForeverTarget = note }, onError: { errorMessage = $0 })
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private func emptyState(_ results: [Note]) -> some View {
        if results.isEmpty {
            if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                switch scope {
                case .trash:
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash", description: Text("Deleted notes stay here for 30 days."))
                case .all, .unfiled, .folder, .tag:
                    ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Choose New Note to start."))
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
        do {
            try context.save()
            // A new empty note cannot match an active text search.
            searchText = ""
            selectedNoteID = note.id
        } catch {
            context.delete(note)
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            try context.save()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func trash(_ note: Note) {
        perform {
            library.trash(note)
        }
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

/// What decides whether the selected note is still in the list. The count changes whenever a note enters or leaves.
private struct ResultsKey: Equatable {
    let count: Int
    let scope: NoteScope
    let query: String
    let everywhere: Bool
}
