//
//  FTPVolume.swift
//  Packmule
//
//  A small FTP client written on Network.framework, so FTP stays free forever.
//  Passive mode only (EPSV, falling back to PASV), MLSD listings falling back
//  to LIST parsing (Unix and DOS formats). Transfers open their own control
//  connection so browsing stays responsive during a long download.
//

import Foundation
import Network

/// Lock-guarded one-shot flag, safe to trip from connection callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    /// True the first time only.
    func trip() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

// MARK: - Client (one control connection)

actor FTPClient {
    struct Config {
        var host: String
        var port: UInt16 = 21
        var username: String = ""
        var password: String = ""
    }

    private let config: Config
    private var control: NWConnection?
    private var buffer = Data()
    /// Serialises whole FTP operations; actors alone don't (reentrancy).
    private var busy = false

    init(config: Config) {
        self.config = config
    }

    // MARK: connection plumbing

    private static func tcpParams() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 12
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func open(host: String, port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw VolumeError.badAddress }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: Self.tcpParams())
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trip() { cont.resume() }
                case .failed(let error):
                    if once.trip() {
                        conn.cancel()
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    if once.trip() { cont.resume(throwing: VolumeError.cancelled) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        conn.stateUpdateHandler = nil
        return conn
    }

    private func receiveChunk(_ conn: NWConnection) async throws -> (Data, Bool) {
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

    private func sendRaw(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: control channel

    private func readLine() async throws -> String {
        guard let conn = control else { throw VolumeError.disconnected }
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            let (chunk, complete) = try await receiveChunk(conn)
            if chunk.isEmpty, complete { throw VolumeError.disconnected }
            buffer.append(chunk)
        }
    }

    @discardableResult
    private func readReply() async throws -> (code: Int, text: String) {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            if line.count >= 4, let code = Int(line.prefix(3)),
               line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return (code, lines.joined(separator: "\n"))
            }
            if line.count == 3, let code = Int(line) {
                return (code, lines.joined(separator: "\n"))
            }
        }
    }

    @discardableResult
    private func command(_ line: String, allow: [Int]? = nil) async throws -> (code: Int, text: String) {
        guard let conn = control else { throw VolumeError.disconnected }
        try await sendRaw(conn, Data((line + "\r\n").utf8))
        let reply = try await readReply()
        if let allow, !allow.contains(reply.code) {
            throw Self.ftpError(reply)
        }
        return reply
    }

    private static func ftpError(_ reply: (code: Int, text: String)) -> VolumeError {
        let text = reply.text
            .split(whereSeparator: { $0 == "\n" })
            .map { line -> String in
                var l = String(line)
                if l.count >= 4, Int(l.prefix(3)) != nil { l = String(l.dropFirst(4)) }
                return l
            }
            .joined(separator: " ")
        if reply.code == 530 { return .authFailed }
        return .protocolFailure(text.isEmpty ? "FTP error \(reply.code)" : text)
    }

    // MARK: session

    func connect() async throws {
        let conn = try await open(host: config.host, port: config.port)
        control = conn
        buffer.removeAll()
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw Self.ftpError(greeting) }
        let user = config.username.isEmpty ? "anonymous" : config.username
        let pass = config.username.isEmpty ? "packmule@" : config.password
        let userReply = try await command("USER \(user)", allow: [230, 331, 332])
        if userReply.code != 230 {
            try await command("PASS \(pass)", allow: [230, 202])
        }
        _ = try? await command("OPTS UTF8 ON")
        try await command("TYPE I", allow: [200])
    }

    func quit() async {
        _ = try? await command("QUIT")
        control?.cancel()
        control = nil
    }

    /// Whole-operation lock; actor reentrancy would otherwise interleave two
    /// commands on the one control connection.
    private func acquire() async {
        while busy {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        busy = true
    }

    private func release() {
        busy = false
    }

    // MARK: data connections (passive only)

    private func openDataConnection() async throws -> NWConnection {
        if let epsv = try? await command("EPSV", allow: [229]),
           let port = Self.parseEPSV(epsv.text) {
            return try await open(host: config.host, port: port)
        }
        let pasv = try await command("PASV", allow: [227])
        guard let (host, port) = Self.parsePASV(pasv.text) else {
            throw VolumeError.protocolFailure("Could not read the server's PASV reply")
        }
        // Servers behind NAT sometimes advertise a bogus address; dial the
        // host we already know in that case.
        let dialHost = (host == "0.0.0.0") ? config.host : host
        return try await open(host: dialHost, port: port)
    }

    static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.lastIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else { return nil }
        let digits = text[text.index(after: open)..<close].filter { $0.isNumber }
        return UInt16(digits)
    }

    static func parsePASV(_ text: String) -> (String, UInt16)? {
        let nums = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 6 else { return nil }
        let n = Array(nums.suffix(6))
        let port = n[4] * 256 + n[5]
        guard port > 0, port <= 65_535 else { return nil }
        return ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", UInt16(port))
    }

    private func abortTransfer() async {
        _ = try? await command("ABOR")
        _ = try? await readReply()
    }

    /// Runs `cmd`, reads the whole data channel. Chunks go to `sink` when set,
    /// otherwise they are collected and returned.
    private func dataTransfer(_ cmd: String, expectSize: Int64,
                              progress: TransferProgress?, sink: FileHandle?) async throws -> Data {
        let data = try await openDataConnection()
        do {
            _ = try await command(cmd, allow: [125, 150])
            var collected = Data()
            var received: Int64 = 0
            while true {
                let (chunk, complete) = try await receiveChunk(data)
                if !chunk.isEmpty {
                    received += Int64(chunk.count)
                    if let sink {
                        try sink.write(contentsOf: chunk)
                    } else {
                        collected.append(chunk)
                    }
                    if let progress, !progress(received, expectSize) {
                        data.cancel()
                        await abortTransfer()
                        throw VolumeError.cancelled
                    }
                }
                if complete { break }
            }
            data.cancel()
            let done = try await readReply()
            guard done.code == 226 || done.code == 250 else { throw Self.ftpError(done) }
            return collected
        } catch {
            data.cancel()
            throw error
        }
    }

    // MARK: operations

    func list(_ path: String) async throws -> [FileEntry] {
        await acquire()
        defer { release() }
        do {
            let lines = try await textTransfer("MLSD \(path)")
            return lines.compactMap { Self.parseMLSD($0, parent: path) }
        } catch let error as VolumeError {
            guard case .protocolFailure = error else { throw error }
            // No MLSD on this server; LIST it is.
            let lines = try await textTransfer("LIST \(path)")
            return lines.compactMap { Self.parseLIST($0, parent: path) }
        }
    }

    private func textTransfer(_ cmd: String) async throws -> [String] {
        let data = try await dataTransfer(cmd, expectSize: -1, progress: nil, sink: nil)
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map(String.init)
    }

    func download(path: String, to url: URL, expectedSize: Int64,
                  progress: @escaping TransferProgress) async throws {
        await acquire()
        defer { release() }
        var total = expectedSize
        if total <= 0, let reply = try? await command("SIZE \(path)", allow: [213]) {
            total = Int64(reply.text.dropFirst(4).filter { $0.isNumber }) ?? -1
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try await dataTransfer("RETR \(path)", expectSize: total, progress: progress, sink: handle)
    }

    func upload(localURL: URL, toPath path: String, progress: @escaping TransferProgress) async throws {
        await acquire()
        defer { release() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs?[.size] as? Int64) ?? -1
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let data = try await openDataConnection()
        do {
            _ = try await command("STOR \(path)", allow: [125, 150])
            var sent: Int64 = 0
            while true {
                let chunk = try handle.read(upToCount: 1 << 16) ?? Data()
                if chunk.isEmpty { break }
                try await sendRaw(data, chunk)
                sent += Int64(chunk.count)
                if !progress(sent, total) {
                    data.cancel()
                    await abortTransfer()
                    throw VolumeError.cancelled
                }
            }
            // Half-close so the server sees EOF, then wait for its verdict.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                data.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
            let done = try await readReply()
            data.cancel()
            guard done.code == 226 || done.code == 250 else { throw Self.ftpError(done) }
        } catch {
            data.cancel()
            throw error
        }
    }

    func delete(path: String, isDirectory: Bool) async throws {
        await acquire()
        defer { release() }
        if isDirectory {
            try await command("RMD \(path)", allow: [250])
        } else {
            try await command("DELE \(path)", allow: [250])
        }
    }

    func makeDirectory(_ path: String) async throws {
        await acquire()
        defer { release() }
        try await command("MKD \(path)", allow: [257])
    }

    func rename(from: String, to: String) async throws {
        await acquire()
        defer { release() }
        try await command("RNFR \(from)", allow: [350])
        try await command("RNTO \(to)", allow: [250])
    }

    // MARK: listing parsers

    static func parseMLSD(_ line: String, parent: String) -> FileEntry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<space]
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var type = "file"
        var size: Int64?
        var modified: Date?
        for fact in facts.split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "type": type = pair[1].lowercased()
            case "size": size = Int64(pair[1])
            case "modify": modified = mlsdDate(String(pair[1]))
            default: break
            }
        }
        if type == "cdir" || type == "pdir" { return nil }
        let isDir = type == "dir"
        return FileEntry(name: name, path: VolumePath.join(parent, name), isDirectory: isDir,
                         size: isDir ? nil : size, modified: modified)
    }

    static func mlsdDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(raw.prefix(14)))
    }

    static func parseLIST(_ line: String, parent: String) -> FileEntry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        // DOS/IIS style: "08-25-26  09:15PM  <DIR>  name" / "08-25-26  09:15PM  1024 name"
        if let first = fields.first, first.contains("-"), first.first?.isNumber == true {
            let isDir = fields[2] == "<DIR>"
            let size = isDir ? nil : Int64(fields[2])
            let name = fields[3...].joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return FileEntry(name: name, path: VolumePath.join(parent, name), isDirectory: isDir, size: size)
        }
        // Unix style: "drwxr-xr-x  2 user group  4096 Jan  1 12:00 name"
        guard fields.count >= 9, let mode = fields.first?.first, "d-l".contains(mode) else { return nil }
        let isDir = mode == "d"
        var name = fields[8...].joined(separator: " ")
        if mode == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return FileEntry(name: name, path: VolumePath.join(parent, name), isDirectory: isDir,
                         size: isDir ? nil : Int64(fields[4]), modified: listDate(fields))
    }

    private static func listDate(_ fields: [Substring]) -> Date? {
        guard fields.count >= 8 else { return nil }
        let raw = "\(fields[5]) \(fields[6]) \(fields[7])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if fields[7].contains(":") {
            formatter.dateFormat = "MMM d HH:mm"
            guard let parsed = formatter.date(from: raw) else { return nil }
            // The listing omits the year: assume this one, stepping back if
            // that would land in the future.
            var comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: parsed)
            comps.year = Calendar.current.component(.year, from: Date())
            var date = Calendar.current.date(from: comps) ?? parsed
            if date > Date() {
                comps.year = (comps.year ?? 0) - 1
                date = Calendar.current.date(from: comps) ?? date
            }
            return date
        }
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: raw)
    }
}

