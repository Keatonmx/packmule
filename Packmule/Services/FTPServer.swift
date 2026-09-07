//
//  FTPServer.swift
//  Packmule
//
//  The hosting half: a small FTP server on the phone, serving the app's
//  Documents folder (the same one the Files app shows). Windows Explorer,
//  another Packmule, or any FTP client can connect to ftp://<phone-ip>:2121
//  over the LAN or a VPN tunnel. Passive mode only, one folder, optional
//  sign-in, and it runs while the app is open (iOS pauses backgrounded apps).
//

import Foundation
import Network
import UIKit

struct HostConfig: Codable, Equatable {
    var port: Int = 2121
    /// Empty means no sign-in: any USER is welcomed straight in.
    var username: String = ""
    var password: String = ""

    private static let key = "packmule.host"

    static func load() -> HostConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(HostConfig.self, from: data) else {
            return HostConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

@MainActor
final class FTPServer: ObservableObject {
    @Published var config = HostConfig.load() {
        didSet { config.save() }
    }
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    @Published private(set) var connectionCount = 0

    private var listener: NWListener?
    private var sessions: [FTPServerSession] = []
    private let queue = DispatchQueue(label: "com.redfernsoutpost.packmule.ftpserver")
    /// Linked-folder security scopes held open while serving.
    private var scopedURLs: [URL] = []

    var root: URL { LocalFiles.documentsURL }

    func start() {
        guard !running else { return }
        lastError = nil
        let port = UInt16(clamping: config.port)
        guard let nwPort = NWEndpoint.Port(rawValue: port == 0 ? 2121 : port) else {
            lastError = "That port doesn't work"
            return
        }
        // Linked folders ride along as folders at the server root.
        var mounts: [(name: String, url: URL)] = []
        for folder in LinkedFolderStore.load() {
            guard let url = LinkedFolderStore.resolve(folder), url.startAccessingSecurityScopedResource() else { continue }
            scopedURLs.append(url)
            mounts.append((folder.name, url))
        }
        let sessionMounts = mounts
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: nwPort)
            // Advertise over Bonjour so other Packmules list it under Nearby.
            // The TXT marker is how another Packmule KNOWS it's one of us and
            // offers tap to browse instead of a generic add form.
            var txt = NWTXTRecord()
            txt["packmule"] = "1"
            listener.service = NWListener.Service(name: UIDevice.current.name, type: "_ftp._tcp",
                                                  domain: nil, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection, mounts: sessionMounts) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        self.lastError = "Server stopped: \(error.localizedDescription)"
                        self.stop()
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            running = true
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            lastError = "Couldn't open port \(config.port): \(error.localizedDescription)"
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            scopedURLs = []
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open = sessions
        queue.async { open.forEach { $0.close() } }
        sessions = []
        connectionCount = 0
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    /// Called on `queue`.
    private nonisolated func accept(_ connection: NWConnection, mounts: [(name: String, url: URL)]) {
        let session = FTPServerSession(connection: connection,
                                       root: LocalFiles.documentsURL,
                                       config: HostConfig.load(),
                                       mounts: mounts,
                                       queue: queue) { [weak self] session in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessions.removeAll { $0 === session }
                self.connectionCount = self.sessions.count
            }
        }
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.sessions.append(session)
            self.connectionCount = self.sessions.count
        }
        session.start()
    }

    /// The addresses other devices can dial: (interface label, ip).
    nonisolated static func deviceAddresses() -> [(label: String, ip: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                    result.append((name.hasPrefix("utun") ? "VPN" : "WiFi", ip))
                }
            }
        }
        return result
    }
}

// MARK: - One client connection

/// All work runs on the server's serial queue; state is confined to it.
final class FTPServerSession {
    private let control: NWConnection
    private let root: URL
    private let config: HostConfig
    /// Linked folders shown as folders at "/" (name, real location).
    private let mounts: [(name: String, url: URL)]
    private let queue: DispatchQueue
    private let onClose: (FTPServerSession) -> Void

    private var buffer = Data()
    private var authed = false
    private var cwd = "/"
    private var renameFrom: String?
    private var dataListener: NWListener?
    private var dataConnection: NWConnection?
    private var pendingTransfer: ((NWConnection) -> Void)?
    private var closed = false

