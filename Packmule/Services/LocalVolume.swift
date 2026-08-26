//
//  LocalVolume.swift
//  Packmule
//
//  The phone's own Documents folder as a volume. Documents is exposed to the
//  Files app (UIFileSharingEnabled), so everything here is also visible under
//  On My iPhone › Packmule. Downloads from servers land in /Downloads.
//

import Foundation

enum LocalFiles {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloadsURL: URL {
        let url = documentsURL.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Caches/Preview: temporary copies fetched for Quick Look and sharing.
    static var previewURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "Movie.mp4" -> "Movie 2.mp4" until the name is free in `dir`.
    static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = dir.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}

final class LocalVolume: RemoteVolume {
    let kindLabel: String
    var isLocal: Bool { true }
    private let root: URL
    /// Linked folders come from Files-picker bookmarks and need the security
    /// scope held open while we browse them.
    private let securityScoped: Bool
    private var scopeActive = false

    init(root: URL = LocalFiles.documentsURL, securityScoped: Bool = false, kindLabel: String = "Local") {
        self.root = root
        self.securityScoped = securityScoped
        self.kindLabel = kindLabel
    }

    func connect() async throws {
        if securityScoped {
            guard root.startAccessingSecurityScopedResource() else {
                throw VolumeError.protocolFailure("Lost access to that folder. Unlink it, then link it again from Files")
            }
            scopeActive = true
        }
        _ = LocalFiles.downloadsURL   // make sure it exists so the app root isn't empty
    }

    private func url(for path: String) -> URL {
        var u = root
        for part in VolumePath.components(path) { u.appendPathComponent(part) }
        return u
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let dir = url(for: path)
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [])
        return items.map { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            return FileEntry(name: item.lastPathComponent,
                             path: VolumePath.join(path, item.lastPathComponent),
                             isDirectory: isDir,
                             size: isDir ? nil : (values?.fileSize).map(Int64.init),
                             modified: values?.contentModificationDate)
        }
    }

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        throw VolumeError.unsupported("downloading from this iPhone")
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        let dest = LocalFiles.uniqueDestination(for: name, in: url(for: dir))
        try FileManager.default.copyItem(at: localURL, to: dest)
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        _ = progress(size, size)
    }

    func delete(_ entry: FileEntry) async throws {
        try FileManager.default.removeItem(at: url(for: entry.path))
    }

    func createFolder(named name: String, in dir: String) async throws {
        try FileManager.default.createDirectory(at: url(for: VolumePath.join(dir, name)),
                                                withIntermediateDirectories: false)
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        let from = url(for: entry.path)
        let to = from.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: from, to: to)
    }

    func disconnect() async {
        if scopeActive {
            root.stopAccessingSecurityScopedResource()
            scopeActive = false
        }
    }

    func localURL(for entry: FileEntry) -> URL? { url(for: entry.path) }
}
