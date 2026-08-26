//
//  LinkedFolders.swift
//  Packmule
//
//  Folders the user picked in the Files app. iOS sandboxes every app to its
//  own container; a folder picked through the document picker comes with a
//  security-scoped bookmark that grants durable access to that one tree.
//  Linked folders are browsable in the app and mounted by the hosted FTP
//  server.
//

import Foundation

struct LinkedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Display name; also the mount name at the FTP server's root.
    var name: String
    var bookmark: Data
}

enum LinkedFolderStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("linked-folders.json")
    }

    static func load() -> [LinkedFolder] {
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? JSONDecoder().decode([LinkedFolder].self, from: data) else {
            return []
        }
        return folders
    }

    static func save(_ folders: [LinkedFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Bookmark -> URL. The caller is responsible for start/stop of the
    /// security scope around actual use.
    static func resolve(_ folder: LinkedFolder) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return url
    }
}
