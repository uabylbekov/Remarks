#if os(macOS)
import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit
import RemarksCore
@testable import Remarks

/// The list does not read the database itself: SwiftUI's `@Query` does. These tests put a real `@Query` on screen with the
/// descriptors the list builds, to check that what it loads is what a plain fetch returns.
@MainActor
struct NoteListQueryTests {
    private struct Probe: View {
        @Query private var notes: [Note]
        let record: ([String]) -> Void

        init(descriptor: FetchDescriptor<Note>, record: @escaping ([String]) -> Void) {
            _notes = Query(descriptor)
            self.record = record
        }

        var body: some View {
            let titles = notes.map(\.title)
            let _ = record(titles)
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// Shows a `@Query` for `descriptor` and returns the titles it loaded.
    private func titlesLoaded(by descriptor: FetchDescriptor<Note>, in container: ModelContainer) async throws -> [String] {
        var seen: [String] = []
        let host = NSHostingView(rootView: Probe(descriptor: descriptor) { seen = $0 }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        window.contentView = nil
        return seen
    }

    @Observable
    final class Place {
        var scope: NoteScope
        init(_ scope: NoteScope) { self.scope = scope }
    }

    enum Style: CustomStringConvertible {
        case descriptor(includesBody: Bool), filterAndSort

        var description: String {
            switch self {
            case .descriptor(let includesBody): "descriptor, bodies: \(includesBody)"
            case .filterAndSort: "filter and sort"
            }
        }
    }

    /// Rebuilds its query whenever the place changes, as the list does when another place is chosen.
    private struct Switcher: View {
        let place: Place
        let style: Style
        let record: ([String]) -> Void

        var body: some View {
            switch style {
            case .descriptor(let includesBody):
                Probe(descriptor: place.scope.fetchDescriptor(isPinned: false, includesBody: includesBody), record: record)
            case .filterAndSort:
                OldProbe(scope: place.scope, record: record)
            }
        }
    }

    /// The form the list used before: a filter and a sort, not a descriptor.
    private struct OldProbe: View {
        @Query private var notes: [Note]
        let record: ([String]) -> Void

        init(scope: NoteScope, record: @escaping ([String]) -> Void) {
            _notes = Query(filter: scope.predicate(isPinned: false), sort: scope.sortDescriptors)
            self.record = record
        }

        var body: some View {
            let titles = notes.map(\.title)
            let _ = record(titles)
            Color.clear.frame(width: 10, height: 10)
        }
    }

    @Test(arguments: [Style.descriptor(includesBody: false), .descriptor(includesBody: true), .filterAndSort])
    func aLiveQueryFollowsAChangeOfPlace(style: Style) async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        library.createNote(body: "Kept\ntext")
        let gone = library.createNote(body: "Gone\ntext")
        let alsoGone = library.createNote(body: "Also gone\ntext")
        library.trash(gone)
        library.trash(alsoGone)
        try container.mainContext.save()

        let place = Place(.all)
        var seen: [String] = []
        let host = NSHostingView(rootView: Switcher(place: place, style: style) { seen = $0 }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen == ["Kept"], "\(style)")

        place.scope = .trash
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.sorted() == ["Also gone", "Gone"], "\(style)")
        window.contentView = nil
    }

    /// The rows the list really draws, counted in its table. Zero while the counter beside Recently Deleted says 2.
    private func tableRows(in view: NSView) -> [Int] {
        var counts: [Int] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { counts.append(table.numberOfRows) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return counts
    }

    @Observable final class RowSelection {
        var id: UUID?
    }

    @Test func insertingANoteMeasuresItsFullRowWithoutResizing() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        let selection = RowSelection()
        let host = NSHostingView(rootView: NavigationSplitView {
            Text("Folders")
        } content: {
            NoteListView(scope: .all, selectedNoteID: Binding(get: { selection.id }, set: { selection.id = $0 }))
        } detail: {
            if let id = selection.id {
                NoteDetailView(id: id)
            } else {
                Text("Select a Note")
            }
        }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        let note = library.createNote()
        try container.mainContext.save()
        selection.id = note.id
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()

        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let pictureID = UUID()
        try attachPicture(id: pictureID, to: note, in: container.mainContext)
        note.setBody("![images](attachment://\(pictureID.uuidString))")
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()

        let list = try #require(table(in: host))
        let noteRow = list.selectedRow >= 0 ? list.selectedRow : list.numberOfRows - 1
        #expect(noteRow >= 1)
        let initialHeight = list.rect(ofRow: noteRow).height
        #expect(initialHeight >= NoteThumbnail.side,
                "The image must fit on the first update")
        window.setContentSize(NSSize(width: 940, height: 400))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(list.rect(ofRow: noteRow).height == initialHeight,
                "Resizing must not be necessary to correct a newly attached image's row height")
    }

