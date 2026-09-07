//
//  PixelArt.swift
//  Packmule (app + widget extension)
//
//  A tiny 16-bit sprite engine in the Stardew Valley / old Harvest Moon
//  spirit: sprites are character bitmaps, rendered one crisp rect per pixel,
//  with the classic dark outline drawn automatically around every shape.
//

import SwiftUI

/// One colour layer of a bitmap as a Shape (works everywhere, widgets included).
struct PixelLayer: Shape {
    let map: [String]
    let match: Character

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = map.count
        let w = map.map(\.count).max() ?? 0
        guard w > 0, h > 0 else { return p }
        let pw = rect.width / CGFloat(w)
        let ph = rect.height / CGFloat(h)
        for (y, row) in map.enumerated() {
            for (x, ch) in row.enumerated() where ch == match {
                // Slight overdraw so antialias seams never show between pixels.
                p.addRect(CGRect(x: rect.minX + CGFloat(x) * pw,
                                 y: rect.minY + CGFloat(y) * ph,
                                 width: pw + 0.4,
                                 height: ph + 0.4))
            }
        }
        return p
    }
}

/// A whole sprite: bitmap + palette. "." is transparent.
struct PixelSprite: View {
    let map: [String]
    let palette: [Character: Color]

    var body: some View {
        ZStack {
            ForEach(palette.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                PixelLayer(map: map, match: entry.key)
                    .fill(entry.value)
            }
        }
        .aspectRatio(CGFloat(map.map(\.count).max() ?? 1) / CGFloat(max(1, map.count)),
                     contentMode: .fit)
    }
}

// MARK: - The mule, 16-bit edition

/// Sprites are built from layout boxes and rasterised, then every filled
/// region grows the classic one pixel dark outline. Two walk frames (legs
/// alternate) and a resting pose for empty states.
enum MuleSprites {
    static let width = 26
    static let height = 18

    struct Box {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let ch: Character
    }

    static let palette: [Character: Color] = [
        "o": Color(red: 0.23, green: 0.16, blue: 0.10),   // outline
        "b": Color(red: 0.79, green: 0.48, blue: 0.29),   // hide (Mule tan)
        "l": Color(red: 0.89, green: 0.66, blue: 0.47),   // belly, muzzle
        "m": Color(red: 0.48, green: 0.31, blue: 0.16),   // mane, tail, hooves
        "c": Color(red: 0.61, green: 0.42, blue: 0.25),   // crate
        "t": Color(red: 0.85, green: 0.63, blue: 0.36),   // crate highlight
        "s": Color(red: 0.29, green: 0.20, blue: 0.13),   // strap
        "e": Color(red: 0.10, green: 0.08, blue: 0.06),   // eye
    ]

    /// Shared upper body, the 2026-09-07 pannier redesign (from the user's
    /// approved concept): two flap topped bags instead of one crate, a
    /// slightly lowered head, the settled face rules. Facing right.
    private static let torso: [Box] = [
        Box(x: 4, y: 0, w: 4, h: 2, ch: "t"),     // rear pannier flap
        Box(x: 4, y: 2, w: 4, h: 5, ch: "c"),     // rear pannier bag
        Box(x: 9, y: 0, w: 4, h: 2, ch: "t"),     // front pannier flap
        Box(x: 9, y: 2, w: 4, h: 5, ch: "c"),     // front pannier bag
        Box(x: 8, y: 0, w: 1, h: 7, ch: "s"),     // strap between the bags
        Box(x: 1, y: 7, w: 2, h: 2, ch: "m"),     // tail
        Box(x: 0, y: 9, w: 2, h: 2, ch: "m"),     // tail tuft, drooping
        Box(x: 3, y: 7, w: 14, h: 6, ch: "b"),    // body, compact
        Box(x: 8, y: 7, w: 1, h: 6, ch: "s"),     // girth strap under the bags
        Box(x: 5, y: 11, w: 10, h: 2, ch: "l"),   // belly light
        Box(x: 16, y: 5, w: 1, h: 2, ch: "m"),    // mane step (head reads apart)
        Box(x: 17, y: 4, w: 6, h: 6, ch: "b"),    // head, a touch lower
        Box(x: 21, y: 7, w: 4, h: 3, ch: "l"),    // muzzle, big and friendly
        Box(x: 24, y: 6, w: 1, h: 1, ch: "l"),    // muzzle, upper step
        Box(x: 17, y: 1, w: 1, h: 1, ch: "m"),    // far ear, tapered tip
        Box(x: 16, y: 2, w: 2, h: 3, ch: "m"),    // far ear, offset behind
        Box(x: 21, y: 1, w: 1, h: 1, ch: "m"),    // near ear, tapered tip
        Box(x: 20, y: 2, w: 2, h: 4, ch: "m"),    // near ear, taller and forward
        Box(x: 21, y: 6, w: 1, h: 1, ch: "e"),    // eye
        Box(x: 24, y: 8, w: 1, h: 1, ch: "m"),    // nostril
    ]

