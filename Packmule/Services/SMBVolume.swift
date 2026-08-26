//
//  SMBVolume.swift
//  Packmule
//
//  SMB2/3 shares via AMSMB2 (libsmb2 underneath). Two modes:
//    • fixed share: the saved server named one (smb://host/media), the volume
//      root is that share's root.
//    • browse mode: the share field was left empty, the volume root lists the
//      server's shares as folders and connects as you step into one.
//

import Foundation
import AMSMB2

final class SMBVolume: RemoteVolume {
    let kindLabel = "SMB"

    private let host: String
    private let port: Int?
    /// nil = browse mode.
    private let fixedShare: String?
    private let credential: URLCredential
    private var client: SMB2Manager?
    private var connectedShare: String?

    init(host: String, port: Int?, share: String?, username: String, password: String) {
        self.host = host
        self.port = port
        self.fixedShare = (share?.isEmpty == false) ? share : nil
        let user = username.isEmpty ? "guest" : username
        self.credential = URLCredential(user: user, password: password, persistence: .forSession)
    }

    func connect() async throws {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        comps.port = port
        guard let url = comps.url, let manager = SMB2Manager(url: url, credential: credential) else {
            throw VolumeError.badAddress
        }
        manager.timeout = 30
        client = manager
        if let share = fixedShare {
            try await manager.connectShare(name: share)
            connectedShare = share
        } else {
            // Validates reachability and the sign-in without picking a share yet.
            _ = try await manager.listShares()
        }
    }

    // MARK: path mapping

    private func requireClient() throws -> SMB2Manager {
        guard let client else { throw VolumeError.disconnected }
        return client
    }

    /// Volume path -> (share, share-relative path). Throws at the browse-mode
    /// root, where there is no share to act inside.
    private func target(_ path: String) throws -> (share: String, rel: String) {
        if let fixedShare {
            return (fixedShare, VolumePath.components(path).joined(separator: "/"))
        }
        let comps = VolumePath.components(path)
        guard let first = comps.first else { throw VolumeError.unsupported("changing the share list") }
        return (first, comps.dropFirst().joined(separator: "/"))
    }

    private func ensureShare(_ name: String) async throws {
        let client = try requireClient()
        guard connectedShare != name else { return }
        if connectedShare != nil { try? await client.disconnectShare() }
        connectedShare = nil
        try await client.connectShare(name: name)
        connectedShare = name
    }

    // MARK: operations

    func list(_ path: String) async throws -> [FileEntry] {
        if fixedShare == nil, path == "/" || path.isEmpty {
            let shares = try await requireClient().listShares()
            return shares.compactMap { share in
                // Hide admin shares (C$, ADMIN$, IPC$ and friends).
                share.name.hasSuffix("$") ? nil
                    : FileEntry(name: share.name, path: "/" + share.name, isDirectory: true)
            }
        }
        let (share, rel) = try target(path)
        try await ensureShare(share)
        let items = try await requireClient().contentsOfDirectory(atPath: rel)
        return items.compactMap { Self.entry(from: $0, parent: path) }
    }

    private static func entry(from item: [URLResourceKey: Any], parent: String) -> FileEntry? {
        guard let name = item[.nameKey] as? String, !name.isEmpty, name != ".", name != ".." else { return nil }
        let type = item[.fileResourceTypeKey] as? URLFileResourceType
        let isDir = type == .directory
        let size = (item[.fileSizeKey] as? Int64) ?? (item[.fileSizeKey] as? NSNumber)?.int64Value
        let modified = item[.contentModificationDateKey] as? Date
        return FileEntry(name: name, path: VolumePath.join(parent, name), isDirectory: isDir,
                         size: isDir ? nil : size, modified: modified)
    }

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        let (share, rel) = try target(entry.path)
        try await ensureShare(share)
        try await requireClient().downloadItem(atPath: rel, to: url) { bytes, total in
            progress(bytes, total)
        }
    }

    func download(_ entry: FileEntry, to url: URL, resumingFrom offset: Int64,
                  progress: @escaping TransferProgress) async throws {
        guard offset > 0 else {
            try await download(entry, to: url, progress: progress)
            return
        }
        let (share, rel) = try target(entry.path)
        try await ensureShare(share)
        let client = try requireClient()
        let total = entry.size ?? -1
        let handle = try appendHandle(for: url, at: offset)
        defer { try? handle.close() }
        var position = offset
        let chunk: Int64 = 4 * 1024 * 1024
        while total < 0 || position < total {
            let end = total < 0 ? position + chunk : min(position + chunk, total)
            let data = try await client.contents(atPath: rel,
                                                 range: UInt64(position)..<UInt64(end),
                                                 progress: nil)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            position += Int64(data.count)
            if !progress(position, total) { throw VolumeError.cancelled }
        }
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        let (share, relDir) = try target(VolumePath.join(dir, name))
        try await ensureShare(share)
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs?[.size] as? Int64) ?? -1
        try await requireClient().uploadItem(at: localURL, toPath: relDir) { bytes in
            progress(bytes, total)
        }
    }

    func delete(_ entry: FileEntry) async throws {
        let (share, rel) = try target(entry.path)
        try await ensureShare(share)
        if entry.isDirectory {
            try await requireClient().removeDirectory(atPath: rel, recursive: true)
        } else {
            try await requireClient().removeFile(atPath: rel)
        }
    }

    func createFolder(named name: String, in dir: String) async throws {
        let (share, rel) = try target(VolumePath.join(dir, name))
        try await ensureShare(share)
        try await requireClient().createDirectory(atPath: rel)
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        let (share, rel) = try target(entry.path)
        let (_, relNew) = try target(VolumePath.join(VolumePath.parent(of: entry.path), newName))
        try await ensureShare(share)
        try await requireClient().moveItem(atPath: rel, toPath: relNew)
    }

    func disconnect() async {
        if connectedShare != nil { try? await client?.disconnectShare() }
        connectedShare = nil
        client = nil
    }

    func reader(for entry: FileEntry) async throws -> RandomAccessReader? {
        let (share, rel) = try target(entry.path)
        try await ensureShare(share)
        let client = try requireClient()
        var size = entry.size ?? -1
        if size < 0 {
            let attrs = try await client.attributesOfItem(atPath: rel)
            size = (attrs[.fileSizeKey] as? Int64)
                ?? (attrs[.fileSizeKey] as? NSNumber)?.int64Value
                ?? -1
        }
        guard size >= 0 else { return nil }
        return SMBRandomReader(client: client, path: rel, size: size)
    }
}

/// Ranged reads straight off the share; each call is an independent
/// open + read, which libsmb2 handles happily at streaming chunk sizes.
final class SMBRandomReader: RandomAccessReader {
    private let client: SMB2Manager
    private let path: String
    let size: Int64

    init(client: SMB2Manager, path: String, size: Int64) {
        self.client = client
        self.path = path
        self.size = size
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset < size, length > 0 else { return Data() }
        let start = UInt64(offset)
        let end = min(start + UInt64(length), UInt64(size))
        return try await client.contents(atPath: path, range: start..<end, progress: nil)
    }

    func close() async {}
}