    @Test(arguments: [NoteScope.all, .trash])
    func theListDrawsRowsForItsScope(scope: NoteScope) async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        library.createNote(body: "Kept\ntext")
        let gone = library.createNote(body: "Gone\ntext")
        let alsoGone = library.createNote(body: "Also gone\ntext")
        library.trash(gone)
        library.trash(alsoGone)
        try container.mainContext.save()

        let host = NSHostingView(rootView: NavigationStack { NoteListView(scope: scope, selectedNoteID: .constant(nil)) }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()

        // Recently Deleted has its retention notice, a date heading, and two deleted notes.
        // All Notes has a date heading and one note; there is no synthetic section spacer.
        let expected = scope == .trash ? 4 : 2
        let rows = tableRows(in: host)
        #expect(rows.contains(expected), "\(scope): table rows \(rows), expected \(expected)")

        window.contentView = nil
    }

    /// The list as the window uses it: one list view that is told another place when the sidebar selection changes.
    private struct ListFollowingPlace: View {
        let place: Place
        var body: some View {
            NavigationStack { NoteListView(scope: place.scope, selectedNoteID: .constant(nil)) }
        }
    }

    @Test func theListFollowsTheSidebarFromAllNotesToRecentlyDeleted() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        library.createNote(body: "Kept\ntext")
        let gone = library.createNote(body: "Gone\ntext")
        let alsoGone = library.createNote(body: "Also gone\ntext")
        library.trash(gone)
        library.trash(alsoGone)
        try container.mainContext.save()

        let place = Place(.all)
        let host = NSHostingView(rootView: ListFollowingPlace(place: place).modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(tableRows(in: host).contains(2), "All Notes: \(tableRows(in: host))")

        place.scope = .trash
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        #expect(tableRows(in: host).contains(4), "Recently Deleted after All Notes: \(tableRows(in: host))")
        window.contentView = nil
    }

    private func allTables(in view: NSView) -> [NSTableView] {
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return tables
    }

    /// Choosing a row in the sidebar must select the place that row stands for. Recently Deleted once left the selection
    /// alone, so the window stayed where it was.
    @Test func eachSidebarRowSetsItsOwnSelection() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        let folder = try library.createFolder(named: "Hello")
        let tagged = library.createNote(body: "Tagged\ntext")
        try library.addTag(named: "Code", to: tagged)
        let tag = try #require(tagged.tags?.first)
        let gone = library.createNote(body: "Gone\ntext")
        library.trash(gone)
        try container.mainContext.save()

        // Starts on Recently Deleted, so that choosing All Notes first is a real change of row.
        var selection: NoteScope? = .trash
        let binding = Binding<NoteScope?>(get: { selection }, set: { selection = $0 })
        let host = NSHostingView(rootView: NavigationStack { SidebarView(selection: binding, asksNewFolder: .constant(false)) }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))

