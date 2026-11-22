import SwiftUI
import NotesCore

/// Draws the bar beside a quote and the line of a horizontal rule. What it draws depends only on the line itself, so
/// moving the caret never changes anything around it.
final class DecorationFragment: NSTextLayoutFragment {
    private var kind: String? {
        guard let text = (textElement as? NSTextParagraph)?.attributedString, text.length > 0 else { return nil }
        return text.attribute(LivePreviewController.decorationKey, at: 0, effectiveRange: nil) as? String
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let left = point.x - layoutFragmentFrame.minX + padding
        context.saveGState()
        defer { context.restoreGState() }

        switch kind {
        case "quote":
            context.setFillColor(EditorColor.systemGray.withAlphaComponent(0.6).cgColor)
            // A little taller than the line, so the bars of neighboring quote lines meet.
            let bar = CGRect(x: left, y: point.y - 2, width: 3, height: layoutFragmentFrame.height + 4)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        case "rule":
            context.setStrokeColor(EditorColor.systemGray.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            let y = point.y + layoutFragmentFrame.height / 2
            context.move(to: CGPoint(x: left, y: y))
            context.addLine(to: CGPoint(x: left + max(0, containerWidth - 2 * padding), y: y))
            context.strokePath()
        default:
            break
        }
    }
}
