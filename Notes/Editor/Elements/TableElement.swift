import SwiftUI
import NotesCore

/// A complete Markdown table reserves native layout space for its hosted SwiftUI grid.
/// Its first source row reserves the grid’s metrics. Incomplete tables remain editable text in the code font.
/// Neither depends on the caret.
struct TableElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        if let table = services.tableModel(for: line.block) {
            styleGridRow(paragraph, isFirst: line.range.location == line.block.range.location, table: table, services: services)
        } else {
            styleTextRow(paragraph, range: line.range, services: services)
        }
        return true
    }

    // MARK: Grid

    /// A native attachment reserves the first row's full height, including at document start.
    /// Remaining source rows stay collapsed; their UTF-16 positions remain available to editing and undo.
    private func styleGridRow(_ paragraph: NSMutableAttributedString, isFirst: Bool, table: MarkdownTable, services: ElementServices) {
        let full = NSRange(location: 0, length: paragraph.length)
        let style = NSMutableParagraphStyle()
        let height = TableGridView.height(for: table)
        style.minimumLineHeight = isFirst ? height : 0.01
        style.maximumLineHeight = isFirst ? height : 0.01
        style.paragraphSpacingBefore = isFirst ? LivePreviewController.cardMargin : 0
        style.paragraphSpacing = isFirst ? LivePreviewController.cardMargin : 0
        style.lineBreakMode = .byClipping
        paragraph.addAttributes([
            .paragraphStyle: style,
            .font: EditorFont.systemFont(ofSize: 0.01),
            .foregroundColor: EditorColor.clear,
        ], range: full)
        if isFirst, paragraph.length > 0 {
            let width = TableGridView.width(for: table, in: services.textContainerWidth,
                                            padding: services.linePadding, gutter: LivePreviewController.tableGutter)
            let anchor = NSRange(location: 0, length: 1)
            paragraph.replaceCharacters(in: anchor, with: "\u{FFFC}")
            let size = CGSize(width: width + LivePreviewController.tableGutter, height: height)
            paragraph.addAttribute(.attachment, value: AttachmentDrawing.placeholder(size: size), range: anchor)
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
        // Top and bottom margins come from `CodeBlockFragment` via `blockMarkerKey`, matching code blocks.
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
        if !isSeparator { _ = InlineStyler.style(paragraph, selection: NSRange(location: 0, length: paragraph.length)) }
    }
}
