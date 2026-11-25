import SwiftUI
import SwiftData
import RemarksCore

/// The middle column: the notes in the selected place, with search (Spec 04).
/// This view owns the search field and the shared folder/tag queries. The notes themselves are loaded by
/// `NoteResultsList`, which builds its `@Query` descriptors when it is created.
///
/// The field shows what is typed at once, but the list follows a moment after typing stops (`appliedQuery`). This view
/// never reads `searchText` while it builds its body, so a keystroke does not rebuild the list or its queries, and a long
/// library is not searched for every letter.
struct NoteListView: View {
    let scope: NoteScope
    @Binding var selectedNoteID: UUID?
    var onWillCreateNote: () -> Void = {}
    var onCreatedNote: (UUID) -> Void = { _ in }

    @Query private var folders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var searchText = ""
    @State private var appliedQuery = ""
    @State private var pendingQuery: Task<Void, Never>?
    @State private var searchEverywhere = true

    private var liveFolders: [Folder] {
        folders.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var liveTags: [Tag] {
        tags.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var isSearching: Bool {
        !NoteSearch.words(in: appliedQuery).isEmpty
    }

    /// The search field. Typing updates the field now and the list after a pause; clearing the field updates both now.
    private var searchField: Binding<String> {
        Binding(
            get: { searchText },
            set: { newValue in
                searchText = newValue
                pendingQuery?.cancel()
                guard !newValue.isEmpty else {
                    appliedQuery = ""
                    return
                }
                pendingQuery = Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    appliedQuery = newValue
                }
            }
        )
    }

    private func clearSearch() {
        pendingQuery?.cancel()
        searchText = ""
        appliedQuery = ""
    }

    private var title: Text {
        switch scope {
        case .all: Text("All Notes")
        case .unfiled: Text("Unfiled")
        case .folder(let id):
            if let folder = liveFolders.first(where: { $0.id == id }) {
                Text(verbatim: folder.displayName)
            } else {
                Text("Folder")
            }
        case .tag(let id):
            if let tag = liveTags.first(where: { $0.id == id }) {
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
            hasDeletedFolders: liveFolders.contains { $0.deletedAt != nil },
            searchField: searchField,
            query: appliedQuery,
            clearSearch: clearSearch,
            isSearching: isSearching,
            searchEverywhere: $searchEverywhere,
            showsSearchScopes: showsSearchScopes,
            widenedToAllNotes: searchEverywhere && isSearching,
            onWillCreateNote: onWillCreateNote,
            onCreatedNote: onCreatedNote
        )
        .onChange(of: scope) { clearSearch() }
    }
}

/// Captures a live note's plain `UUID` while the model is valid so SwiftUI `List` diffing
/// never faults a deleted SwiftData `@Model` attribute during row-removal animations.
private struct NoteRowItem: Identifiable {
    let id: UUID
    let note: Note
}

/// The list of notes. The database does the filtering and ordering: one query for the pinned notes and one for the
/// rest, each limited to the scope, newest first (or newest-deleted first in Recently Deleted). Without a search
/// nothing here scans the notes, and their bodies are not even loaded, so a save while typing does not cost more as the
/// library grows. A search loads the bodies and filters in memory.
private struct NoteResultsList: View {
    let scope: NoteScope
    @Binding var selectedNoteID: UUID?
    let title: Text
    let hasDeletedFolders: Bool
    let searchField: Binding<String>
    /// The search the list shows, which follows the field a moment after typing stops.
    let searchText: String
    let clearSearch: () -> Void
    let isSearching: Bool
    @Binding var searchEverywhere: Bool
    let showsSearchScopes: Bool
    let onWillCreateNote: () -> Void
    let onCreatedNote: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.calendar) private var calendar
    @Query private var pinned: [Note]
    @Query private var unpinned: [Note]
    @Query private var untitled: [Note]
    @State private var tagTarget: Note?
    @State private var exportRequest: NoteExportRequest?
    @State private var deleteForeverNoteID: UUID?
    @State private var confirmsEmptyTrash = false
    @State private var errorMessage: String?
    @State private var now = Date.now
    #if os(macOS)
    @State private var settledScope: NoteScope?
    #endif

    private var library: Library { Library(context: context) }

    private var livePinned: [Note] {
        pinned.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var liveUnpinned: [Note] {
        unpinned.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var liveUntitled: [Note] {
        untitled.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    init(
        scope: NoteScope,
        selectedNoteID: Binding<UUID?>,
        title: Text,
        hasDeletedFolders: Bool,
        searchField: Binding<String>,
        query: String,
        clearSearch: @escaping () -> Void,
        isSearching: Bool,
        searchEverywhere: Binding<Bool>,
        showsSearchScopes: Bool,
        widenedToAllNotes: Bool,
        onWillCreateNote: @escaping () -> Void,
        onCreatedNote: @escaping (UUID) -> Void
    ) {
        self.scope = scope
        self._selectedNoteID = selectedNoteID
        self.title = title
        self.hasDeletedFolders = hasDeletedFolders
        self.searchField = searchField
        self.searchText = query
        self.clearSearch = clearSearch
        self.isSearching = isSearching
        self._searchEverywhere = searchEverywhere
        self.showsSearchScopes = showsSearchScopes
        self.onWillCreateNote = onWillCreateNote
        self.onCreatedNote = onCreatedNote
        // The rows only need titles, previews, and dates. A search also reads the bodies.
        _pinned = Query(scope.fetchDescriptor(isPinned: true, widenedToAllNotes: widenedToAllNotes, includesBody: isSearching))
        _unpinned = Query(scope.fetchDescriptor(isPinned: false, widenedToAllNotes: widenedToAllNotes, includesBody: isSearching))
        _untitled = Query(filter: scope.untitledPredicate)
    }

    /// Whether this scope already has an empty note, disabling New Note as in Apple Notes.
    /// Checks the tiny untitled query plus the selected note so clearing an existing note disables New Note immediately.
    private var hasEmptyNote: Bool {
        guard scope != .trash else { return false }
        if liveUntitled.contains(where: \.isEmpty) { return true }
        if let selectedNoteID,
           let selected = livePinned.first(where: { $0.id == selectedNoteID })
               ?? liveUnpinned.first(where: { $0.id == selectedNoteID }),
           scope.contains(selected),
           selected.isEmpty {
            return true
        }
        return false
    }

    var body: some View {
        let currentPinned = livePinned
        let currentUnpinned = liveUnpinned
        let loaded = currentPinned + currentUnpinned
        let currentResults: [Note] = isSearching
            ? NoteFilter.apply(to: loaded, scope: scope, query: searchText, searchEverywhere: searchEverywhere)
            : loaded
        // Whether the open note is still part of this place. A search narrows what the list shows, not what is open, so
        // this looks at the notes the scope loads, before the search filters them: only a note that was trashed or moved
        // away closes the editor.
        let isSelectedNotePresent = selectedNoteID.map { id in
            loaded.contains { $0.id == id }
        } ?? true

        noteList(results: currentResults, loaded: loaded, pinned: currentPinned, unpinned: currentUnpinned, now: now)
            // The headings and the dates in the rows are by calendar day, so the list only has to be rebuilt at midnight.
            // Rebuilding it on a timer has the table lay its rows out again while the notes are being edited.
            .task {
                for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) { now = .now }
            }
            .onChange(of: isSelectedNotePresent, initial: true) {
                // A note that left the list (trashed, moved, no longer matching) cannot stay selected.
                if !isSelectedNotePresent {
                    selectedNoteID = nil
                }
            }
    }

    private func listSelection(loaded: [Note]) -> Binding<UUID?> {
        Binding(
            get: { selectedNoteID },
            set: { newValue in
                #if os(macOS)
                if newValue == nil,
                   let current = selectedNoteID,
                   loaded.contains(where: { $0.id == current }) {
                    return
                }
                #endif
                selectedNoteID = newValue
            }
        )
    }

    private func noteList(results: [Note], loaded: [Note], pinned: [Note], unpinned: [Note], now: Date) -> some View {
        List(selection: listSelection(loaded: loaded)) {
            if scope == .trash && !results.isEmpty {
                Text("Notes are permanently deleted after \(Library.trashRetentionDays) days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            if isSearching {
                // Ranked matches, not grouped: the order says how well each note matches.
                ForEach(rowItems(for: results)) { row($0, now: now) }
            } else {
                #if os(macOS)
                ForEach(groupedRows(pinned: pinned, unpinned: unpinned, now: now)) { entry in
                    switch entry {
                    case .heading(let heading):
                        heading.label(calendar: calendar)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                            .accessibilityAddTraits(.isHeader)
                    case .note(let item):
                        row(item, now: now)
                    }
                }
                #else
                if !pinned.isEmpty {
                    headedSection(Label("Pinned", systemImage: "pin.fill")) {
                        ForEach(rowItems(for: pinned)) { row($0, now: now) }
                    }
                }
                dateSections(for: unpinned, now: now)
                #endif
            }
        }
        #if os(macOS)
        .animation(!isSearching && settledScope == scope ? .default : nil, value: loaded.map(\.id))
        .task(id: scope) {
            await Task.yield()
            settledScope = scope
        }
        #else
        .animation(!isSearching ? .default : nil, value: loaded.map(\.id))
        #endif
        .navigationTitle(title)
        #if os(macOS)
        // As in Apple Notes, the title carries the number of notes under it.
        .navigationSubtitle(Text("^[\(results.count) note](inflect: true)"))
        #endif
        .searchable(text: searchField, prompt: "Search notes")
        #if os(iOS)
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        #endif
        .searchScopes($searchEverywhere) {
            if showsSearchScopes {
                Text("All Notes").tag(true)
                title.tag(false)
            }
        }
        .toolbar {
            if scope == .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty Recently Deleted", systemImage: "trash.slash") { confirmsEmptyTrash = true }
                        .disabled(pinned.isEmpty && unpinned.isEmpty && !hasDeletedFolders)
                }
            } else {
                #if os(macOS)
                // At the list column's leading edge, not the window's trailing edge, which is over the editor.
                // ⌘N lives in FileCommands so it works even when the list column is collapsed.
                ToolbarItem(placement: .navigation) {
                    Button("New Note", systemImage: "square.and.pencil", action: addNote)
                        .disabled(hasEmptyNote)
                }
                #endif
            }
            #if os(iOS)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            if scope != .trash {
                ToolbarItem(placement: .bottomBar) {
                    Button("New Note", systemImage: "square.and.pencil", action: addNote)
                        .keyboardShortcut("n")
                        .disabled(hasEmptyNote)
                }
            }
            #endif
        }
        .overlay { NoteListEmptyState(isEmpty: results.isEmpty, isSearching: isSearching, searchText: searchText, scope: scope) }
        .newTagPrompt(for: $tagTarget)
        .noteExport(for: $exportRequest)
        .deleteForeverConfirmation(for: $deleteForeverNoteID) { deletedID in
            if selectedNoteID == deletedID {
                selectedNoteID = nil
            }
        }
        .confirmationDialog("Delete all notes and folders in Recently Deleted forever?", isPresented: $confirmsEmptyTrash, titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) {
                selectedNoteID = nil
                do {
                    _ = try library.emptyTrash()
                    try context.save()
                } catch {
                    context.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("These items can’t be recovered.")
        }
        .alert("Unable to Complete Action", item: $errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
        #if os(iOS)
        .background {
            NoteListScrollPreserver()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #endif
        #if os(macOS)
        .background {
            NoteListSelectionLock(allowsEmptySelection: results.isEmpty || selectedNoteID == nil)
        }
        .onDeleteCommand {
            if let note = results.first(where: { !$0.isDeleted && $0.modelContext != nil && $0.id == selectedNoteID }) {
                if note.deletedAt != nil {
                    deleteForeverNoteID = note.id
                } else {
                    trash(note)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    /// A single collection gives List each heading and note its own stable row identity.
    private func groupedRows(pinned: [Note], unpinned: [Note], now: Date) -> [GroupedNoteRow] {
        var rows: [GroupedNoteRow] = []
        if !pinned.isEmpty {
            rows.append(.heading(.pinned))
            rows.append(contentsOf: rowItems(for: pinned).map(GroupedNoteRow.note))
        }
        for run in NoteDateGroup.runs(of: unpinned, date: { scope.sortDate(for: $0) }, now: now, calendar: calendar) {
            rows.append(.heading(.date(run.group)))
            rows.append(contentsOf: rowItems(for: Array(unpinned[run.range])).map(GroupedNoteRow.note))
        }
        return rows
    }
    #endif

    #if !os(macOS)
    /// One section per date heading. The notes arrive newest first, so each heading takes a run of neighbors.
    @ViewBuilder
    private func dateSections(for unpinned: [Note], now: Date) -> some View {
        let runs: [NoteDateGroup.Run] = NoteDateGroup.runs(
            of: unpinned,
            date: { scope.sortDate(for: $0) },
            now: now,
            calendar: calendar
        )
        ForEach(runs, id: \.group) { run in
            headedSection(run.group.title(calendar: calendar)) {
                ForEach(rowItems(for: Array(unpinned[run.range]))) { row($0, now: now) }
            }
        }
    }

    #endif

    private func rowItems(for notes: [Note]) -> [NoteRowItem] {
        notes.compactMap { note in
            guard !note.isDeleted, note.modelContext != nil else { return nil }
            return NoteRowItem(id: note.id, note: note)
        }
    }

    #if !os(macOS)
    /// iOS uses native section headers for its grouped note list.
    private func headedSection<Heading: View, Rows: View>(_ heading: Heading, @ViewBuilder rows: () -> Rows) -> some View {
        Section {
            rows()
        } header: {
            heading
        }
        .headerProminence(.increased)
        .listSectionSeparator(.hidden)
    }
    #endif

    private func row(_ item: NoteRowItem, now: Date) -> some View {
        NoteListRow(
            item: item,
            now: now,
            query: searchText,
            showsFolder: scope == .all || isSearching,
            showsPin: isSearching && scope != .trash,
            showsDeletedDate: scope == .trash,
            onRestore: { note in perform { library.restore(note) } },
            onTogglePin: { note in perform { note.setPinned(!note.isPinned) } },
            onTrash: trash,
            onDeleteForever: { deleteForeverNoteID = item.id },
            onNewTag: { tagTarget = $0 },
            onExport: { exportRequest = NoteExportRequest(note: $0, format: $1) },
            onError: { errorMessage = $0 }
        )
    }

    // MARK: Actions

    private func addNote() {
        guard !hasEmptyNote else { return }
        onWillCreateNote()
        do {
            let note = try withAnimation {
                try library.createNote(in: scope)
            }
            try context.save()
            onCreatedNote(note.id)
            // A new empty note cannot match an active text search.
            clearSearch()
            selectedNoteID = note.id
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try withAnimation { try action() }
            try context.save()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func trash(_ note: Note) {
        guard !note.isDeleted, note.modelContext != nil else { return }
        perform {
            library.delete(note)
        }
    }
}

#if os(macOS)
private enum NoteListHeading: Hashable {
    case pinned
    case date(NoteDateGroup)

    @ViewBuilder func label(calendar: Calendar) -> some View {
        switch self {
        case .pinned: Label("Pinned", systemImage: "pin.fill")
        case .date(let group): group.title(calendar: calendar)
        }
    }
}

private enum GroupedNoteRow: Identifiable {
    enum ID: Hashable {
        case heading(NoteListHeading)
        case note(UUID)
    }

    case heading(NoteListHeading)
    case note(NoteRowItem)

    var id: ID {
        switch self {
        case .heading(let heading): .heading(heading)
        case .note(let item): .note(item.id)
        }
    }
}

import AppKit

/// Keeps the AppKit table backing `NoteResultsList` from clearing row selection
/// when clicking empty space below the rows.
private struct NoteListSelectionLock: NSViewRepresentable {
    let allowsEmptySelection: Bool

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(allowsEmptySelection: allowsEmptySelection)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.allowsEmptySelection = allowsEmptySelection
        nsView.syncTableView()
        Task { @MainActor [weak nsView] in
            nsView?.syncTableView()
        }
    }

    final class ProbeView: NSView {
        var allowsEmptySelection: Bool
        private weak var observedTable: NSTableView?
        private var selectionRuleObservation: NSKeyValueObservation?

        init(allowsEmptySelection: Bool) {
            self.allowsEmptySelection = allowsEmptySelection
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        deinit {
            selectionRuleObservation?.invalidate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncTableView()
            attachWhenReady()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            syncTableView()
        }

        override func layout() {
            super.layout()
            syncTableView()
        }

        override func viewWillDraw() {
            super.viewWillDraw()
            syncTableView()
        }

        private func attachWhenReady() {
            guard window != nil, observedTable == nil else { return }
            Task { @MainActor [weak self] in
                for _ in 0..<6 {
                    await Task.yield()
                    guard let self, self.window != nil else { return }
                    self.syncTableView()
                    if self.observedTable != nil { return }
                }
            }
        }

        func syncTableView() {
            guard let tableView = enclosingNoteListTableView() else { return }
            if observedTable !== tableView {
                observedTable = tableView
                selectionRuleObservation?.invalidate()
                selectionRuleObservation = tableView.observe(\.allowsEmptySelection, options: [.new]) { [weak self] table, _ in
                    Task { @MainActor [weak self, weak table] in
                        guard let self, let table, table === self.observedTable,
                              table.allowsEmptySelection != self.allowsEmptySelection else { return }
                        table.allowsEmptySelection = self.allowsEmptySelection
                    }
                }
            }
            if tableView.allowsEmptySelection != allowsEmptySelection {
                tableView.allowsEmptySelection = allowsEmptySelection
            }
        }

        private func enclosingNoteListTableView() -> NSTableView? {
            var cursor: NSView? = self
            while let current = cursor {
                if current is NSSplitView { break }
                if let table = Self.findNoteTableView(in: current) {
                    return table
                }
                cursor = current.superview
            }
            return nil
        }

        private static func findNoteTableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.effectiveStyle != .sourceList {
                return table
            }
            for subview in view.subviews {
                if subview is NSSplitView { continue }
                if let found = findNoteTableView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}
#endif

#if os(iOS)
import UIKit

/// Preserves the note list's scroll offset across navigation pushes/pops.
/// On iOS 26+, returning from an editor without a bottom bar causes UIKit to transiently drop the
/// list's bottom safe-area inset (from the bottom search bar/toolbar) before restoring it, which
/// clamps `UICollectionView.contentOffset` upward when scrolled near the bottom.
private struct NoteListScrollPreserver: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var savedOffsetY: CGFloat?
        private var savedSafeBottom: CGFloat = 0
        private var isRestoring = false

        override func loadView() {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            view = v
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Capture only when a detail view is pushed over this list (not when the list itself is popped).
            guard let parent, !parent.isMovingFromParent, !parent.isBeingDismissed,
                  let scrollView = enclosingScrollView() else {
                savedOffsetY = nil
                isRestoring = false
                return
            }
            // Keep the pre-push offset if an interactive pop was cancelled mid-transition.
            if savedOffsetY == nil {
                savedOffsetY = scrollView.contentOffset.y
                savedSafeBottom = scrollView.safeAreaInsets.bottom
            }
            isRestoring = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard savedOffsetY != nil else { return }
            isRestoring = true
            let coordinator = parent?.transitionCoordinator ?? transitionCoordinator
            coordinator?.animate(alongsideTransition: { [weak self] _ in
                self?.restoreIfReady()
            }, completion: { [weak self] context in
                guard let self else { return }
                if context.isCancelled {
                    self.isRestoring = false
                } else {
                    self.restoreIfReady()
                    self.savedOffsetY = nil
                    self.isRestoring = false
                }
            })
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            restoreIfReady()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            restoreIfReady()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restoreIfReady()
            savedOffsetY = nil
            isRestoring = false
        }

        private func restoreIfReady() {
            guard isRestoring, let targetRawY = savedOffsetY, let scrollView = enclosingScrollView() else { return }
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                savedOffsetY = nil
                isRestoring = false
                return
            }
            guard scrollView.safeAreaInsets.bottom + 0.5 >= savedSafeBottom else { return }
            let inset = scrollView.adjustedContentInset
            let minOffsetY = -inset.top
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            let targetY = min(max(targetRawY, minOffsetY), maxOffsetY)
            if abs(scrollView.contentOffset.y - targetY) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            guard let root = parent?.view else { return nil }
            return Self.findCollectionOrScrollView(in: root)
        }

        private static func findCollectionOrScrollView(in view: UIView) -> UIScrollView? {
            if let collection = view as? UICollectionView {
                return collection
            }
            for subview in view.subviews {
                if let found = findCollectionOrScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}
#endif

// MARK: - Subviews

private struct NoteListRow: View {
    let item: NoteRowItem
    let now: Date
    let query: String
    let showsFolder: Bool
    let showsPin: Bool
    let showsDeletedDate: Bool
    let onRestore: (Note) -> Void
    let onTogglePin: (Note) -> Void
    let onTrash: (Note) -> Void
    let onDeleteForever: () -> Void
    let onNewTag: (Note) -> Void
    let onExport: (Note, NoteExportFormat) -> Void
    let onError: (String) -> Void

    var body: some View {
        let note = item.note
        let isLive = !note.isDeleted && note.modelContext != nil
        let isTrashed = isLive && note.deletedAt != nil
        NavigationLink(value: item.id) {
            NoteRow(
                note: note,
                now: now,
                query: query,
                showsFolder: showsFolder,
                showsPin: showsPin,
                showsDeletedDate: showsDeletedDate
            )
        }
        // The date headings already group the notes, so no lines between rows, as in Apple Notes.
        .listRowSeparator(.hidden)
        // Dragged onto a folder, tag, or Recently Deleted in the sidebar. A deleted note cannot be filed, so it is not dragged.
        .modifier(DragsNote(id: item.id, isEnabled: !isTrashed))
        .swipeActions(edge: .leading) {
            if isTrashed {
                Button("Restore", systemImage: "arrow.uturn.backward") { onRestore(note) }
                    .labelStyle(.iconOnly)
            } else if isLive {
                Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                    onTogglePin(note)
                }
                .labelStyle(.iconOnly)
            }
        }
        // Permanent deletion opens a confirmation dialog, so disallow full-swipe to prevent UIKit from
        // dismissing the row before confirmation.
        .swipeActions(edge: .trailing, allowsFullSwipe: isLive && !isTrashed) {
            if isTrashed {
                // Not `.destructive`: that makes the list remove the row at once, but the note only goes after the
                // confirmation, so the row count would be wrong when the deletion lands.
                Button("Delete", systemImage: "trash", action: onDeleteForever)
                    .tint(.red)
                    .labelStyle(.iconOnly)
            } else if isLive {
                Button("Delete", systemImage: "trash", role: .destructive) { onTrash(note) }
                    .labelStyle(.iconOnly)
            }
        }
        .contextMenu {
            if isLive {
                NoteActionsMenu(
                    note: note,
                    onNewTag: { onNewTag(note) },
                    onExport: { onExport(note, $0) },
                    onDeleteForever: onDeleteForever,
                    onError: onError
                )
            }
        }
    }
}

/// Makes a row draggable as a note reference, unless it is switched off.
private struct DragsNote: ViewModifier {
    let id: UUID
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(NoteReference(id: id))
        } else {
            content
        }
    }
}

private struct NoteListEmptyState: View {
    let isEmpty: Bool
    let isSearching: Bool
    let searchText: String
    let scope: NoteScope

    var body: some View {
        if isEmpty {
            if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                switch scope {
                case .trash:
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash", description: Text("Deleted notes stay here for \(Library.trashRetentionDays) days."))
                case .all, .unfiled, .folder, .tag:
                    Text("No Notes")
                        .foregroundStyle(.secondary)
                }
            }
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
