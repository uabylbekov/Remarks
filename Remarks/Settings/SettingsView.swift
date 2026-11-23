import SwiftUI
import RemarksCore

/// The app's settings. On Mac they open as a single grouped form in the Settings window, matching Apple Notes;
/// on iPhone and iPad they are a short list that pushes into each area, matching the system Settings app.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        Form {
            AppearanceSettingsSections()
            SearchSettingsSection()
            AppearanceResetSection(title: "Reset Appearance to Defaults")
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 450, maxWidth: 520, minHeight: 560, idealHeight: 700)
        #else
        Form {
            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "textformat")
                }
            }
            SearchSettingsSection()
        }
        .navigationTitle("Settings")
        #endif
    }
}

private struct SearchSettingsSection: View {
    @AppStorage(SpotlightSettings.key) private var indexNotes = true

    var body: some View {
        Section {
            Toggle("Show Notes in Spotlight", isOn: $indexNotes)
        } header: {
            Text("Search")
        } footer: {
            Text("Titles, previews, and tags are added to Spotlight and Siri. The full text of a note is never shared.")
        }
    }
}

#Preview {
    #if os(macOS)
    SettingsView()
    #else
    NavigationStack { SettingsView() }
    #endif
}
