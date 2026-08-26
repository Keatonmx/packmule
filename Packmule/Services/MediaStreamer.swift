//
//  MediaStreamer.swift
//  Packmule
//
//  A tiny HTTP server on 127.0.0.1 that turns the player's byte range
//  requests into seekable reads on the active volume. This is what lets a
//  movie on the SMB share start playing, and scrub, without downloading.
//

import Foundation
import Network

@MainActor
final class MediaStreamer {
    static let shared = MediaStreamer()

    private struct Target {
        let token: String
        let entry: FileEntry
        let volume: RemoteVolume
        let size: Int64
        let mime: String
    }

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var target: Target?

    private init() {}

    /// Prepares `entry` for streaming and returns its local playback URL,
    /// or nil when the volume has no seekable access.
    func makeURL(entry: FileEntry, volume: RemoteVolume) async throws -> URL? {
        guard let probe = try await volume.reader(for: entry) else { return nil }
        let size = entry.size.flatMap { $0 > 0 ? $0 : nil } ?? probe.size
        await probe.close()
        guard size > 0 else { return nil }

        let port = try await ensureListener()
        let token = UUID().uuidString.prefix(8).lowercased()
        target = Target(token: String(token), entry: entry, volume: volume,
                        size: size, mime: Self.mime(for: entry.name))
        let name = entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")
    }

    /// Old URLs stop answering; the listener stays warm for the next play.
    func clearTarget() {
        target = nil
    }

    // MARK: listener

    private func ensureListener() async throws -> UInt16 {
        if listener != nil, port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let snapshot = MediaStreamer.shared.target
                Self.serve(connection, target: snapshot)
            }
        }
        self.listener = listener
        port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trip() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.trip() { cont.resume(throwing: error) }
                case .cancelled:
                    if once.trip() { cont.resume(throwing: VolumeError.cancelled) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        guard port != 0 else { throw VolumeError.protocolFailure("Couldn't start the stream bridge") }
        return port
    }

    // MARK: one connection

    private nonisolated static func serve(_ conn: NWConnection, target: Target?) {
        conn.start(queue: .global(qos: .userInitiated))
        Task {
            var reader: RandomAccessReader?
            do {
                let head = try await readHead(conn)
                let lines = head.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
                guard let requestLine = lines.first else { throw VolumeError.protocolFailure("empty request") }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { throw VolumeError.protocolFailure("bad request") }
                let method = String(parts[0]).uppercased()
                let path = String(parts[1])

                guard let target, path.contains("/\(target.token)/") || path.hasPrefix("/\(target.token)") else {
                    try await send(conn, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    conn.cancel()
                    return
                }

                // Range: bytes=start-end (either side may be missing)
                var start: Int64 = 0
                var end: Int64 = target.size - 1
                var isPartial = false
                if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
                   let eq = rangeLine.firstIndex(of: "=") {
                    isPartial = true
                    let spec = rangeLine[rangeLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    let sides = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    let left = sides.count > 0 ? Int64(sides[0]) : nil
                    let right = sides.count > 1 ? Int64(sides[1]) : nil
                    if let left {
                        start = left
                        if let right { end = right }
                    } else if let right {
                        // suffix range: last N bytes
                        start = max(0, target.size - right)
                    }
                }
                start = max(0, min(start, target.size - 1))
                end = max(start, min(end, target.size - 1))
                let length = end - start + 1

                var header = isPartial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: \(target.mime)\r\n"
                header += "Accept-Ranges: bytes\r\n"
                header += "Content-Length: \(length)\r\n"
                if isPartial {
                    header += "Content-Range: bytes \(start)-\(end)/\(target.size)\r\n"
                }
                header += "Connection: close\r\n\r\n"
                try await send(conn, Data(header.utf8))

                if method != "HEAD" {
                    reader = try await target.volume.reader(for: target.entry)
                    guard let reader else { throw VolumeError.protocolFailure("no reader") }
                    var offset = start
                    while offset <= end {
                        let want = Int(min(1 << 20, end - offset + 1))
                        let chunk = try await reader.read(offset: offset, length: want)
                        if chunk.isEmpty { break }
                        try await send(conn, chunk)
                        offset += Int64(chunk.count)
                    }
                }
                conn.cancel()
            } catch {
                conn.cancel()
            }
            if let reader { await reader.close() }
        }
    }

    private nonisolated static func readHead(_ conn: NWConnection) async throws -> String {
        var data = Data()
        let marker = Data("\r\n\r\n".utf8)
        while data.range(of: marker) == nil {
            let (chunk, complete) = try await receive(conn)
            if chunk.isEmpty {
                if complete { break }
                continue
            }
            data.append(chunk)
            if data.count > 32_768 { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func receive(_ conn: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (data ?? Data(), complete))
                }
            }
        }
    }

    private nonisolated static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: types

    static func mime(for name: String) -> String {
        switch MediaFile.ext(name) {
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "mov": return "video/quicktime"
        case "3gp": return "video/3gpp"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}
