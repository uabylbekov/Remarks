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
final class TableViewRegistry {
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
    var onCellFocusChanged: ((Bool) -> Void)?
    private var focusedCell: (id: UUID, bounds: CGRect)? {
        didSet {
            if (oldValue != nil) != (focusedCell != nil) { onCellFocusChanged?(focusedCell != nil) }
        }
    }
    private var viewportSize: CGSize = .zero
    private var requestCount = 0

    init(container: OverlayContainer) {
        self.container = container
        self.origin = { [weak container] in
            #if canImport(UIKit)
            guard let view = container as? UITextView else { return .zero }
            return CGPoint(x: view.textContainerInset.left, y: view.textContainerInset.top)
            #else
            return (container as? NSTextView)?.textContainerOrigin ?? .zero
            #endif
        }
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
        let size = container?.bounds.size ?? .zero
        let viewportChanged = size != viewportSize
        viewportSize = size
        update()
        if viewportChanged { revealFocusedCell() }
    }

    private func focusBoundsChanged(id: UUID, bounds: CGRect?) {
        if let bounds {
            focusedCell = (id, bounds)
            revealFocusedCell()
        } else if focusedCell?.id == id {
            focusedCell = nil
        }
    }

    private func revealFocusedCell() {
        guard let container, let focusedCell, let entry = placed[focusedCell.id] else { return }
        #if canImport(UIKit)
        guard let textView = container as? UITextView else { return }
        var rect = entry.host.view.convert(focusedCell.bounds, to: textView)
        #else
        var rect = entry.host.convert(focusedCell.bounds, to: container)
        #endif
        // The table owns horizontal scrolling; reveal only the cell’s vertical extent here.
        rect.origin.x = entry.frame.minX
        rect.size.width = entry.frame.width
        #if canImport(UIKit)
        rect = rect.insetBy(dx: 0, dy: -max(textView.textContainerInset.top, textView.textContainerInset.bottom))
        textView.scrollRectToVisible(rect, animated: false)
        #else
        container.scrollToVisible(rect)
        #endif
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
        focusedCell = nil
    }

    private func update() {
        guard let container, let preview else { return }
        let origin = origin()
        var focusedFrameChanged = false

        var laidOut: Set<UUID> = []
        for item in preview.gridTables() {
            let frame = item.frame.offsetBy(dx: origin.x, dy: origin.y)
            let id = item.id
            laidOut.insert(id)
            let request = requests[id]
            let view = TableGridView(
                table: item.table,
                focusRequest: request,
                onChange: { [weak preview] table in
                    guard let preview, let index = preview.tableIndex(for: id) else { return }
                    preview.replaceTable(at: index, with: table)
                },
                onDelete: { [weak preview] in
                    guard let preview, let index = preview.tableIndex(for: id) else { return }
                    preview.deleteTable(at: index)
                },
                onExit: { [weak preview] exit in
                    guard let preview, let index = preview.tableIndex(for: id) else { return }
                    preview.exitTable(at: index, toward: exit)
                },
                onFocusBounds: { [weak self] bounds in
                    self?.focusBoundsChanged(id: id, bounds: bounds)
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
                    if focusedCell?.id == id { focusedFrameChanged = true }
                    setFrame(frame, of: current.host)
                    current.frame = frame
                }
                setHidden(false, of: current.host)
                placed[id] = current
            } else {
                let host = makeHost(view, in: container)
                setFrame(frame, of: host)
                placed[id] = Placed(host: host, table: item.table, request: request, frame: frame)
            }
        }

        // A table the text view has not laid out has no position yet. This is a table pushed below what is on screen by an
        // edit above it, such as an attached picture. Its view would stay where it was, over whatever text is there now,
        // so it is hidden until the text view lays the table out, which it does as the table scrolls into view. A table
        // with a cell being edited stays: it is on screen, and hiding it would take the keyboard from the cell.
        for (id, entry) in placed where !laidOut.contains(id) && preview.tableIndex(for: id) != nil && focusedCell?.id != id {
            setHidden(true, of: entry.host)
        }

        // Missing geometry during a resize is temporary, not a deleted table.
        for (id, entry) in placed where preview.tableIndex(for: id) == nil {
            remove(entry.host)
            placed[id] = nil
            requests[id] = nil
            if focusedCell?.id == id { focusedCell = nil }
        }
        if focusedFrameChanged { revealFocusedCell() }
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
    private func setHidden(_ hidden: Bool, of host: Host) { if host.view.isHidden != hidden { host.view.isHidden = hidden } }

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
    private func setHidden(_ hidden: Bool, of host: Host) { if host.isHidden != hidden { host.isHidden = hidden } }
    private func remove(_ host: Host) { host.removeFromSuperview() }
    #endif
}
