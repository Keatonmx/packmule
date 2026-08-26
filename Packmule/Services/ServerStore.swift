//
//  ServerStore.swift
//  Packmule
//
//  Saved servers as one JSON file in Application Support (not Documents, so
//  it never shows up in the Files app). Passwords live in the Keychain.
//

import Foundation

enum ServerStore {
    private static let seedFlag = "packmule.seeded"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    static func load() -> [SavedServer] {
        guard let data = try? Data(contentsOf: fileURL),
              let servers = try? JSONDecoder().decode([SavedServer].self, from: data) else {
            return seedIfNeeded()
        }
        return servers
    }

    static func save(_ servers: [SavedServer]) {
        if let data = try? JSONEncoder().encode(servers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Personal sideload builds start with the home media share already saved,
    /// so the first tap on day one is already "Connect". Public builds (built
    /// without the SIDELOAD condition) start clean.
    private static func seedIfNeeded() -> [SavedServer] {
        guard !UserDefaults.standard.bool(forKey: seedFlag) else { return [] }
        UserDefaults.standard.set(true, forKey: seedFlag)
        #if SIDELOAD
        var home = SavedServer()
        home.kind = .smb
        home.name = "Home media"
        home.host = "10.0.0.253"
        home.share = "media"
        let servers = [home]
        save(servers)
        return servers
        #else
        return []
        #endif
    }
}
