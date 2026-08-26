//
//  TransferQueue.swift
//  Packmule
//
//  Serial queue of uploads and downloads with live progress. Downloads land in
//  Documents/Downloads (visible in the Files app); previews and shares fetch
//  into Caches/Preview first and hand the file onward when done.
//

import Foundation
import UIKit

enum TransferDirection {
    case download
    case upload
}

enum TransferPurpose {
    /// Keep the file in Downloads.
    case keep
    /// Fetch to a temporary spot, then open Quick Look.
    case preview
    /// Fetch to a temporary spot, then open the share sheet.
    case share
}

enum TransferStatus: Equatable {
    case queued
    case running
    case done
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Moving"
        case .done: return "Done"
        case .failed(let why): return why
        case .cancelled: return "Cancelled"
        }
    }
}

final class TransferItem: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let direction: TransferDirection
    let purpose: TransferPurpose
    /// "Home media" or wherever it's going/coming from.
    let detail: String

    @Published var status: TransferStatus = .queued
    @Published var fraction: Double = 0
    @Published var bytes: Int64 = 0
    @Published var total: Int64 = -1
    /// Where the file ended up (downloads only).
    var destination: URL?

    /// Read from the transfer thread via the progress callback.
    var cancelRequested = false

    init(name: String, direction: TransferDirection, purpose: TransferPurpose, detail: String) {
        self.name = name
        self.direction = direction
        self.purpose = purpose
        self.detail = detail
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    @Published private(set) var items: [TransferItem] = []

    /// Fired on completion so the app can toast, open Quick Look, share.
    var onFinished: ((TransferItem) -> Void)?

    private var pumping = false
    private var work: [UUID: () async throws -> URL?] = [:]

    var activeCount: Int {
        items.filter { $0.status == .queued || $0.status == .running }.count
    }

    var runningItem: TransferItem? {
        items.first { $0.status == .running }
    }

    // MARK: enqueue

    func enqueueDownload(volume: RemoteVolume, entry: FileEntry, from serverName: String,
                         purpose: TransferPurpose = .keep) {
        let item = TransferItem(name: entry.name, direction: .download, purpose: purpose, detail: serverName)
        item.total = entry.size ?? -1
        work[item.id] = { [weak item] in
            let dir = purpose == .keep ? LocalFiles.downloadsURL : LocalFiles.previewURL
            let dest = LocalFiles.uniqueDestination(for: entry.name, in: dir)
            try await volume.download(entry, to: dest) { bytes, total in
                Self.report(item, bytes: bytes, total: total)
                return !(item?.cancelRequested ?? true)
            }
            return dest
        }
        add(item)
    }

    func enqueueUpload(volume: RemoteVolume, localURL: URL, toDirectory dir: String, on serverName: String) {
        let name = localURL.lastPathComponent
        let item = TransferItem(name: name, direction: .upload, purpose: .keep, detail: serverName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        item.total = (attrs?[.size] as? Int64) ?? -1
        work[item.id] = { [weak item] in
            try await volume.upload(localURL, toDirectory: dir, name: name) { bytes, total in
                Self.report(item, bytes: bytes, total: total)
                return !(item?.cancelRequested ?? true)
            }
            return nil
        }
        add(item)
    }

    /// CI screenshots.
    func injectDemo() {
        let a = TransferItem(name: "Spirited Away (2001).mkv", direction: .download, purpose: .keep, detail: "Home media")
        a.status = .running
        a.total = 5_310 * 1_048_576
        a.bytes = a.total * 42 / 100
        a.fraction = 0.42
        let b = TransferItem(name: "roadtrip.m3u", direction: .download, purpose: .keep, detail: "Home media")
        b.status = .done
        b.fraction = 1
        let c = TransferItem(name: "keaton-pc-2026-08-25.zip", direction: .upload, purpose: .keep, detail: "Backup pi")
        c.status = .queued
        items = [a, c, b]
    }

    private func add(_ item: TransferItem) {
        items.insert(item, at: 0)
        pump()
    }

    // MARK: control

    func cancel(_ item: TransferItem) {
        item.cancelRequested = true
        if item.status == .queued {
            item.status = .cancelled
            work[item.id] = nil
        }
    }

    func clearFinished() {
        items.removeAll { $0.status == .done || $0.status == .cancelled }
        items.removeAll { item in
            if case .failed = item.status { return true }
            return false
        }
    }

    // MARK: engine

    private nonisolated static func report(_ item: TransferItem?, bytes: Int64, total: Int64) {
        DispatchQueue.main.async {
            guard let item else { return }
            item.bytes = bytes
            if total > 0 { item.total = total }
            if item.total > 0 {
                item.fraction = min(1, Double(bytes) / Double(item.total))
            }
        }
    }

    private func pump() {
        guard !pumping else { return }
        guard let next = items.last(where: { $0.status == .queued }) else { return }
        guard let job = work[next.id] else {
            next.status = .failed("Lost the job")
            pump()
            return
        }
        pumping = true
        next.status = .running
        let background = UIApplication.shared.beginBackgroundTask(withName: "packmule.transfer")
        Task {
            do {
                let dest = try await job()
                next.destination = dest
                next.fraction = 1
                next.status = .done
                ButtonHaptics.shared.tick()
                onFinished?(next)
            } catch is CancellationError {
                next.status = .cancelled
            } catch let error as VolumeError {
                if case .cancelled = error {
                    next.status = .cancelled
                } else {
                    next.status = .failed(error.localizedDescription)
                }
            } catch {
                next.status = .failed(error.localizedDescription)
            }
            work[next.id] = nil
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            pumping = false
            pump()
        }
    }
}
