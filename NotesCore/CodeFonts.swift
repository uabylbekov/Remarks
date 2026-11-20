import Foundation

/// The fonts offered for code (Spec 11, F2): the system's own monospaced fonts, and a few open-licensed ones
/// that ship inside the app. Fonts are stored by name, so a font that is missing on one device falls back to the
/// system font there (F4).
public struct CodeFontOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let choice: FontChoice
    /// True for fonts that ship inside the app (see `CodeFonts.bundledFileNames`).
    public let isBundled: Bool
}

public enum CodeFonts {
    public static let all: [CodeFontOption] = [
        CodeFontOption(id: "system", name: "SF Mono", choice: .design(.monospaced), isBundled: false),
        CodeFontOption(id: "menlo", name: "Menlo", choice: .custom(postScriptName: "Menlo-Regular", family: "Menlo"), isBundled: false),
        CodeFontOption(id: "courier-new", name: "Courier New", choice: .custom(postScriptName: "CourierNewPSMT", family: "Courier New"), isBundled: false),
        CodeFontOption(id: "fira-code", name: "Fira Code", choice: .custom(postScriptName: "FiraCode-Regular", family: "Fira Code"), isBundled: true),
        CodeFontOption(id: "jetbrains-mono", name: "JetBrains Mono", choice: .custom(postScriptName: "JetBrainsMono-Regular", family: "JetBrains Mono"), isBundled: true),
        CodeFontOption(id: "ibm-plex-mono", name: "IBM Plex Mono", choice: .custom(postScriptName: "IBMPlexMono-Regular", family: "IBM Plex Mono"), isBundled: true),
    ]

    /// The font files inside the app, without the `.ttf` extension. Bold and italic faces are included so
    /// bold and italic code render with the real faces instead of slanted or smeared ones.
    public static let bundledFileNames: [String] = [
        "FiraCode-Regular", "FiraCode-Bold",
        "JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic",
        "IBMPlexMono-Regular", "IBMPlexMono-Bold", "IBMPlexMono-Italic", "IBMPlexMono-BoldItalic",
    ]

    /// The option that matches a saved choice, if it is one of the offered fonts.
    public static func option(for choice: FontChoice) -> CodeFontOption? {
        all.first { $0.choice == choice }
    }
}
