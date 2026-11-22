import SwiftUI
import NotesCore

#if canImport(UIKit)
import UIKit
#endif

/// How notes look: background, text, and code (Spec 11). A standard `Form`, so it follows the system look on every platform.
struct AppearanceSettingsView: View {
    @Bindable private var model = AppearanceModel.shared

    var body: some View {
        Form {
            Section("Preview") {
                AppearancePreview(settings: model.settings)
            }

            Section {
                FontChoiceRow(
                    title: "Font",
                    choice: $model.settings.textFont,
                    presets: [.system, .design(.serif), .design(.rounded), .design(.monospaced)]
                )
                SliderRow(title: "Size", value: $model.settings.sizeScale, range: AppearanceSettings.sizeScaleRange,
                          lowSymbol: "textformat.size.smaller", highSymbol: "textformat.size.larger")
                SliderRow(title: "Line Spacing", value: $model.settings.lineSpacing, range: AppearanceSettings.lineSpacingRange,
                          lowSymbol: "text.alignleft", highSymbol: "text.justify.leading")
            } header: {
                Text("Text")
            } footer: {
                Text("Size works together with your system text size.")
            }

            Section {
                FontChoiceRow(
                    title: "Font",
                    choice: $model.settings.codeFont,
                    presets: CodeFonts.all.map(\.choice),
                    displayName: { CodeFonts.option(for: $0)?.name }
                )
                Toggle("Ligatures", isOn: $model.settings.codeLigatures)
                ThemeSwatches(selection: $model.settings.codeThemeID)
            } header: {
                Text("Code")
            } footer: {
                Text("Fira Code, JetBrains Mono, and IBM Plex Mono come with the app under the SIL Open Font License. Ligatures join characters such as -> and != into one symbol, in the fonts that support them. Themes follow light and dark appearance.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { model.reset() }
                    .disabled(model.settings == AppearanceSettings())
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

// MARK: - Font row

private struct FontChoiceRow: View {
    let title: LocalizedStringKey
    @Binding var choice: FontChoice
    let presets: [FontChoice]
    /// A friendlier name for a choice, when the caller has one (the code fonts do).
    var displayName: (FontChoice) -> String? = { _ in nil }

    private func name(of choice: FontChoice) -> String {
        displayName(choice) ?? Self.name(of: choice)
    }

    var body: some View {
        Picker(title, selection: $choice) {
            ForEach(presets, id: \.self) { preset in
                Text(name(of: preset)).tag(preset)
            }
            // A font saved by an older version, or from another device, that is no longer offered.
            if !presets.contains(choice) {
                Text(name(of: choice)).tag(choice)
            }
        }
        if !EditorTheme.isAvailable(choice) {
            // Spec 11, F4: say why the text looks different, instead of failing silently.
            Label("This font isn't installed on this device, so the system font is used.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private static func name(of choice: FontChoice) -> String {
        switch choice {
        case .system: String(localized: "System")
        case .design(.serif): String(localized: "Serif")
        case .design(.rounded): String(localized: "Rounded")
        case .design(.monospaced): String(localized: "Monospaced")
        case .custom(_, let family): family
        }
    }
}

// MARK: - Preview

/// A real sample in the chosen fonts and theme (Spec 11, F7), built with the same colors the editor uses.
private struct AppearancePreview: View {
    /// Not read directly: the editor's theme reads the same settings, and passing them in makes the preview redraw on a change.
    let settings: AppearanceSettings

    private static let sample = """
    func note(id: Int) -> String {
        // Fetch a note
        return "Groceries"
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Groceries")
                .font(Font(EditorTheme.headingFont(level: 1) as CTFont))
            Text("Pick up fresh bread, olive oil, and anything else that looks good at the market.")
                .font(Font(EditorTheme.proseFont as CTFont))
                .lineSpacing(EditorTheme.bodyParagraphStyle.lineSpacing)
            Text(codeSample)
                .lineSpacing(EditorTheme.codeLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(EditorTheme.codeBackground), in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var codeSample: AttributedString {
        var text = AttributedString(Self.sample)
        text.font = Font(EditorTheme.codeFont as CTFont)
        text.foregroundColor = Color(EditorTheme.codeTextColor)
        let source = Self.sample as NSString
        if let engine = SyntaxGrammars.engine(forLanguage: "swift") {
            for token in engine.tokens(in: Self.sample, range: NSRange(location: 0, length: source.length)) {
                if let range = Range(token.range, in: text) {
                    text[range].foregroundColor = Color(EditorTheme.color(for: token.scope))
                }
            }
        }
        return text
    }
}

// MARK: - Slider row

/// A name with its current value, and a slider under it. The slider's own label is hidden because the row already shows it.
private struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let lowSymbol: String
    let highSymbol: String

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: value.formatted(.percent.precision(.fractionLength(0))))
            Slider(value: $value, in: range, step: 0.05) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: lowSymbol)
            } maximumValueLabel: {
                Image(systemName: highSymbol)
            }
            .labelsHidden()
        }
    }
}

// MARK: - Theme swatches

/// The code themes as small samples of their own colors, so a theme is chosen by looking at it.
private struct ThemeSwatches: View {
    @Binding var selection: String

    var body: some View {
        LabeledContent("Theme") {
            HStack(spacing: 12) {
                ForEach(CodeTheme.builtIn) { theme in
                    Button { selection = theme.id } label: { swatch(theme) }
                        .buttonStyle(.plain)
                }
            }
        }
        .accessibilityRepresentation {
            Picker("Theme", selection: $selection) {
                ForEach(CodeTheme.builtIn) { Text($0.name).tag($0.id) }
            }
        }
    }

    /// The same dynamic colors the editor uses, so a swatch follows light and dark like the code block does.
    private func color(_ themeColor: ThemeColor) -> Color {
        Color(EditorTheme.color(themeColor))
    }

    private func swatch(_ theme: CodeTheme) -> some View {
        let isSelected = selection == theme.id
        return VStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Aa")
                    .font(.system(.footnote, design: .monospaced, weight: .semibold))
                    .foregroundStyle(color(theme.text))
                HStack(spacing: 3) {
                    ForEach([SyntaxScope.keyword, .string, .function, .number], id: \.self) { scope in
                        Circle()
                            .fill(theme.style(for: scope).map { color($0.color) } ?? color(theme.text))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(8)
            .background(color(theme.background), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
            }
            Text(theme.name)
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}

#Preview {
    NavigationStack { AppearanceSettingsView() }
}

#Preview("Fira Code") {
    // Previews do not run `MyApp.init`, so register the bundled fonts here.
    BundledFonts.register()
    AppearanceModel.shared.settings.codeFont = CodeFonts.all.first { $0.id == "fira-code" }?.choice ?? .design(.monospaced)
    return NavigationStack { AppearanceSettingsView() }
}