    private static func legs(_ positions: [(x: Int, y: Int, h: Int)]) -> [Box] {
        positions.flatMap { leg in
            [Box(x: leg.x, y: leg.y, w: 2, h: leg.h, ch: "b"),
             Box(x: leg.x, y: leg.y + leg.h - 1, w: 2, h: 1, ch: "m")]
        }
    }

    static let walkA = frame(torso + legs([(4, 13, 4), (8, 13, 4), (12, 13, 4), (15, 13, 4)]))
    static let walkB = frame(torso + legs([(3, 13, 4), (9, 14, 3), (12, 14, 3), (16, 13, 4)]))

    /// Legs folded, head low, eye shut: the mule off duty.
    static let resting: [String] = frame([
        Box(x: 1, y: 9, w: 2, h: 2, ch: "m"),     // tail
        Box(x: 0, y: 11, w: 2, h: 2, ch: "m"),    // tail tuft, drooping
        Box(x: 4, y: 2, w: 4, h: 2, ch: "t"),     // rear pannier flap
        Box(x: 4, y: 4, w: 4, h: 5, ch: "c"),     // rear pannier bag
        Box(x: 9, y: 2, w: 4, h: 2, ch: "t"),     // front pannier flap
        Box(x: 9, y: 4, w: 4, h: 5, ch: "c"),     // front pannier bag
        Box(x: 8, y: 2, w: 1, h: 7, ch: "s"),     // strap between the bags
        Box(x: 3, y: 9, w: 14, h: 6, ch: "b"),    // body, low
        Box(x: 8, y: 9, w: 1, h: 6, ch: "s"),     // girth strap
        Box(x: 4, y: 15, w: 12, h: 1, ch: "m"),   // folded legs
        Box(x: 16, y: 7, w: 1, h: 2, ch: "m"),    // mane step
        Box(x: 17, y: 6, w: 6, h: 6, ch: "b"),    // head, low
        Box(x: 21, y: 9, w: 4, h: 3, ch: "l"),    // muzzle, big and friendly
        Box(x: 24, y: 8, w: 1, h: 1, ch: "l"),    // muzzle, upper step
        Box(x: 17, y: 3, w: 1, h: 1, ch: "m"),    // far ear, tapered tip
        Box(x: 16, y: 4, w: 2, h: 3, ch: "m"),    // far ear, offset behind
        Box(x: 21, y: 3, w: 1, h: 1, ch: "m"),    // near ear, tapered tip
        Box(x: 20, y: 4, w: 2, h: 4, ch: "m"),    // near ear, taller and forward
        Box(x: 20, y: 8, w: 2, h: 1, ch: "m"),    // closed eye
        Box(x: 24, y: 10, w: 1, h: 1, ch: "m"),   // nostril
    ])

    static func frame(_ boxes: [Box]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        for box in boxes {
            guard box.x >= 0, box.y >= 0 else { continue }
            for yy in box.y..<min(height, box.y + box.h) {
                for xx in box.x..<min(width, box.x + box.w) {
                    grid[yy][xx] = box.ch
                }
            }
        }
        // The classic outline: every empty cell touching paint goes dark.
        var outlined = grid
        for y in 0..<height {
            for x in 0..<width where grid[y][x] == "." {
                let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                let touchesPaint = neighbours.contains { nx, ny in
                    nx >= 0 && ny >= 0 && nx < width && ny < height && grid[ny][nx] != "."
                }
                if touchesPaint {
                    outlined[y][x] = "o"
                }
            }
        }
        return outlined.map { String($0) }
    }

    /// The frame for a given progress: he takes a step every percent.
    static func stepFrame(for fraction: Double) -> [String] {
        Int(fraction * 100) % 2 == 0 ? walkA : walkB
    }
}
