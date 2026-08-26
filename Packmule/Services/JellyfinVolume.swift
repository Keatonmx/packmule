//
//  JellyfinVolume.swift
//  Packmule
//
//  Jellyfin as a browsable, playable volume. Libraries and folders map to
//  directories; movies, episodes and songs map to files. Playback prefers a
//  direct stream and falls back to HLS so the server transcodes what the
//  phone can't play (MKV included). Read only by design.
//

import Foundation

final class JellyfinVolume: RemoteVolume {
    let kindLabel = "Jellyfin"
    var isReadOnly: Bool { true }

    private let base: URL
    private let username: String
    private let password: String
    private let deviceID: String

    private var token = ""
    private var userID = ""
    /// Volume path -> item, filled in while browsing.
    private var items: [String: JFItem] = [:]

    init(host: String, port: Int?, https: Bool, username: String, password: String) {
        var comps = URLComponents()
        comps.scheme = https ? "https" : "http"
        comps.host = host
        comps.port = port ?? (https ? nil : 8096)
        self.base = comps.url ?? URL(string: "http://127.0.0.1")!
        self.username = username
        self.password = password

        let key = "packmule.jellyfin.deviceid"
        if let existing = UserDefaults.standard.string(forKey: key) {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: key)
            deviceID = fresh
        }
    }

    // MARK: plumbing

    private var authHeader: String {
        "MediaBrowser Client=\"Packmule\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
    }

    private func request(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw VolumeError.badAddress
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw VolumeError.badAddress }
        var req = URLRequest(url: url)
        req.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        return req
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw VolumeError.authFailed }
        guard (200..<300).contains(code) else {
            throw VolumeError.protocolFailure("Jellyfin answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: session

    func connect() async throws {
        var req = try request("Users/AuthenticateByName")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let auth = try await fetch(JFAuth.self, req)
        token = auth.AccessToken
        userID = auth.User.Id
    }

    func disconnect() async {
        token = ""
        items = [:]
    }

    // MARK: browsing

    func list(_ path: String) async throws -> [FileEntry] {
        guard !token.isEmpty else { throw VolumeError.disconnected }
        let children: [JFItem]
        if path == "/" || path.isEmpty {
            children = try await fetch(JFItems.self, request("Users/\(userID)/Views")).Items
        } else {
            guard let parent = items[path] else { throw VolumeError.notFound(VolumePath.name(of: path)) }
            children = try await fetch(JFItems.self, request("Users/\(userID)/Items", query: [
                "ParentId": parent.Id,
                "SortBy": "IsFolder,SortName",
                "Fields": "MediaSources,DateCreated",
            ])).Items
        }

        var used = Set<String>()
        var entries: [FileEntry] = []
        for item in children {
            let isFolder = item.IsFolder ?? false
            var name = item.Name
            if !isFolder, let container = item.container, !name.lowercased().hasSuffix(".\(container)") {
                name += ".\(container)"
            }
            var candidate = name
            var counter = 2
            while used.contains(candidate) {
                candidate = "\(name) \(counter)"
                counter += 1
            }
            used.insert(candidate)
            let entryPath = VolumePath.join(path, candidate)
            items[entryPath] = item
            entries.append(FileEntry(
                name: candidate,
                path: entryPath,
                isDirectory: isFolder,
                size: isFolder ? nil : item.size,
                modified: item.created))
        }
        return entries
    }

    // MARK: playback

    /// Direct stream for containers the phone plays; HLS (server transcode)
    /// for everything else. That's what makes MKV work on the Apple engine.
    func playbackURL(for entry: FileEntry) -> URL? {
        guard let item = items[entry.path], !token.isEmpty else { return nil }
        if item.MediaType == "Audio" || item.TypeName == "Audio" {
            return url("Audio/\(item.Id)/universal", query: [
                "api_key": token,
                "UserId": userID,
                "DeviceId": deviceID,
                "Container": "mp3,aac,m4a,flac,wav",
                "TranscodingContainer": "mp3",
                "TranscodingProtocol": "http",
            ])
        }
        let container = item.container ?? ""
        if ["mp4", "m4v", "mov"].contains(container) {
            return url("Videos/\(item.Id)/stream.\(container)", query: [
                "api_key": token,
                "Static": "true",
                "MediaSourceId": item.mediaSourceID ?? item.Id,
            ])
        }
        return url("Videos/\(item.Id)/master.m3u8", query: [
            "api_key": token,
            "DeviceId": deviceID,
            "MediaSourceId": item.mediaSourceID ?? item.Id,
            "VideoCodec": "h264",
            "AudioCodec": "aac,mp3",
            "VideoBitrate": "20000000",
            "AudioBitrate": "384000",
            "SegmentContainer": "ts",
            "MinSegments": "1",
            "BreakOnNonKeyFrames": "True",
            "TranscodeReasons": "ContainerNotSupported",
        ])
    }

    private func url(_ path: String, query: [String: String]) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps?.url
    }

    // MARK: transfers

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        try await download(entry, to: url, resumingFrom: 0, progress: progress)
    }

    func download(_ entry: FileEntry, to url: URL, resumingFrom offset: Int64,
                  progress: @escaping TransferProgress) async throws {
        guard let item = items[entry.path] else { throw VolumeError.notFound(entry.name) }
        guard let source = self.url("Items/\(item.Id)/Download", query: ["api_key": token]) else {
            throw VolumeError.badAddress
        }
        _ = progress(offset, entry.size ?? -1)
        var request = URLRequest(url: source)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let (temp, response) = try await URLSession.shared.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: temp)
            throw VolumeError.protocolFailure("Jellyfin answered \(code)")
        }
        if code == 206, offset > 0 {
            // Partial content: stitch the new bytes onto the existing tail.
            let handle = try appendHandle(for: url, at: offset)
            defer { try? handle.close() }
            let reading = try FileHandle(forReadingFrom: temp)
            defer { try? reading.close() }
            while let chunk = try reading.read(upToCount: 1 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try? FileManager.default.removeItem(at: temp)
        } else {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? entry.size ?? -1
        _ = progress(size, size)
    }

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        throw VolumeError.unsupported("uploading to Jellyfin")
    }

    func delete(_ entry: FileEntry) async throws {
        throw VolumeError.unsupported("deleting from Jellyfin")
    }

    func createFolder(named name: String, in dir: String) async throws {
        throw VolumeError.unsupported("folders on Jellyfin")
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        throw VolumeError.unsupported("renaming on Jellyfin")
    }
}

// MARK: - Wire format

private struct JFAuth: Decodable {
    let AccessToken: String
    let User: JFUser
}

private struct JFUser: Decodable {
    let Id: String
}

private struct JFItems: Decodable {
    let Items: [JFItem]
}

private struct JFItem: Decodable {
    let Id: String
    let Name: String
    let IsFolder: Bool?
    let MediaType: String?
    let Container: String?
    let DateCreated: String?
    let MediaSources: [JFSource]?

    enum CodingKeys: String, CodingKey {
        case Id, Name, IsFolder, MediaType, Container, DateCreated, MediaSources
        case TypeName = "Type"
    }
    let TypeName: String?

    var container: String? {
        let raw = MediaSources?.first?.Container ?? Container
        // Jellyfin sometimes reports "mov,mp4,m4a" style lists; take the first.
        return raw?.split(separator: ",").first.map(String.init)
    }

    var size: Int64? { MediaSources?.first?.Size }

    var mediaSourceID: String? { MediaSources?.first?.Id }

    var created: Date? {
        guard let DateCreated else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: DateCreated) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: DateCreated)
    }
}

private struct JFSource: Decodable {
    let Id: String?
    let Size: Int64?
    let Container: String?
}
