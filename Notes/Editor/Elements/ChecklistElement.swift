import SwiftUI
import NotesCore

/// `- [ ] task` and `- [x] done`: a box in place of the mark, drawn by `ChecklistFragment`. The mark is hidden but keeps
/// its room, which is the room for the box, and it is the same whether or not the caret is on the line. Backspace at the
/// start of the text takes the checkbox away.
struct ChecklistElement: MarkdownElement {
    func style(_ paragraph: NSMutableAttributedString, line: ElementLine, services: ElementServices) -> Bool {
        guard case .checklist(let markPosition, let isChecked) = line.block.kind else { return false }
        let full = NSRange(location: 0, length: paragraph.length)
        let markRange = NSRange(location: markPosition.location - line.range.location, length: markPosition.length)

        let base = (paragraph.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont) ?? EditorTheme.proseFont
        #if os(iOS)
        // The size Apple Notes uses on iPhone: about 24 points beside body text, scaling with the font, so it is also a
        // target for a finger. It can be taller than its line, so the fragment draws outside the line (see below).
        let side = max(22, base.pointSize * 1.4)
        let hiddenWidth = side + 10
        #else
        let side = max(14, base.capHeight * 1.4)
        let hiddenWidth = side + 8
        #endif
        // The native glyph holds identical space for [ ], [x], and [] without measuring hidden text.
        // This is a display paragraph; source characters and UTF-16 offsets are preserved.
        InlineStyler.collapse(paragraph, range: markRange)
        let anchor = NSRange(location: markRange.location, length: 1)
        paragraph.replaceCharacters(in: anchor, with: "\u{FFFC}")
        paragraph.addAttributes([
            .attachment: AttachmentDrawing.placeholder(size: CGSize(width: hiddenWidth, height: base.capHeight)),
            .font: base,
        ], range: anchor)

        paragraph.addAttribute(LivePreviewController.checklistKey, value: isChecked ? 2 : 1, range: full)
        paragraph.addAttribute(LivePreviewController.checklistWidthKey, value: Double(hiddenWidth), range: full)
        InlineStyler.applyHangingIndent(paragraph, through: NSMaxRange(markRange))
        #if os(iOS)
        // Air between items, or each circle touches the one below. After the item, so a wrapped item keeps its lines close.
        if let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let spaced = style.mutableCopy() as? NSMutableParagraphStyle {
            spaced.paragraphSpacing = max(spaced.paragraphSpacing, 8)
            paragraph.addAttribute(.paragraphStyle, value: spaced.copy(), range: full)
        }
        #endif

        if isChecked {
            let content = NSRange(location: NSMaxRange(markRange), length: max(0, full.length - NSMaxRange(markRange)))
            paragraph.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            paragraph.addAttribute(.foregroundColor, value: EditorTheme.dimColor, range: content)
        }
        _ = InlineStyler.style(paragraph, hidesMarkers: true, shrinksMarkers: true)
        return true
    }

    /// The whole front of the line, indent included: the caret never rests there.
    func hiddenMarks(of block: MarkdownDocument.Block, line: NSRange, in source: NSString) -> [NSRange] {
        guard case .checklist(let mark, _) = block.kind else { return [] }
        return [NSRange(location: line.location, length: NSMaxRange(mark) - line.location)]
    }

    func prefixMark(of block: MarkdownDocument.Block, in source: NSString) -> NSRange? {
        if case .checklist(let mark, _) = block.kind { mark } else { nil }
    }
}

// MARK: - Drawing

/// Draws a round checkbox in the space of a checklist item's hidden `- [ ] ` mark.
final class ChecklistFragment: NSTextLayoutFragment {
    private func number(for key: NSAttributedString.Key) -> CGFloat {
        let value = (textElement as? NSTextParagraph)?.attributedString.attribute(key, at: 0, effectiveRange: nil) as? NSNumber
        return CGFloat(value?.doubleValue ?? 0)
    }

    /// One geometry for painting and interaction, measured in text-container coordinates.
    var checkboxBounds: CGRect {
        let hiddenWidth = number(for: LivePreviewController.checklistWidthKey)
        let line = textLineFragments.first
        let paragraph = (textElement as? NSTextParagraph)?.attributedString
        let marker = (paragraph?.string as NSString?)?.range(of: "\u{FFFC}").location ?? NSNotFound
        let markerX = marker != NSNotFound ? line?.locationForCharacter(at: marker).x ?? 0 : 0
        let lineHeight = line?.typographicBounds.height ?? layoutFragmentFrame.height
        #if os(iOS)
        let side = max(14, hiddenWidth - 10)
        #else
        let side = max(14, min(lineHeight * 0.9, hiddenWidth - 6))
        #endif
        let font = (textElement as? NSTextParagraph)?.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont
        let baseline = (line?.typographicBounds.minY ?? 0) + (line?.glyphOrigin.y ?? lineHeight)
        let center = font.map { baseline - $0.capHeight / 2 } ?? lineHeight / 2
        return CGRect(x: layoutFragmentFrame.minX + (line?.typographicBounds.minX ?? 0) + markerX,
                      y: layoutFragmentFrame.minY + center - side / 2, width: side, height: side)
    }

    /// The circle may be taller than its line, and would be cut off at the line's edge without this.
    override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        return super.renderingSurfaceBounds.union(
            checkboxBounds.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -2, dy: -2))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let isChecked = number(for: LivePreviewController.checklistKey) == 2
        let box = checkboxBounds.offsetBy(dx: point.x - layoutFragmentFrame.minX, dy: point.y - layoutFragmentFrame.minY)
        let side = box.width

        context.saveGState()
        // A circle, as in Apple Notes: a ring while open, a filled disc with a check once done.
        let outline = CGPath(ellipseIn: box.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        if isChecked {
            context.setFillColor(EditorTheme.accentColor.cgColor)
            context.addPath(outline)
            context.fillPath()
            context.setStrokeColor(EditorColor.white.cgColor)
            context.setLineWidth(max(1.8, side * 0.11))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + side * 0.25, y: box.minY + side * 0.53))
            context.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.71))
            context.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.30))
            context.strokePath()
        } else {
            context.setStrokeColor(EditorColor.systemGray.cgColor)
            context.setLineWidth(1.5)
            context.addPath(outline)
            context.strokePath()
        }
        context.restoreGState()
    }
}
