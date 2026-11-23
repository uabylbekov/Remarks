import Foundation
import Testing
@testable import RemarksCore

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
        settings.codeThemeID = "monokai"
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

    @Test func lineHeightMapsCleanlyToLineSpacingAndClamps() {
        var settings = AppearanceSettings()
        #expect(settings.lineHeight == AppearanceSettings.defaultLineHeight)

        settings.lineHeight = 1.4
        #expect(settings.lineSpacing == 0.4)
        #expect(settings.lineHeight == 1.4)

        settings.lineHeight = AppearanceSettings.defaultLineHeight
        #expect(settings.lineSpacing == 0.15)
        #expect(settings == AppearanceSettings())

        settings.lineHeight = 0.5
        #expect(settings.lineHeight == AppearanceSettings.lineHeightRange.lowerBound)
        #expect(settings.lineSpacing == AppearanceSettings.lineSpacingRange.lowerBound)

        settings.lineHeight = 2.5
        #expect(settings.lineHeight == AppearanceSettings.lineHeightRange.upperBound)
        #expect(settings.lineSpacing == AppearanceSettings.lineSpacingRange.upperBound)
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
        fromOtherDevice.codeThemeID = "monokai"
        AppearanceStorage(local: MemoryStorage(), cloud: cloud).save(fromOtherDevice)

        #expect(AppearanceStorage(local: local, cloud: cloud).load().codeThemeID == "monokai")
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

/// Spec 11, F2: the code fonts offered in Settings.
struct CodeFontTests {
    @Test func everyOptionHasAUniqueIDAndName() {
        #expect(Set(CodeFonts.all.map(\.id)).count == CodeFonts.all.count)
        #expect(Set(CodeFonts.all.map(\.name)).count == CodeFonts.all.count)
    }

    @Test func theDefaultCodeFontIsTheFirstOption() {
        #expect(CodeFonts.all.first?.choice == AppearanceSettings().codeFont)
    }

    @Test func everyBundledOptionHasItsRegularFaceInTheBundledFiles() {
        for option in CodeFonts.all where option.isBundled {
            guard case .custom(let postScriptName, _) = option.choice else {
                Issue.record("\(option.name) is bundled but not a named font")
                continue
            }
            #expect(CodeFonts.bundledFileNames.contains(postScriptName), "\(option.name)")
        }
    }

    @Test func bundledFilesAreListedOnce() {
        #expect(Set(CodeFonts.bundledFileNames).count == CodeFonts.bundledFileNames.count)
    }

    @Test func aSavedChoiceMapsBackToItsOption() {
        let fira = CodeFonts.all.first { $0.id == "fira-code" }
        #expect(fira != nil)
        #expect(CodeFonts.option(for: fira?.choice ?? .system)?.name == "Fira Code")
        #expect(CodeFonts.option(for: .custom(postScriptName: "Unknown", family: "Unknown")) == nil)
    }
}

struct AppearanceCompatibilityTests {
    @Test func settingsSavedBeforeLigaturesWereAddedStillLoad() throws {
        let old = #"{"textFont":{"system":{}},"codeFont":{"design":{"_0":"monospaced"}},"sizeScale":1.2,"lineSpacing":0.3,"codeThemeID":"solarized"}"#
        let settings = try JSONDecoder().decode(AppearanceSettings.self, from: Data(old.utf8))
        #expect(settings.sizeScale == 1.2)
        #expect(settings.lineSpacing == 0.3)
        #expect(settings.codeThemeID == "solarized")
        #expect(settings.codeLigatures)
    }

    /// A newer app version may save a font design this version does not know. That one choice falls back to its
    /// default; the rest of the settings still load, so a save never wipes them.
    @Test func anUnknownFontDesignKeepsTheOtherSettings() throws {
        let newer = #"{"textFont":{"design":{"_0":"handwritten"}},"codeFont":{"design":{"_0":"monospaced"}},"sizeScale":1.4,"lineSpacing":0.3,"codeThemeID":"github"}"#
        let settings = try JSONDecoder().decode(AppearanceSettings.self, from: Data(newer.utf8))
        #expect(settings.textFont == AppearanceSettings().textFont)
        #expect(settings.sizeScale == 1.4)
        #expect(settings.lineSpacing == 0.3)
        #expect(settings.codeThemeID == "github")
    }

    @Test func ligaturesRoundTrip() throws {
        var settings = AppearanceSettings()
        settings.codeLigatures = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data).codeLigatures == false)
    }
}

