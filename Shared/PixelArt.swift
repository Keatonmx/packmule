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

// MARK: - The outpost glyph set, 16 by 16

/// UI icons in the mule's world: a barn for SMB, a signpost for FTP, a
/// strongbox for SFTP, a lantern for media servers, a saddlebag for this
/// phone, an album for Photos, two mules meeting for a nearby Packmule,
/// and a feed sack for folders. Compositions from the 2026-09-07 ChatGPT
/// concept round, pixels placed here. Same palette as the mule so they
/// feel like one world in every theme.
enum GlyphSprites {
    static let size = 16

    private static func frame(_ boxes: [(x: Int, y: Int, w: Int, h: Int, ch: Character)]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: size), count: size)
        for box in boxes {
            guard box.x >= 0, box.y >= 0 else { continue }
            for yy in box.y..<min(size, box.y + box.h) {
                for xx in box.x..<min(size, box.x + box.w) {
                    grid[yy][xx] = box.ch
                }
            }
        }
        var outlined = grid
        for y in 0..<size {
            for x in 0..<size where grid[y][x] == "." {
                let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                let touchesPaint = neighbours.contains { nx, ny in
                    nx >= 0 && ny >= 0 && nx < size && ny < size && grid[ny][nx] != "."
                }
                if touchesPaint {
                    outlined[y][x] = "o"
                }
            }
        }
        return outlined.map { String($0) }
    }

    /// SMB server: a barn with a crossbuck door.
    static let barn = frame([
        (7, 1, 2, 1, "b"), (6, 2, 4, 1, "b"), (5, 3, 6, 1, "b"),
        (4, 4, 8, 1, "b"), (3, 5, 10, 1, "b"),
        (3, 6, 10, 8, "l"),
        (7, 7, 2, 1, "s"),
        (6, 9, 4, 5, "s"),
        (6, 9, 1, 1, "t"), (9, 9, 1, 1, "t"), (7, 10, 1, 1, "t"), (8, 10, 1, 1, "t"),
        (7, 11, 1, 1, "t"), (8, 11, 1, 1, "t"), (6, 12, 1, 1, "t"), (9, 12, 1, 1, "t"),
    ])

    /// FTP: a signpost with two boards.
    static let signpost = frame([
        (7, 1, 2, 13, "m"),
        (3, 3, 9, 3, "t"), (12, 4, 1, 1, "t"),
        (4, 8, 9, 3, "c"), (3, 9, 1, 1, "c"),
    ])

    /// SFTP: a strapped strongbox with a keyhole.
    static let strongbox = frame([
        (2, 3, 12, 3, "t"),
        (2, 6, 12, 8, "c"),
        (4, 3, 1, 11, "s"), (11, 3, 1, 11, "s"),
        (6, 7, 4, 5, "l"),
        (7, 8, 2, 2, "e"),
    ])

    /// Media server: a lantern, lit.
    static let lantern = frame([
        (6, 1, 4, 1, "m"), (5, 2, 1, 1, "m"), (10, 2, 1, 1, "m"),
        (6, 2, 4, 1, "m"),
        (5, 3, 6, 9, "m"),
        (6, 5, 4, 5, "l"),
        (7, 6, 2, 2, "t"),
        (4, 12, 8, 1, "m"),
    ])

    /// This phone: the saddlebag.
    static let saddlebag = frame([
        (3, 3, 10, 1, "b"), (2, 4, 12, 9, "b"), (3, 13, 10, 1, "b"),
        (3, 3, 4, 1, "t"), (9, 3, 4, 1, "t"),
        (2, 6, 5, 1, "s"), (9, 6, 5, 1, "s"),
        (7, 3, 2, 11, "m"),
        (6, 7, 4, 3, "s"), (7, 8, 2, 1, "t"),
    ])

    /// Photos: a leather bound album, one picture showing.
    static let album = frame([
        (3, 2, 10, 12, "c"),
        (3, 2, 2, 12, "t"),
        (6, 4, 6, 8, "l"),
        (9, 5, 2, 1, "b"),
        (7, 10, 2, 1, "m"), (6, 11, 6, 1, "m"),
    ])

    /// A nearby Packmule phone: two mules meeting.
    static let mules = frame([
        (2, 5, 5, 6, "b"), (2, 5, 1, 6, "m"), (3, 2, 1, 3, "m"),
        (5, 8, 2, 3, "l"), (4, 7, 1, 1, "e"), (2, 11, 4, 1, "b"),
        (9, 5, 5, 6, "b"), (13, 5, 1, 6, "m"), (12, 2, 1, 3, "m"),
        (9, 8, 2, 3, "l"), (11, 7, 1, 1, "e"), (10, 11, 4, 1, "b"),
    ])

    /// Folder: a feed sack with a patch.
    static let sack = frame([
        (6, 2, 4, 2, "b"),
        (5, 4, 6, 1, "m"),
        (4, 5, 8, 1, "b"), (3, 6, 10, 7, "b"), (4, 13, 8, 1, "b"),
        (8, 9, 2, 2, "t"),
    ])
}
