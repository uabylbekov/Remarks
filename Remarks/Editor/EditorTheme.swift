import SwiftUI
import RemarksCore

#if canImport(UIKit)
import UIKit
typealias EditorFont = UIFont
typealias EditorColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias EditorFont = NSFont
typealias EditorColor = NSColor
#endif

/// Fonts and colors used by the editor. Fonts, size, and the code theme come from the user's appearance
/// settings (Spec 11). Colors adapt to light, dark, and Increase Contrast.
@MainActor
enum EditorTheme {
    /// Pre-resolved fonts, paragraph style, and dynamic colors for one appearance revision and base size.
    private struct Cache {
        let revision: Int
        let baseProseSize: CGFloat
        let proseFont: EditorFont
        let codeFont: EditorFont
        let fenceFont: EditorFont
        let bodyParagraphStyle: NSParagraphStyle
        let codeLineSpacing: CGFloat
        let headingFonts: [EditorFont]
        let codeBackground: EditorColor
        let codeTextColor: EditorColor
        let scopeColors: [SyntaxScope: EditorColor]
        let scopeFonts: [SyntaxScope: EditorFont]
    }

    private static var cached: Cache?

    private static var settings: AppearanceSettings { AppearanceModel.shared.settings }

    // MARK: Fonts

    /// The size body text uses before the user's size setting. On iOS it follows Dynamic Type.
    private static var baseProseSize: CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        NSFont.systemFontSize + 1
        #endif
    }

    private static var current: Cache {
        let revision = AppearanceModel.shared.revision
        let baseSize = baseProseSize
        if let cached, cached.revision == revision, cached.baseProseSize == baseSize {
            return cached
        }
        let settings = AppearanceModel.shared.settings
        let proseSize = baseSize * settings.sizeScale
        let prose = font(for: settings.textFont, size: proseSize)
        let code = codeFont(size: proseSize * 0.92, settings: settings)
        let fence = codeFont(size: code.pointSize * 0.8, settings: settings)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = proseSize * settings.lineSpacing
        let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.1, 1.0, 1.0]
        let headings = scales.map { traited(font(for: settings.textFont, size: proseSize * $0), bold: true) }
        let codeBg = color(settings.codeTheme.background)
        let codeText = color(settings.codeTheme.text)
        var scopes: [SyntaxScope: EditorColor] = [:]
        var scopeFonts: [SyntaxScope: EditorFont] = [:]
        for scope in SyntaxScope.allCases {
            if let tokenStyle = settings.codeTheme.style(for: scope) {
                scopes[scope] = color(tokenStyle.color)
                if tokenStyle.bold || tokenStyle.italic {
                    scopeFonts[scope] = traited(code, bold: tokenStyle.bold, italic: tokenStyle.italic)
                }
            } else {
                scopes[scope] = codeText
            }
        }
        let next = Cache(
            revision: revision,
            baseProseSize: baseSize,
            proseFont: prose,
            codeFont: code,
            fenceFont: fence,
            bodyParagraphStyle: style.copy() as? NSParagraphStyle ?? style,
            codeLineSpacing: code.pointSize * settings.lineSpacing,
            headingFonts: headings,
            codeBackground: codeBg,
            codeTextColor: codeText,
            scopeColors: scopes,
            scopeFonts: scopeFonts
        )
        cached = next
        return next
    }

    private static var proseSize: CGFloat { baseProseSize * settings.sizeScale }

    static var proseFont: EditorFont { current.proseFont }

    static var codeFont: EditorFont { current.codeFont }

    /// The smaller code font used for fenced block delimiters (` ```swift `).
    static var fenceFont: EditorFont { current.fenceFont }

    /// Complete base attributes for ordinary prose so newly inserted text never falls back to default 12pt black.
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: proseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    /// The code font scaled down, for tables that are wider than the text.
    static func codeFont(scale: CGFloat) -> EditorFont {
        codeFont(size: proseSize * 0.92 * scale, settings: settings)
    }

    /// The code font at a size, with ligatures switched off when the setting says so.
    private static func codeFont(size: CGFloat, settings: AppearanceSettings) -> EditorFont {
        let base = font(for: settings.codeFont, size: size)
        return settings.codeLigatures ? base : withoutLigatures(base)
    }

    /// Fira Code and JetBrains Mono build their symbols (`->`, `!=`) from contextual alternates, so both that and the
    /// common ligature feature are turned off.
    private static func withoutLigatures(_ font: EditorFont) -> EditorFont {
        #if canImport(UIKit)
        let (type, selector) = (EditorFontDescriptor.FeatureKey.type, EditorFontDescriptor.FeatureKey.selector)
        #else
        let (type, selector) = (EditorFontDescriptor.FeatureKey.typeIdentifier, EditorFontDescriptor.FeatureKey.selectorIdentifier)
        #endif
        let features: [[EditorFontDescriptor.FeatureKey: Int]] = [
            [type: kContextualAlternatesType, selector: kContextualAlternatesOffSelector],
            [type: kLigaturesType, selector: kCommonLigaturesOffSelector],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        #if canImport(UIKit)
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    /// The paragraph style for ordinary text: the line spacing setting, as a fraction of the font size. Lines that the
    /// live preview styles itself (code, tables, attachments) set their own.
    static var bodyParagraphStyle: NSParagraphStyle { current.bodyParagraphStyle }

    /// The line spacing setting for code, as a fraction of the code font size, like `bodyParagraphStyle` does for text.
    static var codeLineSpacing: CGFloat { current.codeLineSpacing }

    /// Heading level 1 to 6. Levels 5 and 6 stay at body size.
    static func headingFont(level: Int) -> EditorFont {
        current.headingFonts[min(max(level, 1), 6) - 1]
    }

    /// Inline code: the code font, slightly smaller than the surrounding text.
    static func inlineCodeFont(matching font: EditorFont) -> EditorFont {
        codeFont(size: font.pointSize * 0.92, settings: settings)
    }

    /// Builds a font from a saved choice. A font that is missing on this device falls back to the system font (F4).
    static func font(for choice: FontChoice, size: CGFloat) -> EditorFont {
        switch choice {
        case .system:
            return .systemFont(ofSize: size)
        case .design(.monospaced):
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .design(let design):
            let base = EditorFont.systemFont(ofSize: size)
            let systemDesign: EditorFontDescriptor.SystemDesign = design == .serif ? .serif : .rounded
            #if canImport(UIKit)
            return base.fontDescriptor.withDesign(systemDesign).map { UIFont(descriptor: $0, size: size) } ?? base
            #else
            return base.fontDescriptor.withDesign(systemDesign).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            #endif
        case .custom(let postScriptName, _):
            return EditorFont(name: postScriptName, size: size) ?? .systemFont(ofSize: size)
        }
    }

    /// Whether a saved choice can be used on this device.
    static func isAvailable(_ choice: FontChoice) -> Bool {
        if case .custom(let postScriptName, _) = choice {
            return EditorFont(name: postScriptName, size: 12) != nil
        }
        return true
    }

    /// The same font with bold and/or italic added. Returns the font unchanged if the face does not exist.
    static func traited(_ font: EditorFont, bold: Bool = false, italic: Bool = false) -> EditorFont {
        #if canImport(UIKit)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #endif
    }

    // MARK: Colors

    static var baseColor: EditorColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }

    /// Used for the fence lines while they are visible.
    static var dimColor: EditorColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    static var linkColor: EditorColor {
        #if canImport(UIKit)
        .link
        #else
        .linkColor
        #endif
    }

    /// The editor's background: the system color.
    static var editorBackground: EditorColor {
        #if canImport(UIKit)
        .systemBackground
        #else
        .textBackgroundColor
        #endif
    }

    /// The system accent color, for checkboxes and attachment icons.
    static var accentColor: EditorColor {
        #if canImport(UIKit)
        .tintColor
        #else
        .controlAccentColor
        #endif
    }

    /// Whether the system's Increase Contrast accessibility setting is enabled.
    static var increaseContrast: Bool {
        #if canImport(UIKit)
        UIAccessibility.isDarkerSystemColorsEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #endif
    }

    /// Hairline border and divider color that strengthens under Increase Contrast.
    static var separatorColor: EditorColor {
        if increaseContrast { return baseColor.withAlphaComponent(0.5) }
        #if canImport(UIKit)
        return .separator
        #else
        return .separatorColor
        #endif
    }

    /// White or black foreground guaranteeing high WCAG contrast over `background`.
    static func contrastingForeground(over background: EditorColor) -> EditorColor {
        #if canImport(UIKit)
        let resolved = background.resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        #else
        guard let srgb = background.usingColorSpace(.sRGB) else { return .white }
        let (r, g, b) = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        #endif
        let fg = RGB(red: Double(r), green: Double(g), blue: Double(b)).contrastingForeground
        return EditorColor(red: fg.red, green: fg.green, blue: fg.blue, alpha: 1)
    }

    /// The code theme's background, for code blocks and inline code.
    static var codeBackground: EditorColor { current.codeBackground }

    /// The code theme's plain text color, for code that has no token color.
    static var codeTextColor: EditorColor { current.codeTextColor }

    static func color(for scope: SyntaxScope) -> EditorColor {
        current.scopeColors[scope] ?? current.codeTextColor
    }

    /// Bold/italic code font variant for syntax scopes whose theme style sets font traits, or nil for regular code font.
    static func font(for scope: SyntaxScope) -> EditorFont? {
        current.scopeFonts[scope]
    }

    /// A color that switches between the theme's light and dark variants with the appearance.
    static func color(_ themeColor: ThemeColor) -> EditorColor {
        func make(_ rgb: RGB) -> EditorColor {
            EditorColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        #if canImport(UIKit)
        return UIColor { $0.userInterfaceStyle == .dark ? make(themeColor.dark) : make(themeColor.light) }
        #else
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(themeColor.dark) : make(themeColor.light)
        }
        #endif
    }
}

#if canImport(UIKit)
typealias EditorFontDescriptor = UIFontDescriptor
#else
typealias EditorFontDescriptor = NSFontDescriptor
#endif
