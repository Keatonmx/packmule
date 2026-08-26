//
//  RemoteVolume.swift
//  Packmule
//
//  One protocol for every place files live: an SMB share, an FTP server, the
//  phone's own Documents folder, or the demo data CI screenshots use. The
//  browser never knows which one it is talking to.
//

import Foundation

enum VolumeError: LocalizedError {
    case badAddress
    case cancelled
    case disconnected
    case authFailed
    case notFound(String)
    case unsupported(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "That address doesn't look right"
        case .cancelled: return "Cancelled"
        case .disconnected: return "The server closed the connection"
        case .authFailed: return "The server rejected the user or password"
        case .notFound(let name): return "Not found: \(name)"
        case .unsupported(let what): return "Not supported here: \(what)"
        case .protocolFailure(let detail): return detail
        }
    }
}

/// Progress callback: (bytes so far, total bytes or -1). Return false to cancel.
typealias TransferProgress = (Int64, Int64) -> Bool

protocol RemoteVolume: AnyObject {
    /// "SMB", "FTP", "This iPhone"; shown as the browser's little kind badge.
    var kindLabel: String { get }
    /// Local volumes preview and share in place instead of downloading first.
    var isLocal: Bool { get }
    /// Read-only volumes (Photos) hide upload, rename, delete and new folder.
    var isReadOnly: Bool { get }

    func connect() async throws
    func list(_ path: String) async throws -> [FileEntry]
    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws
    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws
    func delete(_ entry: FileEntry) async throws
    func createFolder(named name: String, in dir: String) async throws
    func rename(_ entry: FileEntry, to newName: String) async throws
    func disconnect() async

    /// The on-disk URL for an entry, when the volume is the phone itself.
    func localURL(for entry: FileEntry) -> URL?

    /// Seekable byte access for media streaming; nil when the volume can't
    /// seek (plain FTP). Each caller gets its own reader and must close it.
    func reader(for entry: FileEntry) async throws -> RandomAccessReader?
}

/// A seekable byte source feeding the in-app streaming bridge.
protocol RandomAccessReader: AnyObject {
    var size: Int64 { get }
    func read(offset: Int64, length: Int) async throws -> Data
    func close() async
}

extension RemoteVolume {
    var isLocal: Bool { false }
    var isReadOnly: Bool { false }
    func localURL(for entry: FileEntry) -> URL? { nil }
    func reader(for entry: FileEntry) async throws -> RandomAccessReader? { nil }
}
