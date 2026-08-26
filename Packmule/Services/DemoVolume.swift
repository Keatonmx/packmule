//
//  DemoVolume.swift
//  Packmule
//
//  Fake media-server listing used by the CI simulator screenshots
//  (-packmule-demo). Never reachable from normal UI.
//

import Foundation

final class DemoVolume: RemoteVolume {
    let kindLabel = "SMB"

    private let tree: [String: [FileEntry]] = {
        func date(_ daysAgo: Double) -> Date { Date(timeIntervalSinceNow: -daysAgo * 86_400) }
        func file(_ dir: String, _ name: String, _ mb: Double, _ daysAgo: Double) -> FileEntry {
            FileEntry(name: name, path: VolumePath.join(dir, name), isDirectory: false,
                      size: Int64(mb * 1_048_576), modified: date(daysAgo))
        }
        func folder(_ dir: String, _ name: String, _ daysAgo: Double) -> FileEntry {
            FileEntry(name: name, path: VolumePath.join(dir, name), isDirectory: true, modified: date(daysAgo))
        }
        return [
            "/": [
                folder("/", "Movies", 2), folder("/", "Shows", 0.4), folder("/", "Music", 12),
                folder("/", "Photos", 5), folder("/", "Backups", 30),
                file("/", "family-trip-2019.mp4", 1_433, 90),
                file("/", "notes.txt", 0.01, 1),
            ],
            "/Movies": [
                file("/Movies", "The Iron Giant (1999).mkv", 4_812, 200),
                file("/Movies", "Spirited Away (2001).mkv", 5_310, 150),
                file("/Movies", "Mad Max Fury Road (2015).mkv", 7_945, 88),
                file("/Movies", "Paddington 2 (2017).mkv", 4_020, 30),
                file("/Movies", "The Mitchells vs the Machines (2021).mkv", 6_120, 12),
            ],
            "/Shows": [
                folder("/Shows", "Severance", 3), folder("/Shows", "Andor", 9),
                folder("/Shows", "Planet Earth III", 40),
            ],
            "/Music": [
                folder("/Music", "Vinyl rips", 60), folder("/Music", "Mixtapes", 21),
                file("/Music", "roadtrip.m3u", 0.004, 21),
            ],
            "/Photos": [
                folder("/Photos", "2024", 100), folder("/Photos", "2025", 40), folder("/Photos", "2026", 4),
            ],
            "/Backups": [
                file("/Backups", "keaton-pc-2026-08-01.zip", 68_400, 24),
                file("/Backups", "router-config.bak", 0.2, 60),
            ],
        ]
    }()

    func connect() async throws {}

    func list(_ path: String) async throws -> [FileEntry] {
        try? await Task.sleep(nanoseconds: 150_000_000)
        return tree[path] ?? []
    }

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        let total = entry.size ?? 1_000_000
        for step in 1...20 {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !progress(total * Int64(step) / 20, total) { throw VolumeError.cancelled }
        }
        FileManager.default.createFile(atPath: url.path, contents: Data("demo".utf8))
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        _ = progress(1, 1)
    }

    func delete(_ entry: FileEntry) async throws {}
    func createFolder(named name: String, in dir: String) async throws {}
    func rename(_ entry: FileEntry, to newName: String) async throws {}
    func disconnect() async {}
}
