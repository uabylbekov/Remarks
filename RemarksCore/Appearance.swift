import Foundation

// Appearance settings (Spec 11). Pure data: fonts, sizes, and code themes. Nothing here touches note content.

/// A color as sRGB components, 0 to 1.
public struct RGB: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// For example `RGB(hex: 0xFF8800)`.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors, 1 to 21.
    public func contrast(with other: RGB) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// Black or white, whichever yields higher WCAG contrast against this color.
    public var contrastingForeground: RGB {
        let white = RGB(hex: 0xFFFFFF)
        let black = RGB(hex: 0x000000)
        return contrast(with: white) >= contrast(with: black) ? white : black
    }
}

/// A color with a light and a dark variant (Spec 11, T3).
public struct ThemeColor: Codable, Equatable, Sendable {
    public var light: RGB
    public var dark: RGB

    public init(light: RGB, dark: RGB) {
        self.light = light
        self.dark = dark
    }

    public init(light: UInt32, dark: UInt32) {
        self.init(light: RGB(hex: light), dark: RGB(hex: dark))
    }
}

public struct TokenStyle: Codable, Equatable, Sendable {
    public var color: ThemeColor
    public var bold: Bool
    public var italic: Bool

    public init(color: ThemeColor, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// A code color theme. A versioned `Codable` value (Spec 11, T5). Token styles are keyed by `SyntaxScope`
/// raw value, so a scope a theme does not know falls back to the text color (T6).
public struct CodeTheme: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public var id: String
    public var name: String
    public var background: ThemeColor
    public var text: ThemeColor
    public var tokens: [String: TokenStyle]

    public init(id: String, name: String, background: ThemeColor, text: ThemeColor, tokens: [SyntaxScope: TokenStyle]) {
        self.id = id
        self.name = name
        self.background = background
        self.text = text
        self.tokens = Dictionary(uniqueKeysWithValues: tokens.map { ($0.key.rawValue, $0.value) })
    }

    public func style(for scope: SyntaxScope) -> TokenStyle? {
        tokens[scope.rawValue]
    }
}

extension CodeTheme {
    private static func tokens(
        comment: (UInt32, UInt32), string: (UInt32, UInt32), keyword: (UInt32, UInt32), number: (UInt32, UInt32),
        type: (UInt32, UInt32), function: (UInt32, UInt32), attribute: (UInt32, UInt32), constant: (UInt32, UInt32),
        property: (UInt32, UInt32), variable: (UInt32, UInt32), boldKeywords: Bool = false
    ) -> [SyntaxScope: TokenStyle] {
        func style(_ pair: (UInt32, UInt32), bold: Bool = false, italic: Bool = false) -> TokenStyle {
            TokenStyle(color: ThemeColor(light: pair.0, dark: pair.1), bold: bold, italic: italic)
        }
        return [
            .comment: style(comment, italic: true), .string: style(string), .keyword: style(keyword, bold: boldKeywords),
            .number: style(number), .type: style(type), .function: style(function), .attribute: style(attribute),
            .constant: style(constant), .property: style(property), .variable: style(variable),
        ]
    }

    /// The default look: close to Xcode's default colors.
    public static let standard = CodeTheme(
        id: "standard", name: "Standard",
        background: ThemeColor(light: 0xF2F2F7, dark: 0x2C2C2E),
        text: ThemeColor(light: 0x1C1C1E, dark: 0xF2F2F7),
        tokens: tokens(
            comment: (0x5D6C79, 0x8E99A4), string: (0xC92D1A, 0xFF8170), keyword: (0xAD3DA4, 0xFF7AB2),
            number: (0x272AD8, 0xD9C97C), type: (0x1C464A, 0x6BDFFF), function: (0x326D74, 0x4EB0CC),
            attribute: (0x78492A, 0xFFA14F), constant: (0x3A767D, 0xB281EB), property: (0x326D74, 0x78C2B3),
            variable: (0x0F68A0, 0x4EB0CC)
        )
    )

    /// GitHub's code colors: a light gray block in light mode, GitHub's dark palette in dark mode.
    public static let github = CodeTheme(
        id: "github", name: "GitHub",
        background: ThemeColor(light: 0xF6F8FA, dark: 0x161B22),
        text: ThemeColor(light: 0x1F2328, dark: 0xE6EDF3),
        tokens: tokens(
            comment: (0x59636E, 0x8B949E), string: (0x0A3069, 0xA5D6FF), keyword: (0xCF222E, 0xFF7B72),
            number: (0x0550AE, 0x79C0FF), type: (0x953800, 0xFFA657), function: (0x8250DF, 0xD2A8FF),
            attribute: (0x0550AE, 0x79C0FF), constant: (0x0550AE, 0x79C0FF), property: (0x0550AE, 0x79C0FF),
            variable: (0x953800, 0xFFA657)
        )
    )

