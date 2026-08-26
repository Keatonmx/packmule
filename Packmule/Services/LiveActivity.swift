//
//  LiveActivity.swift
//  Packmule
//
//  Drives the Dynamic Island mule from the transfer queue: one Live Activity
//  per busy spell, updated about once a second with progress and speed, ended
//  with a short "Delivered" beat when the queue drains.
//

import Foundation
import ActivityKit

@available(iOS 16.2, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<TransferAttributes>?
    private var timer: Timer?
    private var lastName = ""
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var speed: Double = 0

    private init() {}

    /// Called whenever the queue starts or stops moving.
    func queueChanged(_ queue: TransferQueue) {
        if queue.activeCount > 0 {
            if activity == nil { start(queue) }
        } else if activity != nil {
            end(queue)
        }
    }

    private func start(_ queue: TransferQueue) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lastName = ""
        lastBytes = 0
        lastTime = Date()
        speed = 0
        activity = try? Activity.request(
            attributes: TransferAttributes(startedAt: Date()),
            content: ActivityContent(state: makeState(queue), staleDate: staleDate))
        timer?.invalidate()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self, weak queue] _ in
            Task { @MainActor in
                guard let self, let queue else { return }
                self.push(queue)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    private func push(_ queue: TransferQueue) {
        guard let activity else { return }
        let content = ActivityContent(state: makeState(queue), staleDate: staleDate)
        Task { await activity.update(content) }
    }

    /// If the app gets suspended mid-haul, updates stop; the system then dims
    /// the island as stale instead of showing a frozen number as fresh.
    private var staleDate: Date {
        Date().addingTimeInterval(75)
    }

    private func makeState(_ queue: TransferQueue) -> TransferAttributes.ContentState {
        guard let item = queue.runningItem else {
            return TransferAttributes.ContentState(
                fraction: 0, detailText: "Loading up", itemName: "Queued",
                direction: "down", queued: queue.activeCount, finished: false)
        }
        if item.name != lastName {
            lastName = item.name
            lastBytes = item.bytes
            lastTime = Date()
            speed = 0
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed > 0.4 {
            let instant = Double(max(0, item.bytes - lastBytes)) / elapsed
            speed = speed == 0 ? instant : (0.7 * speed + 0.3 * instant)
            lastBytes = item.bytes
            lastTime = now
        }
        var detail = item.bytes.fileSizeString
        if item.total > 0 {
            detail += " of \(item.total.fileSizeString)"
        }
        if speed > 1024 {
            detail += " · \(Int64(speed).fileSizeString)/s"
        }
        return TransferAttributes.ContentState(
            fraction: item.total > 0 ? min(1, Double(item.bytes) / Double(item.total)) : 0,
            detailText: detail,
            itemName: item.name,
            direction: item.direction == .upload ? "up" : "down",
            queued: max(0, queue.activeCount - 1),
            finished: false)
    }

    private func end(_ queue: TransferQueue) {
        timer?.invalidate()
        timer = nil
        guard let activity else { return }
        self.activity = nil
        let clean = !queue.items.contains { item in
            if case .failed = item.status { return true }
            return false
        }
        let state = TransferAttributes.ContentState(
            fraction: 1,
            detailText: clean ? "Everything arrived" : "Some items failed, see the app",
            itemName: clean ? "Delivered" : "Finished with trouble",
            direction: "down", queued: 0, finished: true)
        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.update(content)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await activity.end(content, dismissalPolicy: .default)
        }
    }
}
