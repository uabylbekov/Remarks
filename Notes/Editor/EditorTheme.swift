import SwiftUI
import NotesCore

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
enum EditorTheme {
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

    private static var proseSize: CGFloat { baseProseSize * settings.sizeScale }

    static var proseFont: EditorFont {
        font(for: settings.textFont, size: proseSize)
    }

    static var codeFont: EditorFont {
        font(for: settings.codeFont, size: proseSize * 0.92)
    }

    /// Heading level 1 to 6. Levels 5 and 6 stay at body size.
    static func headingFont(level: Int) -> EditorFont {
        let scale = [1.7, 1.45, 1.25, 1.1, 1.0, 1.0][min(max(level, 1), 6) - 1]
        return traited(font(for: settings.textFont, size: proseSize * scale), bold: true)
    }

    /// Inline code: the code font, slightly smaller than the surrounding text.
    static func inlineCodeFont(matching font: EditorFont) -> EditorFont {
        self.font(for: settings.codeFont, size: font.pointSize * 0.92)
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

    static var accentColor: EditorColor { .systemBlue }

    /// The code theme's background, for code blocks and inline code.
    static var codeBackground: EditorColor { color(settings.codeTheme.background) }

    /// The code theme's plain text color, for code that has no token color.
    static var codeTextColor: EditorColor { color(settings.codeTheme.text) }

    static func color(for scope: SyntaxScope) -> EditorColor {
        settings.codeTheme.style(for: scope).map { color($0.color) } ?? codeTextColor
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
