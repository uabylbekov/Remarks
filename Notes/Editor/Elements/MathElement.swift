import SwiftUI
import NotesCore

/// Display-math source is literal while editing or when a renderer rejects it.
struct MathElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttributes([.font: EditorTheme.codeFont,
                                 .foregroundColor: EditorTheme.codeTextColor,
                                 .paragraphStyle: EditorTheme.bodyParagraphStyle], range: full)
        if case .math(let math) = line.block.kind,
           line.range.location == math.open.location || line.range.location == math.close.location {
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: full)
        }
        return true
    }
}
