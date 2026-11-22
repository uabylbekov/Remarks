import SwiftUI
import NotesCore

/// The app's settings. On the Mac they open in the Settings window with a tab for each area; on iPhone and iPad they
/// are a short list that opens each area, the way the system Settings app does.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        // The window follows the selected tab's natural size. The short tab is pinned to its content; the long one can
        // shrink and scroll, and the window is kept on screen by the system.
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
                    .frame(minWidth: 440, idealWidth: 480, maxWidth: 640)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Tab("Appearance", systemImage: "textformat") {
                AppearanceSettingsView()
                    .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 360)
            }
        }
        #else
        Form {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                Label("Appearance", systemImage: "textformat")
            }
            SearchSettingsSection()
        }
        .navigationTitle("Settings")
        #endif
    }
}

/// Settings that are not about looks.
struct GeneralSettingsView: View {
    var body: some View {
        Form { SearchSettingsSection() }
            .formStyle(.grouped)
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
    NavigationStack { SettingsView() }
}
