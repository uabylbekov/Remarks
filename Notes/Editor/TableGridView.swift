import SwiftUI
import NotesCore

/// A Markdown table drawn as a grid, in the way Bear shows one: cells you edit in place, a menu on each cell for adding
/// and deleting rows and columns, and a horizontal scroll when the table is wider than the note.
///
/// The view owns no data. It shows `table`, and every change goes out through `onChange` as a whole new table, which
/// the editor writes back into the note's text. Rows are one line tall and columns have fixed widths worked out from
/// their text, so the height is known before the view is laid out (see `height(for:)`).
/// Which way the caret leaves a table that is being edited with the keyboard.
enum TableExit {
    case before, after
}

/// Asks a table to put the caret in a cell. A new `token` is a new request, so asking twice for the same cell works.
struct TableFocusRequest: Equatable {
    let token: Int
    /// -1 is the header row.
    let row: Int
    let column: Int
}

struct TableGridView: View {
    let table: MarkdownTable
    var focusRequest: TableFocusRequest?
    let onChange: (MarkdownTable) -> Void
    let onDelete: () -> Void
    /// The caret left the table with an arrow key, Tab, or Return, past its first or last cell.
    let onExit: (TableExit) -> Void
    /// Focused cell bounds in the hosting view, for the native editor’s vertical scrolling.
    var onFocusBounds: ((CGRect?) -> Void)? = nil

    private struct CellID: Hashable {
        /// -1 is the header row.
        let row: Int
        let column: Int
    }

    @FocusState private var focus: CellID?
    /// The cell that last had focus. Its menu button stays while the menu is open, which takes focus from the field.
    @State private var lastFocus: CellID?
    @State private var hovered: CellID?
    /// Keep in-progress spaces and marked text independent of Markdown's normalized cells.
    @State private var drafts: [CellID: String] = [:]

    // MARK: Metrics

    static var rowHeight: CGFloat {
        let font = EditorTheme.proseFont
        return max(34, ceil(font.ascender - font.descender + font.leading) + 16)
    }
    private static let cellHorizontalPadding: CGFloat = 10
    private static let menuWidth: CGFloat = 20
    private static let minimumColumnWidth: CGFloat = 80
    private static let maximumColumnWidth: CGFloat = 320

    /// The room the grid needs: the header and every row.
    static func height(for table: MarkdownTable) -> CGFloat {
        CGFloat(table.rows.count + 1) * rowHeight
    }

    private func width(ofColumn column: Int) -> CGFloat {
        Self.width(ofColumn: column, in: table)
    }

    static func width(ofColumn column: Int, in table: MarkdownTable) -> CGFloat {
        let values = [table.header[column]] + table.rows.map { $0[column] }
        let textWidth = values.map { NSAttributedString(string: $0, attributes: [.font: EditorTheme.proseFont]).size().width }.max() ?? 0
        return min(maximumColumnWidth, max(minimumColumnWidth, ceil(textWidth) + 2 * cellHorizontalPadding + menuWidth + 8))
    }

    /// How wide the grid is when it is not squeezed: all its columns side by side.
    static func contentWidth(for table: MarkdownTable) -> CGFloat {
        (0..<table.columnCount).reduce(0) { $0 + width(ofColumn: $1, in: table) }
    }

    /// The width the grid takes in a text container `containerWidth` wide: as wide as its columns, or the room that is
    /// left of the line when they do not fit, which makes it scroll. What is beside it belongs to the text, so a click
    /// there puts the caret at the end of the table.
    static func width(for table: MarkdownTable, in containerWidth: CGFloat, padding: CGFloat, gutter: CGFloat) -> CGFloat {
        max(0, min(contentWidth(for: table), containerWidth - 2 * padding - gutter))
    }

    // MARK: Body

