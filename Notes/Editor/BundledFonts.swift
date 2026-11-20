import CoreText
import Foundation
import NotesCore

/// Makes the fonts inside the app usable by name (`UIFont(name:)`, `NSFont(name:)`). They are registered for this
/// process only, so nothing is installed on the device. Call once at launch, before any text is styled.
enum BundledFonts {
    @discardableResult
    static func register() -> Int {
        let urls = CodeFonts.bundledFileNames.compactMap {
            Bundle.main.url(forResource: $0, withExtension: "ttf")
                ?? Bundle.main.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard !urls.isEmpty else { return 0 }
        // Already-registered fonts report an error. That is fine and not worth failing for.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return urls.count
    }
}