// MARK: - Volume

final class FTPVolume: RemoteVolume {
    let kindLabel = "FTP"
    private let config: FTPClient.Config
    private var client: FTPClient?

    init(host: String, port: Int?, username: String, password: String) {
        config = FTPClient.Config(host: host,
                                  port: UInt16(clamping: port ?? 21),
                                  username: username,
                                  password: password)
    }

    func connect() async throws {
        let c = FTPClient(config: config)
        try await c.connect()
        client = c
    }

    private func requireClient() throws -> FTPClient {
        guard let client else { throw VolumeError.disconnected }
        return client
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await requireClient().list(path)
    }

    /// Transfers dial their own control connection so a long download never
    /// blocks browsing on the shared one.
    private func withFreshClient<T>(_ body: (FTPClient) async throws -> T) async throws -> T {
        let c = FTPClient(config: config)
        try await c.connect()
        do {
            let result = try await body(c)
            await c.quit()
            return result
        } catch {
            await c.quit()
            throw error
        }
    }

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        try await withFreshClient { c in
            try await c.download(path: entry.path, to: url, expectedSize: entry.size ?? -1, progress: progress)
        }
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        try await withFreshClient { c in
            try await c.upload(localURL: localURL, toPath: VolumePath.join(dir, name), progress: progress)
        }
    }

    func delete(_ entry: FileEntry) async throws {
        try await requireClient().delete(path: entry.path, isDirectory: entry.isDirectory)
    }

    func createFolder(named name: String, in dir: String) async throws {
        try await requireClient().makeDirectory(VolumePath.join(dir, name))
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        try await requireClient().rename(from: entry.path,
                                         to: VolumePath.join(VolumePath.parent(of: entry.path), newName))
    }

    func disconnect() async {
        await client?.quit()
        client = nil
    }
}
