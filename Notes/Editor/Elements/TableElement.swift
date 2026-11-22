import SwiftUI
import NotesCore

/// A GitHub Markdown table. A complete one (it has a separator row) is a grid of editable cells, drawn by `TableGridView`
/// over room that its first row holds (see `TableOverlay`). One without a separator row is shown as text in the code font.
/// Neither depends on the caret.
struct TableElement: MarkdownElement {
    var readsInline: Bool { false }

    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        if !services.showsMarkdown, let table = services.tableModel(for: line.block) {
            styleGridRow(paragraph, isFirst: line.range.location == line.block.range.location, table: table, services: services)
        } else {
            styleTextRow(paragraph, range: line.range, services: services)
        }
        return true
    }

    // MARK: Grid

    /// The first row of a grid holds the room for the table view, and the rows after it take none. Their text is hidden,
    /// and what is stored never changes. The room is paragraph spacing before the first row, not line height, so every
    /// line stays a hair high and there is no gap between the lines of the table: a selection over the table is as high
    /// as its lines. A gap between selected lines is painted as a band, which is what a selection that ended inside the
    /// room would have been, the size of the grid. The text of the first row is right-aligned, so the end of the row is beside the grid. That is where the caret
    /// rests "at the end of the table". The text view's own caret there is too small to see, and `TableOverlay` draws a
    /// caret as tall as the table. The height depends only on the table, never on the caret.
    private func styleGridRow(_ paragraph: NSMutableAttributedString, isFirst: Bool, table: MarkdownTable, services: ElementServices) {
        let full = NSRange(location: 0, length: paragraph.length)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.paragraphSpacingBefore = isFirst ? TableGridView.height(for: table) + 2 * LivePreviewController.cardMargin : 0
        style.paragraphSpacing = 0
        style.alignment = .right
        // The text ends just beside the grid, so the caret at the end of the table is drawn there.
        let gridWidth = TableGridView.width(
            for: table, in: services.textContainerWidth, padding: services.linePadding, gutter: LivePreviewController.tableGutter
        )
        style.tailIndent = gridWidth + LivePreviewController.tableGutter / 2
        style.lineBreakMode = .byClipping
        paragraph.addAttributes([
            .paragraphStyle: style,
            .font: EditorFont.systemFont(ofSize: 1),
            .foregroundColor: EditorColor.clear,
        ], range: full)
        // A click puts the caret at the nearest place in the row's text. Wide spacing after its first character puts the
        // start of the text well under the grid, so every click beside the grid is nearer the end, which is the end of
        // the table.
        if isFirst, paragraph.length > 0 {
            paragraph.addAttribute(.kern, value: 80, range: NSRange(location: 0, length: 1))
        }
    }

    // MARK: Text

    /// A table row is shown in the code font on the same card as code, with the same line spacing. Inline styles are
    /// shown and their marks dimmed. The header row (the one above the separator) is bold, and the separator row and the
    /// pipes are dim.
    private func styleTextRow(_ paragraph: NSMutableAttributedString, range: NSRange, services: ElementServices) {
        let text = paragraph.string
        let content = NSRange(location: 0, length: (text as NSString).length - (text.hasSuffix("\n") ? 1 : 0))
        guard content.length > 0 else { return }

        let isSeparator = MarkdownEditing.isTableSeparator(text)
        let isHeader = !isSeparator && services.nextLineIsTableSeparator(after: range)
        let layout = services.tableLayout(forRowAt: range)
        let base = layout.scale < 1 ? EditorTheme.codeFont(scale: layout.scale) : EditorTheme.codeFont
        let full = NSRange(location: 0, length: paragraph.length)

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = LivePreviewController.codeInset
        style.headIndent = LivePreviewController.codeInset
        style.tailIndent = -LivePreviewController.codeInset
        // The card's padding and margin sit above the first row and below the last, as around a block of code.
        style.paragraphSpacingBefore = range.location == layout.run.location
            ? LivePreviewController.cardMargin + LivePreviewController.cardPadding : 0
        style.paragraphSpacing = NSMaxRange(range) == NSMaxRange(layout.run)
            ? LivePreviewController.cardPadding + LivePreviewController.cardMargin : 0
        style.lineBreakMode = .byClipping
        paragraph.addAttributes([
            .font: isHeader ? EditorTheme.traited(base, bold: true) : base,
            .foregroundColor: isSeparator ? EditorTheme.dimColor : EditorTheme.codeTextColor,
            .paragraphStyle: style,
            LivePreviewController.blockMarkerKey: 1,
        ], range: full)

        // The pipes recede, so the cells read first.
        for index in MarkdownEditing.tablePipeOffsets(in: text as NSString) {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: NSRange(location: index, length: 1))
        }
        // Marks keep the code font's width here, so the columns stay lined up.
        if !isSeparator { _ = InlineStyler.style(paragraph, hidesMarkers: false, shrinksMarkers: false) }
    }
}
