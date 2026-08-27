//
//  ProbeService.swift
//  Packmule
//
//  Quick TCP reachability probe: powers the pulse dot on server cards and
//  the Connection details sheet (round trip time + greeting banner for
//  protocols that send one).
//

import Foundation
import Network

enum Probe {
    struct Result {
        /// Milliseconds to an open TCP connection; nil = unreachable.
        var rttMillis: Int?
        /// First line the server volunteered (FTP greeting, SSH ident).
        var banner: String?
    }

    /// Opens a TCP connection, times it, optionally reads the first line the
    /// server sends, then hangs up. Never throws; unreachable = rtt nil.
    static func tcp(host: String, port: Int, readBanner: Bool = false,
                    timeout: TimeInterval = 3.0) async -> Result {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return Result(rttMillis: nil, banner: nil)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "packmule.probe")
        let started = Date()

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            let once = OnceFlag()
            let finish: (Result) -> Void = { result in
                guard once.trip() else { return }
                conn.cancel()
                cont.resume(returning: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let rtt = Int(Date().timeIntervalSince(started) * 1000)
                    if readBanner {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                            var banner: String?
                            if let data, !data.isEmpty {
                                banner = String(decoding: data, as: UTF8.self)
                                    .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                                    .first.map(String.init)
                            }
                            finish(Result(rttMillis: rtt, banner: banner))
                        }
                        // Silent protocols (SMB) send nothing; don't wait forever.
                        queue.asyncAfter(deadline: .now() + 1.2) {
                            finish(Result(rttMillis: rtt, banner: nil))
                        }
                    } else {
                        finish(Result(rttMillis: rtt, banner: nil))
                    }
                case .failed, .cancelled:
                    finish(Result(rttMillis: nil, banner: nil))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout + 0.5) {
                finish(Result(rttMillis: nil, banner: nil))
            }
        }
    }
}
