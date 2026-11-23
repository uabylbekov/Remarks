import SwiftUI
import RemarksCore

/// How notes look: fonts, text spacing, and code theme (Spec 11). A standard grouped `Form`, so it follows the system
/// look on every platform.
struct AppearanceSettingsView: View {
    var body: some View {
        Form {
            AppearanceSettingsSections()
            AppearanceResetSection(title: "Reset to Defaults")
        }
        .formStyle(.grouped)
        #if !os(macOS)
        .navigationTitle("Appearance")
        #endif
    }
}

/// The appearance sections shared between the iOS Appearance screen and the macOS Settings window.
struct AppearanceSettingsSections: View {
    @Environment(\.appearanceModel) private var model

    var body: some View {
        @Bindable var model = model

        Section("Preview") {
            AppearancePreview(revision: model.revision)
        }

        Section {
            FontChoiceRow(
                title: "Font",
                choice: $model.settings.textFont,
                presets: [.system, .design(.serif), .design(.rounded), .design(.monospaced)]
            )
            SliderRow(
                title: "Size",
                value: $model.settings.sizeScale,
                range: AppearanceSettings.sizeScaleRange,
                neutralValue: AppearanceSettings.defaultSizeScale,
                formattedValue: model.settings.sizeScale.formatted(.percent.precision(.fractionLength(0)))
            ) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.secondary)
            }
            SliderRow(
                title: "Line Height",
                value: $model.settings.lineHeight,
                range: AppearanceSettings.lineHeightRange,
                neutralValue: AppearanceSettings.defaultLineHeight,
                formattedValue: model.settings.lineHeight.formatted(.number.precision(.fractionLength(2)))
            ) {
                Text(AppearanceSettings.lineHeightRange.lowerBound, format: .number.precision(.fractionLength(1)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } maximumValueLabel: {
                Text(AppearanceSettings.lineHeightRange.upperBound, format: .number.precision(.fractionLength(1)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } header: {
            Text("Text")
        } footer: {
            #if os(iOS)
            Text("Size works together with your system text size.")
            #endif
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
    }
}

/// Resets appearance settings back to their defaults.
struct AppearanceResetSection: View {
    @Environment(\.appearanceModel) private var model
    let title: LocalizedStringKey

    var body: some View {
        Section {
            Button(title, role: .destructive) {
                model.reset()
            }
            .disabled(model.settings == AppearanceSettings())
        }
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
    /// Not read directly: `EditorTheme` caches its fonts and colors by this number, which changes with every setting and
    /// with the system text size. Passing it in redraws the preview exactly when the theme has new values.
    let revision: Int

    private static let sample = """
    func note(id: Int) -> String {
        // Fetch a note
        return "Groceries"
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headingSample)
            Text("Pick up fresh bread, olive oil, and anything else that looks good at the market.")
                .font(Font(EditorTheme.proseFont as CTFont))
                .lineSpacing(EditorTheme.bodyParagraphStyle.lineSpacing)
            VStack(alignment: .leading, spacing: 0) {
                Text(openingFence)
                    .padding(.bottom, LivePreviewController.fenceGap)
                Text(codeSample)
                    .lineSpacing(EditorTheme.codeLineSpacing)
                Text(verbatim: "```")
                    .font(fenceFont)
                    .foregroundStyle(Color(EditorTheme.dimColor))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, LivePreviewController.cardPadding)
            .padding(.horizontal, LivePreviewController.codeInset)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var fenceFont: Font {
        Font(EditorFont.monospacedSystemFont(ofSize: EditorTheme.codeFont.pointSize * 0.8, weight: .regular) as CTFont)
    }

    private var headingSample: AttributedString {
        var marker = AttributedString("# ")
        marker.foregroundColor = Color(EditorTheme.dimColor)
        var title = AttributedString(String(localized: "Groceries"))
        title.foregroundColor = Color(EditorTheme.baseColor)
        var combined = marker + title
        combined.font = Font(EditorTheme.headingFont(level: 1) as CTFont)
        return combined
    }

    private var openingFence: AttributedString {
        var ticks = AttributedString("```")
        ticks.foregroundColor = Color(EditorTheme.dimColor)
        var language = AttributedString("swift")
        language.foregroundColor = Color(EditorTheme.codeTextColor)
        var combined = ticks + language
        combined.font = fenceFont
        return combined
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

/// A stepped slider with a default tick mark and a formatted value readout.
/// On macOS it uses the native grouped-form `Slider` row layout; on iOS it places a `LabeledContent` header above the
/// slider because iOS forms hide the slider's built-in label.
private struct SliderRow<ValueLabel: View>: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double = 0.05
    let neutralValue: Double
    let formattedValue: String
    @ViewBuilder let minimumValueLabel: () -> ValueLabel
    @ViewBuilder let maximumValueLabel: () -> ValueLabel

    private var roundedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = ($0 * 100).rounded() / 100 }
        )
    }

    var body: some View {
        #if os(macOS)
        Slider(
            value: roundedValue,
            in: range,
            step: step,
            neutralValue: neutralValue
        ) {
            Text(title)
            Text(formattedValue)
                .monospacedDigit()
        } minimumValueLabel: {
            minimumValueLabel()
        } maximumValueLabel: {
            maximumValueLabel()
        }
        .accessibilityValue(formattedValue)
        #else
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Text(formattedValue)
                    .monospacedDigit()
            }
            Slider(
                value: roundedValue,
                in: range,
                step: step,
                neutralValue: neutralValue
            ) {
                Text(title)
            } minimumValueLabel: {
                minimumValueLabel()
            } maximumValueLabel: {
                maximumValueLabel()
            }
            .labelsHidden()
            .accessibilityValue(formattedValue)
        }
        #endif
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
                        .contentShape(.rect)
                }
            }
        }
        .accessibilityRepresentation {
            Picker("Theme", selection: $selection) {
                ForEach(CodeTheme.builtIn) { Text(displayName(for: $0)).tag($0.id) }
            }
        }
    }

    private func displayName(for theme: CodeTheme) -> String {
        theme.id == CodeTheme.standard.id ? String(localized: "Standard") : theme.name
    }

    /// The same dynamic colors the editor uses, so a swatch follows light and dark like the code block does.
    private func color(_ themeColor: ThemeColor) -> Color {
        Color(EditorTheme.color(themeColor))
    }

    private func swatch(_ theme: CodeTheme) -> some View {
        let isSelected = selection == theme.id
        return VStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Aa")
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
            Text(displayName(for: theme))
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
