//
//  Discovery.swift
//  Packmule
//
//  Bonjour browse for SMB and FTP services on the local network, so NAS boxes
//  and Macs show up under Nearby without typing anything. Tapping one resolves
//  the endpoint to a host and prefills the Add server sheet.
//

import Foundation
import Network

@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var services: [DiscoveredService] = []

    private var browsers: [NWBrowser] = []
    private var endpoints: [String: NWEndpoint] = [:]
    private var found: [String: [DiscoveredService]] = [:]
    /// Demo mode pins the list; live browse updates are ignored.
    private var frozen = false

    func start() {
        guard browsers.isEmpty else { return }
        browse(type: "_smb._tcp", kind: .smb)
        browse(type: "_ftp._tcp", kind: .ftp)
        browse(type: "_sftp-ssh._tcp", kind: .sftp)
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        endpoints = [:]
        found = [:]
        services = []
    }

    /// CI screenshots: pretend the network has something on it.
    func injectDemo() {
        frozen = true
        services = [
            DiscoveredService(id: "demo-nas", name: "Redfern NAS", kind: .smb),
            DiscoveredService(id: "demo-ftp", name: "workshop-pi", kind: .ftp),
        ]
    }

    private func browse(type: String, kind: ServerKind) {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [DiscoveredService] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredService(id: "\(type):\(name)", name: name, kind: kind)
            }
            let pairs: [(String, NWEndpoint)] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return ("\(type):\(name)", result.endpoint)
            }
            Task { @MainActor [weak self] in
                guard let self, !self.frozen else { return }
                self.found[type] = list
                for (id, endpoint) in pairs { self.endpoints[id] = endpoint }
                self.services = self.found.values.flatMap { $0 }.sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: .global(qos: .utility))
        browsers.append(browser)
    }

    /// Connects briefly to the advertised endpoint to learn its host and port.
    func resolve(_ service: DiscoveredService) async -> (host: String, port: Int)? {
        guard let endpoint = endpoints[service.id] else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: Int)?, Never>) in
            // One serial queue for state updates and the timeout, so `done`
            // is never raced.
            let queue = DispatchQueue(label: "com.redfernsoutpost.packmule.resolve")
            let conn = NWConnection(to: endpoint, using: .tcp)
            var done = false
            let finish: ((host: String, port: Int)?) -> Void = { value in
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        var name: String
                        switch host {
                        case .ipv4(let addr): name = "\(addr)"
                        case .ipv6(let addr): name = "\(addr)"
                        case .name(let n, _): name = n
                        @unknown default: name = "\(host)"
                        }
                        // IPv6 scope suffixes ("%en0") don't survive re-dialling.
                        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
                        finish((host: name, port: Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }
}
