import SwiftUI
import NotesCore

/// The user's appearance choices (Spec 11), kept in iCloud key-value storage with a local copy.
/// Views and the editor read this; changing `settings` saves it and bumps `revision`, which open editors watch.
@MainActor
@Observable
final class AppearanceModel {
    /// The editor's static `EditorTheme` reads from here, so there is exactly one source of truth.
    static let shared = AppearanceModel()

    var settings: AppearanceSettings {
        didSet {
            guard settings != oldValue else { return }
            revision += 1
            if !isApplyingExternalChange { storage.save(settings) }
        }
    }

    /// Increases on every change. An editor compares it with the value it last styled for.
    private(set) var revision = 0

    private let storage = AppearanceStorage()
    private var isApplyingExternalChange = false

    init() {
        settings = storage.load()
        NSUbiquitousKeyValueStore.default.synchronize()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification) {
                self?.reloadFromStorage()
            }
        }
    }

    func reset() {
        settings = AppearanceSettings()
    }

    /// Another device changed the settings (or iCloud delivered them for the first time).
    private func reloadFromStorage() {
        isApplyingExternalChange = true
        settings = storage.load()
        isApplyingExternalChange = false
    }
}
