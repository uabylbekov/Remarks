import SwiftUI
import NotesCore

/// A Markdown table drawn as a grid, in the way Bear shows one: cells you edit in place, a row of controls for adding
/// rows and columns before or after the cell you are in, and a horizontal scroll when the table is wider than the note.
///
/// The view owns no data. It shows `table`, and every change goes out through `onChange` as a whole new table, which
/// the editor writes back into the note's text. Rows are one line tall and columns have fixed widths worked out from
/// their text, so the height is known before the view is laid out (see `height(for:)`).
struct TableGridView: View {
    let table: MarkdownTable
    let onChange: (MarkdownTable) -> Void

    private struct CellID: Hashable {
        /// -1 is the header row.
        let row: Int
        let column: Int
    }

    @FocusState private var focus: CellID?

    // MARK: Metrics

    static let rowHeight: CGFloat = 34
    static let controlsHeight: CGFloat = 36
    private static let minimumColumnWidth: CGFloat = 80
    private static let maximumColumnWidth: CGFloat = 320

    /// The room the grid needs: every row, and the bar of controls under them.
    static func height(for table: MarkdownTable) -> CGFloat {
        CGFloat(table.rows.count + 1) * rowHeight + controlsHeight
    }

    private func width(ofColumn column: Int) -> CGFloat {
        let longest = ([table.header[column]] + table.rows.map { $0[column] }).map(\.count).max() ?? 0
        return min(Self.maximumColumnWidth, max(Self.minimumColumnWidth, CGFloat(longest) * 9 + 28))
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                grid
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                    .clipShape(.rect(cornerRadius: 8))
            }
            .scrollIndicators(.automatic)
            controls
        }
        .frame(height: Self.height(for: table), alignment: .top)
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
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                    .gridCellColumns(table.columnCount)
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
            }
        }
    }

    // MARK: Cells

    private func text(row: Int, column: Int) -> String {
        row < 0 ? table.header[column] : table.rows[row][column]
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
        let binding = Binding(get: { text(row: row, column: column) }, set: { set($0, row: row, column: column) })

        return ZStack {
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .focused($focus, equals: id)
                .multilineTextAlignment(Self.textAlignment(alignment))
                .opacity(isFocused ? 1 : 0)
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
        .padding(.horizontal, 10)
        .frame(width: width(ofColumn: column), height: Self.rowHeight)
        .overlay(alignment: .trailing) {
            if column < table.columnCount - 1 { Divider() }
        }
        .contentShape(.rect)
        .onTapGesture { focus = id }
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

    // MARK: Controls

    /// The row and column the controls act on: the cell being edited, or the last cell when none is.
    private var current: CellID {
        focus ?? CellID(row: table.rows.count - 1, column: table.columnCount - 1)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button("Column Before", systemImage: "arrow.left.to.line") { edit { $0.insertColumn(at: current.column) } }
            Button("Column After", systemImage: "arrow.right.to.line") { edit { $0.insertColumn(at: current.column + 1) } }
            Divider().frame(height: 16)
            Button("Row Above", systemImage: "arrow.up.to.line") { edit { $0.insertRow(at: max(0, current.row)) } }
            Button("Row Below", systemImage: "arrow.down.to.line") { edit { $0.insertRow(at: current.row + 1) } }
            Spacer()
            Menu("Delete", systemImage: "trash") {
                deleteButtons(row: current.row, column: current.column)
            }
            .menuIndicator(.hidden)
            .disabled(table.columnCount == 1 && current.row < 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(height: Self.controlsHeight)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func menu(row: Int, column: Int) -> some View {
        Button("Insert Row Above", systemImage: "arrow.up.to.line") { edit { $0.insertRow(at: max(0, row)) } }
            .disabled(row < 0 && false)
        Button("Insert Row Below", systemImage: "arrow.down.to.line") { edit { $0.insertRow(at: row + 1) } }
        Button("Insert Column Before", systemImage: "arrow.left.to.line") { edit { $0.insertColumn(at: column) } }
        Button("Insert Column After", systemImage: "arrow.right.to.line") { edit { $0.insertColumn(at: column + 1) } }
        Divider()
        deleteButtons(row: row, column: column)
    }

    @ViewBuilder
    private func deleteButtons(row: Int, column: Int) -> some View {
        if row >= 0 {
            Button("Delete Row", systemImage: "trash", role: .destructive) { edit { $0.deleteRow(at: row) } }
        }
        Button("Delete Column", systemImage: "trash", role: .destructive) { edit { $0.deleteColumn(at: column) } }
            .disabled(table.columnCount == 1)
    }

    private func edit(_ change: (inout MarkdownTable) -> Void) {
        var changed = table
        change(&changed)
        if changed != table { onChange(changed) }
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
    TableGridView(table: table) { table = $0 }
        .padding()
        .frame(width: 420)
}
