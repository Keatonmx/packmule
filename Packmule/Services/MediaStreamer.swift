//
//  MediaStreamer.swift
//  Packmule
//
//  A tiny HTTP server on 127.0.0.1 that turns the player's byte range
//  requests into seekable reads on the active volume.
//
//  Lessons baked in (audio was failing with AVFoundation -11850 and
//  OSStatus -12939, both "the server misbehaved"):
//    • ONE shared reader per stream, not one per request. Audio parsing
//      fires dozens of small ranged requests; opening a fresh SMB session
//      for each invited hiccups, and a hiccup after the header was sent is
//      a truncated body, which is exactly what -12939 flags.
//    • Do the FIRST read before sending the header, so a failing read is a
//      clean 500 instead of a lying 206.
//    • Never close cleanly short: if a mid stream read dies, abort the
//      connection so the player retries, instead of ending the body early.
//    • Keep a couple of recent stream URLs alive; replacing a stream must
//      not 404 a URL the player is still probing.
//

import Foundation
import Network

@MainActor
final class MediaStreamer {
    static let shared = MediaStreamer()

    private struct Target {
        let token: String
        let entry: FileEntry
        let reader: RandomAccessReader
        let size: Int64
        let mime: String
    }

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var targets: [String: Target] = [:]
    private var tokenOrder: [String] = []

    private init() {}

    /// Prepares `entry` for streaming and returns its local playback URL,
    /// or nil when the volume has no seekable access.
    func makeURL(entry: FileEntry, volume: RemoteVolume) async throws -> URL? {
        guard let reader = try await volume.reader(for: entry) else { return nil }
        // The open file's own size beats the (possibly stale) listing size:
        // a wrong total makes every Content-Range a lie.
        let size = reader.size > 0 ? reader.size : (entry.size ?? -1)
        guard size > 0 else {
            await reader.close()
            return nil
        }

        let port = try await ensureListener()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        targets[token] = Target(token: token, entry: entry, reader: reader,
                                size: size, mime: Self.mime(for: entry.name))
        tokenOrder.append(token)
        while tokenOrder.count > 2 {
            let old = tokenOrder.removeFirst()
            if let evicted = targets.removeValue(forKey: old) {
                let reader = evicted.reader
                Task { await reader.close() }
            }
        }
        let name = entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")
    }

    /// Player closed: stop answering and release the volume connections.
    func clearTarget() {
        for (_, target) in targets {
            let reader = target.reader
            Task { await reader.close() }
        }
        targets = [:]
        tokenOrder = []
    }

    // MARK: listener

    private func ensureListener() async throws -> UInt16 {
        if listener != nil, port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let snapshot = MediaStreamer.shared.targets
                Self.serve(connection, targets: snapshot)
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

    private nonisolated static func serve(_ conn: NWConnection, targets: [String: Target]) {
        conn.start(queue: .global(qos: .userInitiated))
        Task {
            do {
                let head = try await readHead(conn)
                let lines = head.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
                guard let requestLine = lines.first else { throw VolumeError.protocolFailure("empty request") }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { throw VolumeError.protocolFailure("bad request") }
                let method = String(parts[0]).uppercased()
                let path = String(parts[1])

                let token = path.split(separator: "/").first.map(String.init) ?? ""
                guard let target = targets[token] else {
                    try await send(conn, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    conn.cancel()
                    return
                }

                // Range: bytes=start-end, bytes=start-, or bytes=-suffix
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

                if method == "HEAD" {
                    try await send(conn, Data(header.utf8))
                    conn.cancel()
                    return
                }

                // First read BEFORE the header: if the volume balks, answer
                // 500 honestly instead of a 206 with a missing body.
                let firstWant = Int(min(1 << 20, length))
                var firstChunk: Data
                do {
                    firstChunk = try await target.reader.read(offset: start, length: firstWant)
                } catch {
                    try await send(conn, Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    conn.cancel()
                    return
                }
                guard !firstChunk.isEmpty else {
                    try await send(conn, Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    conn.cancel()
                    return
                }

                try await send(conn, Data(header.utf8))
                try await send(conn, firstChunk)
                var offset = start + Int64(firstChunk.count)

                while offset <= end {
                    let want = Int(min(1 << 20, end - offset + 1))
                    var chunk = try await reader(target, offset: offset, length: want)
                    if chunk.isEmpty {
                        // One polite retry; servers hiccup.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        chunk = try await reader(target, offset: offset, length: want)
                    }
                    if chunk.isEmpty {
                        // Never end the body short and pretend it's fine: abort
                        // so the player retries with a fresh request.
                        conn.forceCancel()
                        return
                    }
                    try await send(conn, chunk)
                    offset += Int64(chunk.count)
                }
                conn.cancel()
            } catch {
                conn.forceCancel()
            }
        }
    }

    private nonisolated static func reader(_ target: Target, offset: Int64, length: Int) async throws -> Data {
        try await target.reader.read(offset: offset, length: length)
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
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}