    var body: some View {
        ScrollView(.horizontal) {
            grid
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                .clipShape(.rect(cornerRadius: 8))
        }
        .coordinateSpace(name: "markdownTable")
        .scrollIndicators(.automatic)
        .frame(height: Self.height(for: table), alignment: .top)
        .onChange(of: focus) { old, new in
            if let old { drafts.removeValue(forKey: old) }
            if let new { lastFocus = new }
            else { onFocusBounds?(nil) }
        }
        .onChange(of: table) { _, _ in
            // Keep local spacing during typing, but let undo and external changes replace stale drafts.
            for (id, draft) in drafts {
                var expected = table
                if id.row < 0 { expected.setHeader(draft, column: id.column) }
                else { expected.setCell(draft, row: id.row, column: id.column) }
                if expected != table { drafts.removeValue(forKey: id) }
            }
        }
        .onChange(of: table.rows.count) { _, _ in validateFocus() }
        .onChange(of: table.columnCount) { _, _ in validateFocus() }
        .onChange(of: focusRequest, initial: true) { _, request in
            guard let request else { return }
            focus = CellID(row: min(max(-1, request.row), table.rows.count - 1), column: min(max(0, request.column), table.columnCount - 1))
        }
        .font(Font(EditorTheme.proseFont))
    }

