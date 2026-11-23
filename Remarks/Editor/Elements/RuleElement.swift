import SwiftUI
import RemarksCore

/// Horizontal-rule syntax remains visible and editable like other Markdown markers.
struct RuleElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        InlineStyler.dimMarker(paragraph, range: NSRange(location: 0, length: paragraph.length))
        return true
    }
}
