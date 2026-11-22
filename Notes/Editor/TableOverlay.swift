import SwiftUI
import NotesCore

#if canImport(UIKit)
import UIKit
typealias OverlayContainer = UIView
#else
import AppKit
typealias OverlayContainer = NSView

#endif

/// Puts a `TableGridView` over the room that the live preview reserves for each table, and keeps it there as the text
/// is laid out. The views belong to the text view, so they scroll with the text.
@MainActor
final class TableOverlay {
    #if canImport(UIKit)
    private typealias Host = UIHostingController<TableGridView>
    #else
    private typealias Host = NSHostingView<TableGridView>
    #endif

    private struct Placed {
        let host: Host
        var table: MarkdownTable
        var request: TableFocusRequest?
        var frame: CGRect
    }

    private weak var container: OverlayContainer?
    private weak var preview: LivePreviewController?
    /// Where the text container starts inside the text view.
    private let origin: () -> CGPoint
    private var placed: [UUID: Placed] = [:]
    private var updateScheduled = false
    /// The latest request to put the caret in a table's cell, by table. It stays until the table has its view.
    private var requests: [UUID: TableFocusRequest] = [:]
    private var requestCount = 0

    init(container: OverlayContainer, origin: @escaping () -> CGPoint) {
        self.container = container
        self.origin = origin
    }

    func connect(to preview: LivePreviewController?, apply: @escaping (TextEdit) -> Void, placeCaret: @escaping (NSRange) -> Void) {
        resetTables()
        self.preview = preview
        preview?.applyTableEdit = apply
        preview?.placeCaret = placeCaret
        preview?.onTablesChanged = { [weak self] in self?.scheduleUpdate() }
        preview?.onEnterTable = { [weak self] index, row, column in self?.focus(table: index, row: row, column: column) }
    }

    /// Puts the caret in a cell of a table.
    private func focus(table index: Int, row: Int, column: Int) {
        guard let id = preview?.tableID(at: index) else { return }
        requestCount += 1
        requests[id] = TableFocusRequest(token: requestCount, row: row, column: column)
        update()
    }

    /// The text view has just laid out. Tables are placed now, in the same pass as the text, so one never lags behind
    /// it when the text above it grows or shrinks, or when the table itself is removed.
    func layoutDidChange() {
        update()
    }

    /// For changes that do not come with a layout pass of their own. It waits a turn.
    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func resetTables() {
        for entry in placed.values { remove(entry.host) }
        placed.removeAll()
        requests.removeAll()
    }

    private func update() {
        guard let container, let preview else { return }
        let origin = origin()

        for item in preview.gridTables() {
            let frame = item.frame.offsetBy(dx: origin.x, dy: origin.y)
            let id = item.id
            let request = requests[id]
            let view = TableGridView(
                table: item.table,
                focusRequest: request,
                onChange: { [weak preview] table in
                    guard let preview, !preview.showsMarkdown, let index = preview.tableIndex(for: id) else { return }
                    preview.replaceTable(at: index, with: table)
                },
                onDelete: { [weak preview] in
                    guard let preview, !preview.showsMarkdown, let index = preview.tableIndex(for: id) else { return }
                    preview.deleteTable(at: index)
                },
                onExit: { [weak preview] exit in
                    guard let preview, !preview.showsMarkdown, let index = preview.tableIndex(for: id) else { return }
                    preview.exitTable(at: index, toward: exit)
                }
            )

            if var current = placed[id] {
                // The same view stays, so the cell being edited keeps its focus.
                if current.table != item.table || current.request != request {
                    setRootView(view, of: current.host)
                    current.table = item.table
                    current.request = request
                }
                if current.frame != frame {
                    setFrame(frame, of: current.host)
                    current.frame = frame
                }
                placed[id] = current
            } else {
                let host = makeHost(view, in: container)
                setFrame(frame, of: host)
                placed[id] = Placed(host: host, table: item.table, request: request, frame: frame)
            }
        }

        // Missing geometry during a resize is temporary, not a deleted table.
        for (id, entry) in placed where preview.showsMarkdown || preview.tableIndex(for: id) == nil {
            remove(entry.host)
            placed[id] = nil
            requests[id] = nil
        }
    }

    // MARK: Platform

    #if canImport(UIKit)
    private func makeHost(_ view: TableGridView, in container: UIView) -> Host {
        let host = UIHostingController(rootView: view)
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        // A hosting controller works best as a child of the screen's controller, so keyboard and focus follow it.
        var responder: UIResponder? = container
        while let next = responder?.next, !(responder is UIViewController) { responder = next }
        if let parent = responder as? UIViewController { parent.addChild(host) }
        container.addSubview(host.view)
        (responder as? UIViewController).map { host.didMove(toParent: $0) }
        return host
    }

    private func setRootView(_ view: TableGridView, of host: Host) { host.rootView = view }
    private func setFrame(_ frame: CGRect, of host: Host) { host.view.frame = frame }

    private func remove(_ host: Host) {
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }
    #else
    private func makeHost(_ view: TableGridView, in container: NSView) -> Host {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        container.addSubview(host)
        return host
    }

    private func setRootView(_ view: TableGridView, of host: Host) { host.rootView = view }
    private func setFrame(_ frame: CGRect, of host: Host) { host.frame = frame }
    private func remove(_ host: Host) { host.removeFromSuperview() }
    #endif
}
