//
//  AppSettings.swift
//  Packmule
//
//  All user settings, persisted as one Codable blob in UserDefaults.
//

import Foundation

struct AppSettings: Codable, Equatable {
    // Appearance (fresh installs boot in the icon's own look)
    var theme: ThemeName = .mule
    var haptics = true

    // Browsing
    var sort: BrowseSort = .name
    var foldersFirst = true
    var showHidden = false
    /// Optional in storage so older saved settings still decode.
    var tidyROMNamesRaw: Bool? = true
    var tidyROMNames: Bool {
        get { tidyROMNamesRaw ?? true }
        set { tidyROMNamesRaw = newValue }
    }
    var tidySongNamesRaw: Bool? = true
    var tidySongNames: Bool {
        get { tidySongNamesRaw ?? true }
        set { tidySongNamesRaw = newValue }
    }

    // Transfers
    var keepAwakeWhileHauling = true

    // Safety
    var confirmDelete = true
}

enum SettingsStore {
    private static let key = "packmule.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
