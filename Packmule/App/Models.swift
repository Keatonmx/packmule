//
//  Models.swift
//  Packmule
//
//  Saved servers, file entries and the small formatting helpers they share.
//

import Foundation

// MARK: - Servers

enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case smb = "SMB"
    case ftp = "FTP"
    case sftp = "SFTP"
    case jellyfin = "Jellyfin"
    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .smb: return 445
        case .ftp: return 21
        case .sftp: return 22
        case .jellyfin: return 8096
        }
    }

    var scheme: String {
        switch self {
        case .smb: return "smb"
        case .ftp: return "ftp"
        case .sftp: return "sftp"
        case .jellyfin: return "http"
        }
    }
}

struct SavedServer: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ServerKind = .smb
    /// Display name; empty means "use the host".
    var name: String = ""
    var host: String = ""
    /// nil means the protocol default.
    var port: Int? = nil
    /// SMB share. Empty means "browse the server's shares".
    var share: String = ""
    /// FTP starting directory.
    var startPath: String = "/"
    /// Empty means guest (SMB) or anonymous (FTP). Passwords live in the Keychain.
    var username: String = ""
    var lastConnected: Date? = nil
    /// Jellyfin behind a reverse proxy; optional so older saves still decode.
    var https: Bool? = nil
    /// nil or true: password lives in the Keychain. false: ask on every
    /// connect and keep nothing. Optional so older saves still decode.
    var rememberPassword: Bool? = nil

    var asksForPassword: Bool { rememberPassword == false }

    var displayName: String { name.isEmpty ? host : name }

    var addressLine: String {
        var scheme = kind.scheme
        if kind == .jellyfin, https == true { scheme = "https" }
        var s = "\(scheme)://\(host)"
        if let port, port != kind.defaultPort { s += ":\(port)" }
        if kind == .smb, !share.isEmpty { s += "/\(share)" }
        if kind == .ftp || kind == .sftp, startPath != "/", !startPath.isEmpty { s += startPath }
        return s
    }
}

/// A server another device is advertising on the local network (Bonjour).
struct DiscoveredService: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: ServerKind
    /// Another phone running Packmule (its Bonjour TXT record says so).
    var isPackmule = false
}

// MARK: - Files

struct FileEntry: Identifiable, Equatable {
    var name: String
    /// Volume path, always "/" rooted.
    var path: String
    var isDirectory: Bool
    var size: Int64? = nil
    var modified: Date? = nil

    var id: String { path + (isDirectory ? "/" : "") }

    var metaLine: String {
        var parts: [String] = []
        if isDirectory {
            parts.append("Folder")
        } else if let size {
            parts.append(size.fileSizeString)
        }
        if let modified { parts.append(modified.browserString) }
        return parts.joined(separator: " · ")
    }
}

enum BrowseSort: String, Codable, CaseIterable, Identifiable {
    case name = "A–Z"
    case size = "Size"
    case date = "Date"
    var id: String { rawValue }
}

// MARK: - Media

/// What the Apple player engine can and cannot open.
enum MediaFile {
    static let video: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf"]
    /// Containers that need a transcoding server (Jellyfin) or the FFmpeg engine.
    static let engineOnly: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "ogv", "ogg", "divx"]

    static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func isStreamable(_ name: String) -> Bool {
        let e = ext(name)
        return video.contains(e) || audio.contains(e)
    }

    static func isAudio(_ name: String) -> Bool {
        audio.contains(ext(name))
    }

    static func needsEngine(_ name: String) -> Bool {
        engineOnly.contains(ext(name))
    }
}

/// One request to open the full screen player.
struct PlayerRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
}

// MARK: - Paths

enum VolumePath {
    static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty || dir == "/" { return "/" + name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/"), idx != trimmed.startIndex else { return "/" }
        return String(trimmed[..<idx])
    }

    static func name(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

// MARK: - Formatting

extension Int64 {
    var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension Date {
    /// Short date for browser rows: time today, "5 Mar" this year, else "5 Mar 2024".
    var browserString: String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        if cal.isDateInToday(self) {
            formatter.dateFormat = "HH:mm"
        } else if cal.component(.year, from: self) == cal.component(.year, from: Date()) {
            formatter.dateFormat = "d MMM"
        } else {
            formatter.dateFormat = "d MMM yyyy"
        }
        return formatter.string(from: self)
    }

    /// "Just now", "2 h ago", "3 d ago" for server cards.
    var relativeShortString: String {
        let seconds = -timeIntervalSinceNow
        if seconds < 90 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400)) d ago" }
        return browserString
    }
}
