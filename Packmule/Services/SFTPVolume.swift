//
//  SFTPVolume.swift
//  Packmule
//
//  SFTP (file transfer over SSH) via Citadel. Password auth, chunked reads
//  and writes with progress, recursive folder delete. Host keys are accepted
//  on first contact in this version.
//

import Foundation
import Citadel
import NIOCore

final class SFTPVolume: RemoteVolume {
    let kindLabel = "SFTP"

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    /// One SFTP request at a time keeps the channel simple and predictable.
    private let gate = AsyncGate()

    init(host: String, port: Int?, username: String, password: String) {
        self.host = host
        self.port = port ?? 22
        self.username = username.isEmpty ? "root" : username
        self.password = password
    }

    func connect() async throws {
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never)
        ssh = client
        sftp = try await client.openSFTP()
    }

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp else { throw VolumeError.disconnected }
        return sftp
    }

    // MARK: operations

    func list(_ path: String) async throws -> [FileEntry] {
        await gate.acquire()
        defer { Task { await gate.release() } }
        return try await rawList(path)
    }

    private func rawList(_ path: String) async throws -> [FileEntry] {
        let sftp = try requireSFTP()
        let names = try await sftp.listDirectory(atPath: path.isEmpty ? "/" : path)
        var entries: [FileEntry] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                guard !filename.isEmpty, filename != ".", filename != ".." else { continue }
                let attrs = component.attributes
                // POSIX file-type bits: 0x4000 is a directory.
                let isDir = ((attrs.permissions ?? 0) & 0xF000) == 0x4000
                entries.append(FileEntry(
                    name: filename,
                    path: VolumePath.join(path, filename),
                    isDirectory: isDir,
                    size: isDir ? nil : attrs.size.map { Int64(clamping: $0) },
                    modified: attrs.accessModificationTime?.modificationTime))
            }
        }
        return entries
    }

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        let sftp = try requireSFTP()
        let file = try await sftp.openFile(filePath: entry.path, flags: .read)
        var failure: Error?
        do {
            let attrs = try? await file.readAttributes()
            let total = (attrs?.size).map { Int64(clamping: $0) } ?? entry.size ?? -1
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            let chunkSize: UInt32 = 512 * 1024
            while true {
                let buffer = try await file.read(from: offset, length: chunkSize)
                let count = buffer.readableBytes
                if count == 0 { break }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(count)
                if !progress(Int64(clamping: offset), total) {
                    throw VolumeError.cancelled
                }
            }
        } catch {
            failure = error
        }
        try? await file.close()
        if let failure { throw failure }
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        let sftp = try requireSFTP()
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs?[.size] as? Int64) ?? -1
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: VolumePath.join(dir, name),
                                           flags: [.write, .create, .truncate])
        var failure: Error?
        var sent: UInt64 = 0
        do {
            while true {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try await file.write(ByteBuffer(bytes: chunk), at: sent)
                sent += UInt64(chunk.count)
                if !progress(Int64(clamping: sent), total) {
                    throw VolumeError.cancelled
                }
            }
        } catch {
            failure = error
        }
        try? await file.close()
        if let failure { throw failure }
    }

    func delete(_ entry: FileEntry) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        try await deleteRecursively(path: entry.path, isDirectory: entry.isDirectory)
    }

    private func deleteRecursively(path: String, isDirectory: Bool) async throws {
        let sftp = try requireSFTP()
        if isDirectory {
            for child in try await rawList(path) {
                try await deleteRecursively(path: child.path, isDirectory: child.isDirectory)
            }
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    func createFolder(named name: String, in dir: String) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        try await requireSFTP().createDirectory(atPath: VolumePath.join(dir, name))
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        try await requireSFTP().rename(at: entry.path,
                                       to: VolumePath.join(VolumePath.parent(of: entry.path), newName))
    }

    func disconnect() async {
        if let sftp { try? await sftp.close() }
        if let ssh { try? await ssh.close() }
        sftp = nil
        ssh = nil
    }

    /// Streaming gets its own SSH connection so browsing stays responsive.
    func reader(for entry: FileEntry) async throws -> RandomAccessReader? {
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never)
        do {
            let sftp = try await client.openSFTP()
            let file = try await sftp.openFile(filePath: entry.path, flags: .read)
            let attrs = try? await file.readAttributes()
            let size = (attrs?.size).map { Int64(clamping: $0) } ?? entry.size ?? -1
            guard size >= 0 else {
                try? await file.close()
                try? await sftp.close()
                try? await client.close()
                return nil
            }
            return SFTPRandomReader(ssh: client, sftp: sftp, file: file, size: size)
        } catch {
            try? await client.close()
            throw error
        }
    }
}

final class SFTPRandomReader: RandomAccessReader {
    private let ssh: SSHClient
    private let sftp: SFTPClient
    private let file: SFTPFile
    let size: Int64

    init(ssh: SSHClient, sftp: SFTPClient, file: SFTPFile, size: Int64) {
        self.ssh = ssh
        self.sftp = sftp
        self.file = file
        self.size = size
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset < size, length > 0 else { return Data() }
        var collected = Data()
        // The server caps a single SFTP read, so accumulate short reads.
        while collected.count < length {
            let want = UInt32(clamping: length - collected.count)
            let buffer = try await file.read(from: UInt64(offset) + UInt64(collected.count),
                                             length: min(want, 256 * 1024))
            if buffer.readableBytes == 0 { break }
            collected.append(Data(buffer.readableBytesView))
        }
        return collected
    }

    func close() async {
        try? await file.close()
        try? await sftp.close()
        try? await ssh.close()
    }
}

/// Tiny polling mutex for whole operations (actors alone are reentrant).
actor AsyncGate {
    private var busy = false

    func acquire() async {
        while busy {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        busy = true
    }

    func release() {
        busy = false
    }
}
