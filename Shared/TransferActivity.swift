//
//  TransferActivity.swift
//  Packmule (app + widget extension)
//
//  The Live Activity contract both processes agree on, plus the pack mule
//  itself, drawn as paths so he renders crisp at any size from the compact
//  Dynamic Island up to the lock screen.
//

import SwiftUI

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
struct TransferAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0...1 along the trail.
        var fraction: Double
        /// "1.2 GB of 5.6 GB · 14 MB/s"
        var detailText: String
        var itemName: String
        /// "up" or "down".
        var direction: String
        /// Items waiting behind the current one.
        var queued: Int
        var finished: Bool
    }

    var startedAt: Date
}
#endif

// MARK: - The mule

/// Side profile pack mule, facing the direction of travel (right), in a
/// 100 x 64 design space: body, head, snout, two ears, four legs, tail.
struct MuleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 64
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGRect {
            _ = r
            return CGRect(x: rect.minX + x * sx, y: rect.minY + y * sy, width: w * sx, height: h * sy)
        }
        var p = Path()
        // body
        p.addRoundedRect(in: box(18, 26, 60, 22, 9), cornerSize: CGSize(width: 9 * sx, height: 9 * sy))
        // head + snout
        p.addRoundedRect(in: box(72, 12, 18, 18, 6), cornerSize: CGSize(width: 6 * sx, height: 6 * sy))
        p.addRoundedRect(in: box(86, 20, 13, 10, 4), cornerSize: CGSize(width: 4 * sx, height: 4 * sy))
        // ears
        p.addRoundedRect(in: box(74, 3, 4.5, 12, 2), cornerSize: CGSize(width: 2 * sx, height: 2 * sy))
        p.addRoundedRect(in: box(82, 3, 4.5, 12, 2), cornerSize: CGSize(width: 2 * sx, height: 2 * sy))
        // legs
        for x in [24.0, 36.0, 58.0, 70.0] {
            p.addRoundedRect(in: box(CGFloat(x), 44, 5.5, 20, 2), cornerSize: CGSize(width: 2 * sx, height: 2 * sy))
        }
        // tail
        p.addRoundedRect(in: box(10, 28, 10, 5, 2.5), cornerSize: CGSize(width: 2.5 * sx, height: 2.5 * sy))
        return p
    }
}

/// The cargo: two strapped boxes riding on the mule's back.
struct MulePackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 64
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * sx, y: rect.minY + y * sy, width: w * sx, height: h * sy)
        }
        var p = Path()
        p.addRoundedRect(in: box(28, 10, 34, 18), cornerSize: CGSize(width: 4 * sx, height: 4 * sy))
        p.addRoundedRect(in: box(34, 1, 22, 12), cornerSize: CGSize(width: 3 * sx, height: 3 * sy))
        return p
    }
}
