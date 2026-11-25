import SwiftUI
import RemarksCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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

    private let storage: AppearanceStorage
    private var isApplyingExternalChange = false
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []

    init(storage: AppearanceStorage? = nil) {
        let storage = storage ?? Self.defaultStorage()
        self.storage = storage
        settings = storage.load()
        NSUbiquitousKeyValueStore.default.synchronize()
        observerTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification) {
                self?.reloadFromStorage()
            }
        })
        #if canImport(UIKit)
        // The editor's text size and contrast follow accessibility settings (see `EditorTheme`), so an open editor must style again when they change.
        observerTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIContentSizeCategory.didChangeNotification) {
                self?.revision += 1
            }
        })
        observerTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIAccessibility.darkerSystemColorsStatusDidChangeNotification) {
                self?.revision += 1
            }
        })
        #elseif canImport(AppKit)
        observerTasks.append(Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
                self?.revision += 1
            }
        })
        #endif
    }

    deinit {
        for task in observerTasks { task.cancel() }
    }

    func reset() {
        settings = AppearanceSettings()
    }

    /// Where the running app keeps settings. A preview runs the app's own code, so it gets memory instead: changing a
    /// setting there must never reach the user's saved settings or their iCloud copy.
    private static func defaultStorage() -> AppearanceStorage {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else { return AppearanceStorage() }
        return AppearanceStorage(local: MemorySettingsStorage(), cloud: nil)
    }

    /// Another device changed the settings (or iCloud delivered them for the first time).
    private func reloadFromStorage() {
        isApplyingExternalChange = true
        settings = storage.load()
        isApplyingExternalChange = false
    }
}

/// Settings kept only until the process ends, for previews.
private final class MemorySettingsStorage: SettingsStorage {
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
}

extension EnvironmentValues {
    /// The appearance model for editors and settings views. Defaults to `AppearanceModel.shared`.
    @Entry var appearanceModel: AppearanceModel = .shared
}
