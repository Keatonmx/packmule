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
    /// Fetch to a temporary spot, then open the player (FTP can't seek).
    case play
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
    /// Chosen at enqueue time so retries append to the same partial file.
    var plannedDestination: URL?
    /// Failed tries so far; the queue resumes downloads from the partial's size.
    var attempts = 0

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
    /// Fired whenever the queue starts or stops moving (idle timer, Live Activity).
    var onActivity: (() -> Void)?

    private static let maxAttempts = 3
    private var pumping = false
    /// Jobs take the byte offset to resume from (0 = fresh start).
    private var work: [UUID: (Int64) async throws -> URL?] = [:]

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
        let dir = purpose == .keep ? LocalFiles.downloadsURL : LocalFiles.previewURL
        let dest = LocalFiles.uniqueDestination(for: entry.name, in: dir)
        item.plannedDestination = dest
        work[item.id] = { [weak item] resumeFrom in
            if (item?.attempts ?? 0) > 0 {
                // The old session may be dead after a drop; reconnecting is cheap.
                try? await volume.connect()
            }
            let onProgress: TransferProgress = { bytes, total in
                Self.report(item, bytes: bytes, total: total)
                return !(item?.cancelRequested ?? true)
            }
            if resumeFrom > 0 {
                try await volume.download(entry, to: dest, resumingFrom: resumeFrom, progress: onProgress)
            } else {
                try await volume.download(entry, to: dest, progress: onProgress)
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
        work[item.id] = { [weak item] _ in
            if (item?.attempts ?? 0) > 0 {
                try? await volume.connect()
                // Uploads restart whole; clear the server's torn partial first.
                let partial = FileEntry(name: name, path: VolumePath.join(dir, name), isDirectory: false)
                try? await volume.delete(partial)
            }
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
        guard let next = items.last(where: { $0.status == .queued }) else {
            onActivity?()
            return
        }
        guard let job = work[next.id] else {
            next.status = .failed("Lost the job")
            pump()
            return
        }
        pumping = true
        next.status = .running
        let background = UIApplication.shared.beginBackgroundTask(withName: "packmule.transfer")
        onActivity?()
        Task {
            do {
                var resumeFrom: Int64 = 0
                if next.direction == .download, next.attempts > 0,
                   let dest = next.plannedDestination {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    resumeFrom = (attrs?[.size] as? Int64) ?? 0
                }
                let dest = try await job(resumeFrom)
                next.destination = dest
                next.fraction = 1
                next.status = .done
                work[next.id] = nil
                ButtonHaptics.shared.tick()
                onFinished?(next)
            } catch {
                if next.cancelRequested || Self.isCancel(error) {
                    next.status = .cancelled
                    work[next.id] = nil
                } else if next.attempts + 1 < Self.maxAttempts, Self.isRetryable(error) {
                    // Leave the job in place; back off briefly and requeue so the
                    // next run picks up from the partial file's size.
                    next.attempts += 1
                    next.status = .queued
                    try? await Task.sleep(nanoseconds: UInt64(next.attempts) * 2_000_000_000)
                } else {
                    next.status = .failed(Self.message(for: error))
                    work[next.id] = nil
                }
            }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            pumping = false
            pump()
        }
    }

    private static func isCancel(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let volumeError = error as? VolumeError, case .cancelled = volumeError { return true }
        return false
    }

    /// Network blips retry; wrong passwords and missing files don't.
    private static func isRetryable(_ error: Error) -> Bool {
        guard let volumeError = error as? VolumeError else { return true }
        switch volumeError {
        case .authFailed, .unsupported, .notFound, .cancelled, .badAddress:
            return false
        case .disconnected, .protocolFailure:
            return true
        }
    }

    private static func message(for error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Something went wrong" : text
    }
}
