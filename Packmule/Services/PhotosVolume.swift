//
//  PhotosVolume.swift
//  Packmule
//
//  The photo library as a read-only volume: smart folders (All Photos,
//  Videos, Favorites, Screenshots) plus the user's albums. Downloading
//  exports the original file, fetching from iCloud when needed. Nothing is
//  ever written back to the library.
//

import Foundation
import Photos

final class PhotosVolume: RemoteVolume {
    let kindLabel = "Photos"
    var isReadOnly: Bool { true }

    /// Most items listed per folder, newest first.
    private static let listCap = 4000

    private var assetsByPath: [String: PHAsset] = [:]

    func connect() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw VolumeError.protocolFailure("Photos access was declined. Allow it in Settings, Privacy, Photos")
        }
    }

    // MARK: listing

    private static let smartFolders = ["All Photos", "Videos", "Favorites", "Screenshots"]

    func list(_ path: String) async throws -> [FileEntry] {
        if path == "/" || path.isEmpty {
            var entries = Self.smartFolders.map {
                FileEntry(name: $0, path: "/" + $0, isDirectory: true)
            }
            var seen = Set(Self.smartFolders)
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            albums.enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle, !title.isEmpty, !seen.contains(title) {
                    seen.insert(title)
                    entries.append(FileEntry(name: title, path: "/" + title, isDirectory: true))
                }
            }
            return entries
        }

        let folder = VolumePath.components(path).first ?? ""
        let assets = fetchAssets(for: folder)
        var entries: [FileEntry] = []
        var usedNames = Set<String>()
        assets.enumerateObjects { asset, index, stop in
            if index >= Self.listCap {
                stop.pointee = true
                return
            }
            var name = Self.filename(for: asset)
            if usedNames.contains(name) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var counter = 2
                var candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                while usedNames.contains(candidate) {
                    counter += 1
                    candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                }
                name = candidate
            }
            usedNames.insert(name)
            let entryPath = VolumePath.join("/" + folder, name)
            self.assetsByPath[entryPath] = asset
            entries.append(FileEntry(name: name, path: entryPath, isDirectory: false,
                                     size: nil, modified: asset.creationDate))
        }
        return entries
    }

    private func fetchAssets(for folder: String) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch folder {
        case "All Photos":
            break
        case "Videos":
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case "Favorites":
            options.predicate = NSPredicate(format: "favorite == YES")
        case "Screenshots":
            options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0",
                                            PHAssetMediaSubtype.photoScreenshot.rawValue)
        default:
            // A user album by title.
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var found: PHAssetCollection?
            albums.enumerateObjects { collection, _, stop in
                if collection.localizedTitle == folder {
                    found = collection
                    stop.pointee = true
                }
            }
            if let found {
                return PHAsset.fetchAssets(in: found, options: options)
            }
        }
        return PHAsset.fetchAssets(with: options)
    }

    private static func filename(for asset: PHAsset) -> String {
        if let name = asset.value(forKey: "filename") as? String, !name.isEmpty {
            return name
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd HH.mm.ss"
        let stamp = formatter.string(from: asset.creationDate ?? Date())
        return asset.mediaType == .video ? "Video \(stamp).mov" : "Photo \(stamp).jpg"
    }

    // MARK: transfer

    func download(_ entry: FileEntry, to url: URL, progress: @escaping TransferProgress) async throws {
        guard let asset = assetsByPath[entry.path] else { throw VolumeError.notFound(entry.name) }
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .video || $0.type == .photo } ?? resources.first
        guard let resource else { throw VolumeError.notFound(entry.name) }

        let total = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? -1
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // fetch the original from iCloud when needed
        options.progressHandler = { fraction in
            if total > 0 {
                _ = progress(Int64(fraction * Double(total)), total)
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        if total > 0 { _ = progress(total, total) }
    }

    // MARK: read-only stubs

    func upload(_ localURL: URL, toDirectory dir: String, name: String, progress: @escaping TransferProgress) async throws {
        throw VolumeError.unsupported("adding to the photo library")
    }

    func delete(_ entry: FileEntry) async throws {
        throw VolumeError.unsupported("changing the photo library")
    }

    func createFolder(named name: String, in dir: String) async throws {
        throw VolumeError.unsupported("changing the photo library")
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        throw VolumeError.unsupported("changing the photo library")
    }

    func disconnect() async {}
}
