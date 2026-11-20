import SwiftUI
import NotesCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Fonts and code themes (Spec 11). A standard `Form`, so it follows the system look on every platform.
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
                    presets: [.system, .design(.serif), .design(.rounded), .design(.monospaced)],
                    monospacedOnly: false
                )
                VStack(alignment: .leading) {
                    LabeledContent("Size", value: model.settings.sizeScale.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $model.settings.sizeScale, in: AppearanceSettings.sizeScaleRange, step: 0.05) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
            } header: {
                Text("Text")
            } footer: {
                Text("Size works together with your system text size.")
            }

            Section {
                FontChoiceRow(
                    title: "Font",
                    choice: $model.settings.codeFont,
                    presets: [.design(.monospaced)],
                    monospacedOnly: true
                )
                Picker("Theme", selection: $model.settings.codeThemeID) {
                    ForEach(CodeTheme.builtIn) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            } header: {
                Text("Code")
            } footer: {
                Text("Themes follow light and dark appearance.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { model.reset() }
                    .disabled(model.settings == AppearanceSettings())
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 520)
        #endif
    }
}

// MARK: - Font row

private struct FontChoiceRow: View {
    let title: LocalizedStringKey
    @Binding var choice: FontChoice
    let presets: [FontChoice]
    let monospacedOnly: Bool
    @State private var showsFontPicker = false

    var body: some View {
        Picker(title, selection: $choice) {
            ForEach(presets, id: \.self) { preset in
                Text(Self.name(of: preset)).tag(preset)
            }
            if case .custom = choice, !presets.contains(choice) {
                Text(Self.name(of: choice)).tag(choice)
            }
        }

        #if canImport(UIKit)
        Button("Choose Installed Font…") { showsFontPicker = true }
            .sheet(isPresented: $showsFontPicker) {
                FontPicker(monospacedOnly: monospacedOnly) { picked in
                    choice = picked
                }
                .ignoresSafeArea()
            }
        #else
        Menu("Choose Installed Font…") {
            ForEach(Self.installedFamilies(monospacedOnly: monospacedOnly), id: \.self) { family in
                Button(family) {
                    if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) {
                        choice = .custom(postScriptName: font.fontName, family: family)
                    }
                }
            }
        }
        #endif

        if !EditorTheme.isAvailable(choice) {
            // Spec 11, F4: say why the text looks different, instead of failing silently.
            Label("This font isn't installed on this device, so the system font is used.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func name(of choice: FontChoice) -> String {
        switch choice {
        case .system: String(localized: "System")
        case .design(.serif): String(localized: "Serif")
        case .design(.rounded): String(localized: "Rounded")
        case .design(.monospaced): String(localized: "Monospaced")
        case .custom(_, let family): family
        }
    }

    #if canImport(AppKit)
    private static func installedFamilies(monospacedOnly: Bool) -> [String] {
        let manager = NSFontManager.shared
        guard monospacedOnly else { return manager.availableFontFamilies }
        return manager.availableFontFamilies.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
    }
    #endif
}

#if canImport(UIKit)
/// The system font picker. It lists system fonts and fonts the user installed.
private struct FontPicker: UIViewControllerRepresentable {
    let monospacedOnly: Bool
    let onPick: (FontChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.filteredTraits = monospacedOnly ? .traitMonoSpace : []
        configuration.includeFaces = false
        let controller = UIFontPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let parent: FontPicker
        init(_ parent: FontPicker) { self.parent = parent }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let descriptor = viewController.selectedFontDescriptor {
                let font = UIFont(descriptor: descriptor, size: 12)
                parent.onPick(.custom(postScriptName: font.fontName, family: font.familyName))
            }
            parent.dismiss()
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            parent.dismiss()
        }
    }
}
#endif

// MARK: - Preview

/// A real sample in the chosen fonts and theme (Spec 11, F7), built with the same colors the editor uses.
private struct AppearancePreview: View {
    let settings: AppearanceSettings

    private static let sample = """
    // Fetch a note
    func note(id: Int) -> String {
        let title = "Groceries"
        return title
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The quick brown fox jumps over the lazy dog.")
                .font(Font(EditorTheme.proseFont as CTFont))
            Text(codeSample)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(EditorTheme.codeBackground), in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
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

#Preview {
    NavigationStack { AppearanceSettingsView() }
}