    private var grid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(row: -1, column: column)
                }
            }
            .background(.fill.tertiary)
            ForEach(0..<table.rows.count, id: \.self) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    // MARK: Cells

    private func text(row: Int, column: Int) -> String {
        guard table.header.indices.contains(column) else { return "" }
        if row < 0 { return table.header[column] }
        guard table.rows.indices.contains(row) else { return "" }
        return table.rows[row][column]
    }

    private func set(_ value: String, row: Int, column: Int) {
        var changed = table
        if row < 0 { changed.setHeader(value, column: column) } else { changed.setCell(value, row: row, column: column) }
        onChange(changed)
    }

    private func cell(row: Int, column: Int) -> some View {
        let id = CellID(row: row, column: column)
        let isFocused = focus == id
        let alignment = table.alignments[column]
        let binding = Binding(
            get: { drafts[id] ?? text(row: row, column: column) },
            set: { value in
                drafts[id] = value
                set(value, row: row, column: column)
            }
        )

        return ZStack {
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .focused($focus, equals: id)
                .multilineTextAlignment(Self.textAlignment(alignment))
                .opacity(isFocused ? 1 : 0)
                .onKeyPress(.upArrow) { move(from: id, rowDelta: -1); return .handled }
                .onKeyPress(.downArrow) { move(from: id, rowDelta: 1); return .handled }
                .onKeyPress(keys: [.tab]) { press in tab(from: id, backward: press.modifiers.contains(.shift)); return .handled }
                .onSubmit { move(from: id, rowDelta: 1) }
            if !isFocused {
                // At rest a cell shows its Markdown rendered (bold, italic, code, links), and the raw text while edited.
                Text(Self.rendered(text(row: row, column: column)))
                    .fontWeight(row < 0 ? .semibold : .regular)
                    .multilineTextAlignment(Self.textAlignment(alignment))
                    .frame(maxWidth: .infinity, alignment: Self.frameAlignment(alignment))
                    .allowsHitTesting(false)
            }
        }
        .lineLimit(1)
        // Reserve the menu's room in both states so hovering never covers text or moves the caret.
        .padding(.trailing, Self.menuWidth)
        .padding(.horizontal, Self.cellHorizontalPadding)
        .frame(width: width(ofColumn: column), height: Self.rowHeight)
        .overlay(alignment: .trailing) {
            if column < table.columnCount - 1 {
                Rectangle().fill(.separator).frame(width: 1)
            }
        }
        .modifier(FocusedTableCellBounds(isFocused: isFocused) { onFocusBounds?($0) })
        .contentShape(.rect)
        .onTapGesture { focus = id }
        .overlay(alignment: .trailing) {
            let showsMenu = isFocused || lastFocus == id || hovered == id
            Menu {
                menu(row: row, column: column)
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 6)
            .accessibilityLabel("Cell Actions")
            .opacity(showsMenu ? 1 : 0)
            .allowsHitTesting(showsMenu)
            .accessibilityHidden(!showsMenu)
        }
        .onHover { hovering in hovered = hovering ? id : (hovered == id ? nil : hovered) }
        .contextMenu { menu(row: row, column: column) }
    }

    private static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private static func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private static func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    // MARK: Keyboard

    /// Moves the caret to the cell above or below, or out of the table past its first or last row.
    private func move(from id: CellID, rowDelta: Int) {
        let row = id.row + rowDelta
        if row < -1 {
            onExit(.before)
        } else if row >= table.rows.count {
            onExit(.after)
        } else {
            focus = CellID(row: row, column: id.column)
        }
    }

    /// Tab goes to the next cell, along the row and then down, and Shift-Tab to the one before.
    private func tab(from id: CellID, backward: Bool) {
        var row = id.row
        var column = id.column + (backward ? -1 : 1)
        if column < 0 {
            column = table.columnCount - 1
            row -= 1
        } else if column >= table.columnCount {
            column = 0
            row += 1
        }
        if row < -1 {
            onExit(.before)
        } else if row >= table.rows.count {
            onExit(.after)
        } else {
            focus = CellID(row: row, column: column)
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menu(row: Int, column: Int) -> some View {
        Button("Insert Row Above", systemImage: "arrow.up.to.line") { edit { $0.insertRow(at: max(0, row)) } }
        Button("Insert Row Below", systemImage: "arrow.down.to.line") { edit { $0.insertRow(at: row + 1) } }
        Button("Insert Column Before", systemImage: "arrow.left.to.line") { edit { $0.insertColumn(at: column) } }
        Button("Insert Column After", systemImage: "arrow.right.to.line") { edit { $0.insertColumn(at: column + 1) } }
        Divider()
        deleteButtons(row: row, column: column)
        Button("Delete Table", systemImage: "trash", role: .destructive, action: onDelete)
    }

    @ViewBuilder
    private func deleteButtons(row: Int, column: Int) -> some View {
        if row >= 0 {
            Button("Delete Row", systemImage: "trash", role: .destructive) { edit { $0.deleteRow(at: row) } }
        }
        Button("Delete Column", systemImage: "trash", role: .destructive) { edit { $0.deleteColumn(at: column) } }
            .disabled(table.columnCount == 1)
    }

    private func validateFocus() {
        drafts.removeAll()
        if let current = focus {
            focus = CellID(row: min(current.row, table.rows.count - 1),
                           column: min(current.column, table.columnCount - 1))
        }
        lastFocus = focus
        hovered = nil
    }

    private func edit(_ change: (inout MarkdownTable) -> Void) {
        drafts.removeAll()
        var changed = table
        change(&changed)
        if changed != table { onChange(changed) }
    }
}

/// Measuring in the host’s local space avoids feeding the parent’s scrolling back into focus updates.
private struct FocusedTableCellBounds: ViewModifier {
    let isFocused: Bool
    let report: (CGRect) -> Void
    @State private var bounds: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("markdownTable"))
            } action: { value in
                bounds = value
                if isFocused { report(value) }
            }
            .onChange(of: isFocused) { _, focused in
                if focused, !bounds.isEmpty { report(bounds) }
            }
    }
}

#Preview("Table") {
    @Previewable @State var table = MarkdownTable(parsing: """
    | Item | Qty | Notes |
    | :-- | --: | --- |
    | **Apples** | 3 | fresh, `local` |
    | Milk | 1 | _skim_ |
    | A very long cell that makes this column wider than the others by a lot | 2 | |
    """)!
    TableGridView(table: table, onChange: { table = $0 }, onDelete: {}, onExit: { _ in })
        .padding()
        .frame(width: 420)
}