    init(connection: NWConnection, root: URL, config: HostConfig,
         mounts: [(name: String, url: URL)],
         queue: DispatchQueue, onClose: @escaping (FTPServerSession) -> Void) {
        self.control = connection
        self.root = root
        self.config = config
        self.mounts = mounts
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        control.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.close() }
            default:
                break
            }
        }
        control.start(queue: queue)
        reply("220 Packmule ready")
        receiveCommands()
    }

    func close() {
        guard !closed else { return }
        closed = true
        tearDownData()
        control.cancel()
        onClose(self)
    }

    // MARK: control channel

    private func receiveCommands() {
        control.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            while let range = self.buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                self.buffer.removeSubrange(self.buffer.startIndex..<range.upperBound)
                self.handle(String(decoding: lineData, as: UTF8.self))
            }
            if complete || error != nil {
                self.close()
            } else {
                self.receiveCommands()
            }
        }
    }

    private func reply(_ line: String) {
        guard !closed else { return }
        control.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let verb = parts[0].uppercased()
        let arg = parts.count > 1 ? String(parts[1]) : ""

        // Anyone may knock; everything past sign-in needs auth.
        switch verb {
        case "USER":
            if config.username.isEmpty {
                authed = true
                reply("230 Welcome to the mule")
            } else {
                reply("331 Password required")
            }
            return
        case "PASS":
            if config.username.isEmpty || authed {
                authed = true
                reply("230 Welcome to the mule")
            } else if arg == config.password {
                authed = true
                reply("230 Welcome to the mule")
            } else {
                reply("530 Wrong password")
            }
            return
        case "QUIT":
            reply("221 Goodbye")
            close()
            return
        case "SYST":
            reply("215 UNIX Type: L8")
            return
        case "FEAT":
            control.send(content: Data("211-Features:\r\n UTF8\r\n MLSD\r\n SIZE\r\n MDTM\r\n EPSV\r\n211 End\r\n".utf8),
                         completion: .contentProcessed { _ in })
            return
        case "OPTS":
            reply("200 Always UTF-8")
            return
        case "NOOP":
            reply("200 Standing by")
            return
        case "HOST":
            reply("200 Sure")
            return
        case "AUTH", "ADAT", "PBSZ", "PROT":
            // FileZilla and friends probe for TLS before signing in; a clean
            // refusal lets them fall back to plain FTP instead of giving up.
            reply("502 Plain FTP only here, no TLS")
            return
        default:
            break
        }

        guard authed else {
            reply("530 Sign in first")
            return
        }

        switch verb {
        case "PWD", "XPWD":
            reply("257 \"\(cwd)\"")
        case "TYPE":
            reply("200 Binary it is")
        case "CWD":
            let target = normalize(arg)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL(target).path, isDirectory: &isDir), isDir.boolValue {
                cwd = target
                reply("250 Now in \(target)")
            } else {
                reply("550 No such folder")
            }
        case "CDUP":
            cwd = VolumePath.parent(of: cwd)
            reply("250 Now in \(cwd)")
        case "PASV":
            openPassive(extended: false)
        case "EPSV":
            openPassive(extended: true)
        case "LIST", "NLST", "MLSD":
            startListing(verb: verb, arg: arg)
        case "SIZE":
            let url = fileURL(normalize(arg))
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                reply("213 \(size)")
            } else {
                reply("550 No such file")
            }
        case "MDTM":
            let url = fileURL(normalize(arg))
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                reply("213 \(Self.mlsdFormatter.string(from: date))")
            } else {
                reply("550 No such file")
            }
        case "RETR":
            startDownload(arg)
        case "STOR":
            startUpload(arg)
        case "DELE":
            do {
                try FileManager.default.removeItem(at: fileURL(normalize(arg)))
                reply("250 Deleted")
            } catch {
                reply("550 \(error.localizedDescription)")
            }
        case "MKD", "XMKD":
            let target = normalize(arg)
            do {
                try FileManager.default.createDirectory(at: fileURL(target), withIntermediateDirectories: false)
                reply("257 \"\(target)\" made")
            } catch {
                reply("550 \(error.localizedDescription)")
            }
        case "RMD", "XRMD":
            do {
                try FileManager.default.removeItem(at: fileURL(normalize(arg)))
                reply("250 Removed")
            } catch {
                reply("550 \(error.localizedDescription)")
            }
        case "RNFR":
            renameFrom = normalize(arg)
            reply("350 And to what?")
        case "RNTO":
            if let from = renameFrom {
                renameFrom = nil
                do {
                    try FileManager.default.moveItem(at: fileURL(from), to: fileURL(normalize(arg)))
                    reply("250 Renamed")
                } catch {
                    reply("550 \(error.localizedDescription)")
                }
            } else {
                reply("503 RNFR first")
            }
        case "ABOR":
            tearDownData()
            reply("226 Aborted")
        case "REST":
            reply("502 No resume here yet")
        default:
            reply("502 Not a thing this mule does")
        }
    }

    // MARK: paths

    private func normalize(_ raw: String) -> String {
        var arg = raw
        // Strip "LIST -al" style flags.
        while arg.hasPrefix("-") {
            if let space = arg.firstIndex(of: " ") {
                arg = String(arg[arg.index(after: space)...])
            } else {
                arg = ""
            }
        }
        let base = arg.hasPrefix("/") ? arg : cwd + "/" + arg
        var stack: [String] = []
        for comp in base.split(separator: "/") {
            switch comp {
            case ".", "": continue
            case "..": _ = stack.popLast()
            default: stack.append(String(comp))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    private func fileURL(_ virtual: String) -> URL {
        let comps = VolumePath.components(virtual)
        if let first = comps.first, let mount = mounts.first(where: { $0.name == first }) {
            var url = mount.url
            for comp in comps.dropFirst() { url.appendPathComponent(comp) }
            return url
        }
        var url = root
        for comp in comps { url.appendPathComponent(comp) }
        return url
    }

    // MARK: passive data connections

    private func openPassive(extended: Bool) {
        tearDownData()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: .any) else {
            reply("425 Can't open a data port")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.dataConnection = connection
            if let pending = self.pendingTransfer {
                self.pendingTransfer = nil
                pending(connection)
            }
        }
        // The system hands out the ephemeral port only once the listener is
        // ready; replying earlier would tell the client to dial port 0.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, listener === self.dataListener else { return }
            switch state {
            case .ready:
                self.announcePassive(listener: listener, extended: extended)
            case .failed:
                self.tearDownData()
                self.reply("425 Can't open a data port")
            default:
                break
            }
        }
        dataListener = listener
        listener.start(queue: queue)
    }

    /// Runs on `queue` once the data listener knows its port.
    private func announcePassive(listener: NWListener, extended: Bool) {
        let port = Int(listener.port?.rawValue ?? 0)
        guard port > 0 else {
            tearDownData()
            reply("425 Can't open a data port")
            return
        }
        if extended {
            reply("229 Entering Extended Passive Mode (|||\(port)|)")
        } else if case let .hostPort(host, _)? = control.currentPath?.localEndpoint,
                  case let .ipv4(address) = host {
            let quad = "\(address)".split(separator: "%")[0].replacingOccurrences(of: ".", with: ",")
            reply("227 Entering Passive Mode (\(quad),\(port / 256),\(port % 256))")
        } else {
            // No IPv4 on the control path; the extended reply names just the port.
            reply("229 Entering Extended Passive Mode (|||\(port)|)")
        }
    }

    private func withDataConnection(_ body: @escaping (NWConnection) -> Void) {
        guard dataListener != nil else {
            reply("425 Send PASV first")
            return
        }
        if let existing = dataConnection {
            body(existing)
        } else {
            pendingTransfer = body
        }
    }

    private func tearDownData() {
        pendingTransfer = nil
        dataConnection?.cancel()
        dataConnection = nil
        dataListener?.cancel()
        dataListener = nil
    }

    private func finishData(_ message: String) {
        dataConnection?.send(content: nil, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { [weak self] _ in
            self?.queue.async {
                self?.tearDownData()
                self?.reply(message)
            }
        })
    }

    // MARK: listings

    private static let listFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private static let mlsdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    private func startListing(verb: String, arg: String) {
        let target = normalize(arg.isEmpty ? cwd : arg)
        let url = fileURL(target)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [])) ?? []
        var lines: [String] = []
        // Linked folders appear at the root next to the real contents.
        if target == "/" {
            for mount in mounts {
                switch verb {
                case "NLST":
                    lines.append(mount.name)
                case "MLSD":
                    lines.append("type=dir;modify=\(Self.mlsdFormatter.string(from: Date()));size=0; \(mount.name)")
                default:
                    let stamp = Self.listFormatter.string(from: Date())
                    lines.append("drwxr-xr-x 1 mule mule 0 \(stamp) \(mount.name)")
                }
            }
        }
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? Date()
            let name = item.lastPathComponent
            switch verb {
            case "NLST":
                lines.append(name)
            case "MLSD":
                let type = isDir ? "dir" : "file"
                lines.append("type=\(type);modify=\(Self.mlsdFormatter.string(from: date));size=\(size); \(name)")
            default:
                let mode = isDir ? "drwxr-xr-x" : "-rw-r--r--"
                let stamp = Self.listFormatter.string(from: date)
                lines.append("\(mode) 1 mule mule \(size) \(stamp) \(name)")
            }
        }
        let payload = Data((lines.map { $0 + "\r\n" }.joined()).utf8)
        reply("150 Here it comes")
        withDataConnection { [weak self] conn in
            conn.send(content: payload, completion: .contentProcessed { _ in
                self?.queue.async { self?.finishData("226 That's everything") }
            })
        }
    }

    // MARK: transfers

    private func startDownload(_ arg: String) {
        let url = fileURL(normalize(arg))
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            reply("550 No such file")
            return
        }
        reply("150 Here it comes")
        withDataConnection { [weak self] conn in
            self?.pump(handle: handle, into: conn)
        }
    }

    private func pump(handle: FileHandle, into conn: NWConnection) {
        let chunk = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
        if chunk.isEmpty {
            try? handle.close()
            finishData("226 Delivered")
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                if error != nil || self?.closed == true {
                    try? handle.close()
                    self?.tearDownData()
                } else {
                    self?.pump(handle: handle, into: conn)
                }
            }
        })
    }

    private func startUpload(_ arg: String) {
        let url = fileURL(normalize(arg))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            reply("550 Can't write there")
            return
        }
        reply("150 Send it")
        withDataConnection { [weak self] conn in
            self?.drain(into: handle, from: conn)
        }
    }

    private func drain(into handle: FileHandle, from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                try? handle.write(contentsOf: data)
            }
            if complete || error != nil {
                try? handle.close()
                self.tearDownData()
                self.reply(error == nil ? "226 Stashed" : "426 Lost the connection")
            } else {
                self.drain(into: handle, from: conn)
            }
        }
    }
}
