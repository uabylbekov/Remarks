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

    /// Muted colors on a warm background, from the Solarized palette.
    public static let solarized = CodeTheme(
        id: "solarized", name: "Solarized",
        background: ThemeColor(light: 0xFDF6E3, dark: 0x002B36),
        text: ThemeColor(light: 0x586E75, dark: 0x93A1A1),
        tokens: tokens(
            comment: (0x5D7179, 0x839496), string: (0x207A72, 0x2AA198), keyword: (0x647300, 0x859900),
            number: (0xC33278, 0xDE68A1), type: (0x886800, 0xB58900), function: (0x2071AC, 0x3F98D8),
            attribute: (0xBB4514, 0xD97850), constant: (0x6468B4, 0x878BCE), property: (0x2071AC, 0x3F98D8),
            variable: (0xBB4514, 0xD97850)
        )
    )

    /// Maximum contrast, for Increase Contrast users and bright light.
    public static let highContrast = CodeTheme(
        id: "high-contrast", name: "High Contrast",
        background: ThemeColor(light: 0xFFFFFF, dark: 0x000000),
        text: ThemeColor(light: 0x000000, dark: 0xFFFFFF),
        tokens: tokens(
            comment: (0x4A4A4A, 0xBDBDBD), string: (0x8A1100, 0xFFB4A8), keyword: (0x7A0072, 0xFF9AD5),
            number: (0x0000A8, 0xFFE27A), type: (0x00494F, 0x7CE8FF), function: (0x004B8D, 0x8CD0FF),
            attribute: (0x6B3300, 0xFFC27A), constant: (0x3B0A99, 0xD2B4FF), property: (0x005A4A, 0x8FF0DB),
            variable: (0x004B8D, 0x8CD0FF), boldKeywords: true
        )
    )

    public static let builtIn: [CodeTheme] = [.standard, .solarized, .highContrast]

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
    public static let lineSpacingRange = 0.0...0.6

    public var textFont: FontChoice = .system
    public var codeFont: FontChoice = .design(.monospaced)
    /// Multiplies the Dynamic Type size, so it works together with it (F3).
    public var sizeScale = 1.0
    /// Extra space between lines, as a fraction of the font size (F6).
    public var lineSpacing = 0.15
    public var codeThemeID = CodeTheme.standard.id

    public init() {}

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