    /// Monokai's classic dark palette, with the same hues deepened for light mode.
    public static let monokai = CodeTheme(
        id: "monokai", name: "Monokai",
        background: ThemeColor(light: 0xFAFAF5, dark: 0x272822),
        text: ThemeColor(light: 0x272822, dark: 0xF8F8F2),
        tokens: tokens(
            comment: (0x6E6A58, 0xA39F8A), string: (0x7A6E00, 0xE6DB74), keyword: (0xD4155F, 0xFF5C93),
            number: (0x7A4FD6, 0xAE81FF), type: (0x00768F, 0x66D9EF), function: (0x3F7300, 0xA6E22E),
            attribute: (0x3F7300, 0xA6E22E), constant: (0x7A4FD6, 0xAE81FF), property: (0x00768F, 0x66D9EF),
            variable: (0x272822, 0xF8F8F2)
        )
    )

    public static let builtIn: [CodeTheme] = [.standard, .github, .monokai]

    /// The built-in theme with this id, or the standard theme if it is unknown (for example from a newer app version).
    public static func builtIn(id: String) -> CodeTheme {
        builtIn.first { $0.id == id } ?? .standard
    }
}

/// A font the user picked. Stored by name, never by file, so a font missing on one device can fall back (F4).
public enum FontChoice: Codable, Hashable, Sendable {
    public enum Design: String, Codable, CaseIterable, Sendable {
        case serif, rounded, monospaced
    }

    case system
    case design(Design)
    case custom(postScriptName: String, family: String)
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public static let sizeScaleRange = 0.8...1.6
    public static let lineSpacingRange = 0.0...1.0
    public static let lineHeightRange = 1.0...2.0
    public static let defaultSizeScale = 1.0
    public static let defaultLineHeight = 1.15

    public var textFont: FontChoice = .system
    public var codeFont: FontChoice = .design(.monospaced)
    /// Multiplies the Dynamic Type size, so it works together with it (F3).
    public var sizeScale = AppearanceSettings.defaultSizeScale
    /// Extra space between lines, as a fraction of the font size (F6).
    public var lineSpacing = 0.15
    public var codeThemeID = CodeTheme.standard.id
    /// Lets the code font join characters such as `->` and `!=` into one symbol. Only Fira Code and JetBrains Mono do it.
    public var codeLigatures = true

    /// Line height as a multiplier of the font size (`1.0` to `2.0`, default `1.15`).
    /// Backed by `lineSpacing` (`lineHeight - 1`) so stored settings stay compatible with earlier versions.
    public var lineHeight: Double {
        get { ((1.0 + lineSpacing) * 100).rounded() / 100 }
        set {
            let clamped = min(max(newValue, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
            lineSpacing = ((clamped - 1.0) * 100).rounded() / 100
        }
    }

    public init() {}

    // Settings written by an older version lack the newer keys, and a newer version may write a value this one does
    // not know (a new font design, say). Each such key keeps its default, so one unreadable value never costs the rest
    // of the settings, and the next save does not overwrite them with defaults.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        textFont = (try? values.decodeIfPresent(FontChoice.self, forKey: .textFont)) ?? textFont
        codeFont = (try? values.decodeIfPresent(FontChoice.self, forKey: .codeFont)) ?? codeFont
        sizeScale = (try? values.decodeIfPresent(Double.self, forKey: .sizeScale)) ?? sizeScale
        lineSpacing = (try? values.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? lineSpacing
        codeThemeID = (try? values.decodeIfPresent(String.self, forKey: .codeThemeID)) ?? codeThemeID
        codeLigatures = (try? values.decodeIfPresent(Bool.self, forKey: .codeLigatures)) ?? codeLigatures
    }

    /// Keeps stored values inside their allowed ranges, in case another device wrote something unexpected.
    public func clamped() -> AppearanceSettings {
        var copy = self
        copy.sizeScale = min(max(sizeScale, Self.sizeScaleRange.lowerBound), Self.sizeScaleRange.upperBound)
        copy.lineSpacing = min(max(lineSpacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        return copy
    }

    public var codeTheme: CodeTheme { CodeTheme.builtIn(id: codeThemeID) }
}

/// Where settings are kept. `NSUbiquitousKeyValueStore` and `UserDefaults` both fit (Spec 11, "Where settings live").
public protocol SettingsStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension UserDefaults: SettingsStorage {
    public func set(_ data: Data?, forKey key: String) {
        set(data as Any?, forKey: key)
    }
}

extension NSUbiquitousKeyValueStore: SettingsStorage {
    public func set(_ data: Data?, forKey key: String) {
        set(data as Any?, forKey: key)
    }
}

/// Reads and writes `AppearanceSettings`: iCloud key-value storage first, a local `UserDefaults` copy always.
public final class AppearanceStorage {
    static let key = "appearance.v1"

    private let local: SettingsStorage
    private let cloud: SettingsStorage?

    public init(local: SettingsStorage = UserDefaults.standard, cloud: SettingsStorage? = NSUbiquitousKeyValueStore.default) {
        self.local = local
        self.cloud = cloud
    }

    /// The iCloud copy if there is one, otherwise the local copy, otherwise the defaults.
    public func load() -> AppearanceSettings {
        for source in [cloud, local] {
            if let data = source?.data(forKey: Self.key),
               let settings = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
                return settings.clamped()
            }
        }
        return AppearanceSettings()
    }

    public func save(_ settings: AppearanceSettings) {
        guard let data = try? JSONEncoder().encode(settings.clamped()) else { return }
        local.set(data, forKey: Self.key)
        cloud?.set(data, forKey: Self.key)
    }
}