        let sidebar = try #require(allTables(in: host).first)
        // The rows: a hidden header, All Notes, Unfiled, the Folders header, Hello, the Tags header, Code, a hidden header,
        // Recently Deleted.
        let expected: [(row: Int, scope: NoteScope)] = [
            (1, .all), (2, .unfiled), (4, .folder(folder.id)), (6, .tag(tag.id)), (8, .trash),
        ]
        #expect(sidebar.numberOfRows == 9, "rows: \(sidebar.numberOfRows)")
        for (row, scope) in expected {
            selection = nil
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(selection == scope, "row \(row) selected \(selection.map(String.init(describing:)) ?? "nothing"), expected \(scope)")
        }
        window.contentView = nil
    }

    /// Recently Deleted is always listed, with or without deleted notes, and stays selected when its last note is restored.
    @Test func recentlyDeletedStaysListedAndSelectedWhenEmpty() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        try container.mainContext.save()

        var selection: NoteScope? = .all
        let binding = Binding<NoteScope?>(get: { selection }, set: { selection = $0 })
        let host = NSHostingView(rootView: NavigationStack {
            SidebarView(selection: binding, asksNewFolder: .constant(false))
        }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(allTables(in: host).first)
        let initialRows = table.numberOfRows

        let note = library.createNote(body: "Deleted note")
        library.trash(note)
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == initialRows)

        selection = .trash
        library.restore(note)
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == initialRows)
        #expect(selection == .trash)
    }

    /// A folder with subfolders sits in a disclosure group; choosing it must still select it.
    @Test func aFolderWithSubfoldersSelectsItself() async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        let parent = try library.createFolder(named: "Parent")
        try library.createFolder(named: "Child", in: parent)
        try container.mainContext.save()

        var selection: NoteScope? = .trash
        let binding = Binding<NoteScope?>(get: { selection }, set: { selection = $0 })
        let host = NSHostingView(rootView: NavigationStack { SidebarView(selection: binding, asksNewFolder: .constant(false)) }.modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))

        let sidebar = try #require(allTables(in: host).first)
        // The hidden header, All Notes, Unfiled, Folders, Parent, a hidden header, and Recently Deleted.
        #expect(sidebar.numberOfRows == 7, "rows: \(sidebar.numberOfRows)")
        selection = nil
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(selection == .folder(parent.id), "Parent selected \(selection.map(String.init(describing:)) ?? "nothing")")
        window.contentView = nil
    }

    @Observable
    final class OpenNote {
        var id: UUID?
    }

    private struct ListWithOpenNote: View {
        let open: OpenNote
        var body: some View {
            NavigationStack {
                NoteListView(scope: .all, selectedNoteID: Binding(get: { open.id }, set: { open.id = $0 }))
            }
        }
    }

    /// Shows All Notes and returns the height of its one note's row. The note exists when the list is first drawn, or is
    /// created while the list is showing; it can be opened (selected, as when it is being edited); and it can be changed
    /// afterwards.
    /// A tall picture, as PNG data, so a thumbnail has something real to load.
    private func tallPicture() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 400).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Links a real picture to `note` under `id`, the one its Markdown names.
    private func attachPicture(id: UUID, to note: Note, in context: ModelContext) throws {
        let attachment = Attachment(id: id, fileName: "images.png", typeIdentifier: "public.png", data: try tallPicture())
        attachment.pixelWidth = 200
        attachment.pixelHeight = 400
        attachment.note = note
        context.insert(attachment)
    }

    private func noteRowHeight(
        start: String,
        thenChangeTo changed: String? = nil,
        createdWhileShown: Bool = false,
        opened: Bool = false,
        pictureID: UUID? = nil
    ) async throws -> CGFloat {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        let open = OpenNote()
        var note: Note?
        if !createdWhileShown {
            note = library.createNote(body: start)
            if let pictureID, start.contains(pictureID.uuidString), let note { try attachPicture(id: pictureID, to: note, in: container.mainContext) }
            try container.mainContext.save()
            if opened { open.id = note?.id }
        }

        let host = NSHostingView(rootView: ListWithOpenNote(open: open).modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))

        if createdWhileShown {
            note = library.createNote(body: start)
            try container.mainContext.save()
            if opened { open.id = note?.id }
            try await Task.sleep(for: .milliseconds(700))
        }
        if let changed, let note {
            if let pictureID, changed.contains(pictureID.uuidString) { try attachPicture(id: pictureID, to: note, in: container.mainContext) }
            note.setBody(changed)
            try container.mainContext.save()
            try await Task.sleep(for: .milliseconds(1200))
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(allTables(in: host).first)
        let height = table.rect(ofRow: table.numberOfRows - 1).height
        window.contentView = nil
        return height
    }

    /// Adding a picture must grow an existing row to the same intrinsic height as a row
    /// first displayed with that picture. Plain text rows can remain shorter.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func rowHeightFollowsContentWhenAPictureIsAttached(createdWhileShown: Bool, opened: Bool) async throws {
        let pictureID = UUID()
        let picture = "![images](attachment://\(pictureID.uuidString))"
        let drawnWithPicture = try await noteRowHeight(start: picture, pictureID: pictureID)
        let withoutPicture = try await noteRowHeight(start: "images")
        let changedToPicture = try await noteRowHeight(
            start: "images", thenChangeTo: picture, createdWhileShown: createdWhileShown, opened: opened, pictureID: pictureID
        )

        #expect(drawnWithPicture >= NoteThumbnail.side)
        #expect(drawnWithPicture > withoutPicture, "Image rows should grow beyond the text-only row height")
        #expect(
            changedToPicture == drawnWithPicture,
            "created while shown: \(createdWhileShown), opened: \(opened): attached later \(changedToPicture), present initially \(drawnWithPicture)"
        )
    }

    @Test(arguments: [true, false])
    func aLiveQueryLoadsRecentlyDeletedNotes(includesBody: Bool) async throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let library = Library(context: container.mainContext)
        library.createNote(body: "Kept\ntext")
        let gone = library.createNote(body: "Gone\ntext")
        let alsoGone = library.createNote(body: "Also gone\ntext")
        library.trash(gone)
        library.trash(alsoGone)
        try container.mainContext.save()

        let descriptor = NoteScope.trash.fetchDescriptor(isPinned: false, includesBody: includesBody)
        let titles = try await titlesLoaded(by: descriptor, in: container)
        #expect(titles.sorted() == ["Also gone", "Gone"], "includesBody: \(includesBody)")
    }
}
#endif
