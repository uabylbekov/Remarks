import Foundation
import Testing
@testable import NotesCore

private final class MemoryStorage: SettingsStorage {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
}

struct AppearanceTests {
    @Test func settingsRoundTripThroughJSON() throws {
        var settings = AppearanceSettings()
        settings.textFont = .custom(postScriptName: "Georgia", family: "Georgia")
        settings.codeFont = .design(.monospaced)
        settings.codeThemeID = "solarized"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data) == settings)
    }

    @Test func outOfRangeValuesAreClamped() {
        var settings = AppearanceSettings()
        settings.sizeScale = 9
        settings.lineSpacing = -3
        let fixed = settings.clamped()
        #expect(fixed.sizeScale == AppearanceSettings.sizeScaleRange.upperBound)
        #expect(fixed.lineSpacing == AppearanceSettings.lineSpacingRange.lowerBound)
    }

    @Test func unknownThemeFallsBackToStandard() {
        var settings = AppearanceSettings()
        settings.codeThemeID = "from-a-newer-version"
        #expect(settings.codeTheme.id == CodeTheme.standard.id)
    }

    @Test func cloudCopyWinsOverLocal() {
        let local = MemoryStorage(), cloud = MemoryStorage()
        var onThisDevice = AppearanceSettings()
        onThisDevice.codeThemeID = "standard"
        AppearanceStorage(local: local, cloud: nil).save(onThisDevice)

        var fromOtherDevice = AppearanceSettings()
        fromOtherDevice.codeThemeID = "solarized"
        AppearanceStorage(local: MemoryStorage(), cloud: cloud).save(fromOtherDevice)

        #expect(AppearanceStorage(local: local, cloud: cloud).load().codeThemeID == "solarized")
    }

    @Test func fallsBackToLocalThenDefaults() {
        let local = MemoryStorage()
        #expect(AppearanceStorage(local: local, cloud: MemoryStorage()).load() == AppearanceSettings())
        var settings = AppearanceSettings()
        settings.sizeScale = 1.2
        AppearanceStorage(local: local, cloud: nil).save(settings)
        #expect(AppearanceStorage(local: local, cloud: MemoryStorage()).load().sizeScale == 1.2)
    }

    @Test func corruptDataIsIgnored() {
        let local = MemoryStorage()
        local.values[AppearanceStorage.key] = Data("not json".utf8)
        #expect(AppearanceStorage(local: local, cloud: nil).load() == AppearanceSettings())
    }

    /// Spec 11, principle 4: every built-in theme is readable in light and dark.
    @Test(arguments: CodeTheme.builtIn)
    func builtInThemesHaveReadableContrast(theme: CodeTheme) {
        for scope in SyntaxScope.allCases {
            let style = theme.style(for: scope)
            #expect(style != nil, "\(theme.name) has no style for \(scope)")
            guard let style else { continue }
            #expect(style.color.light.contrast(with: theme.background.light) >= 4.5, "\(theme.name) light \(scope)")
            #expect(style.color.dark.contrast(with: theme.background.dark) >= 4.5, "\(theme.name) dark \(scope)")
        }
        #expect(theme.text.light.contrast(with: theme.background.light) >= 4.5)
        #expect(theme.text.dark.contrast(with: theme.background.dark) >= 4.5)
    }
}
