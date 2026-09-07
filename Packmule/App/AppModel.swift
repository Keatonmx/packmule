//
//  AppModel.swift
//  Packmule
//
//  One observable object driving everything: saved servers, the active
//  browser session, sheets, toasts and the transfer queue.
//

import SwiftUI
import UIKit
import Network

enum Screen: Equatable {
    case home
    case browser
}

enum ActiveSheet: Equatable {
    /// Prefill values (nil = blank form); isEdit switches the copy and shows Forget.
    case addServer(SavedServer?, isEdit: Bool)
    case serverActions(SavedServer)
    case fileActions(FileEntry)
    case confirmDelete(FileEntry)
    case rename(FileEntry)
    case newFolder
    case transfers
    case settings
    case about
    case host
    /// The server's password isn't stored; ask, connect, forget.
    case passwordPrompt(SavedServer)
    /// Type or paste a path, jump straight there.
    case goToPath
    /// Multi-select delete confirmation.
    case confirmDeleteMany([FileEntry])
    /// Reachability, round trip time, server banner.
    case connectionDetails(SavedServer)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            SettingsStore.save(settings)
            ButtonHaptics.shared.enabled = settings.haptics
            if oldValue.sort != settings.sort || oldValue.foldersFirst != settings.foldersFirst
                || oldValue.showHidden != settings.showHidden {
                entries = Self.arrange(rawEntries, settings: settings)
            }
        }
    }
    @Published var servers: [SavedServer]
    @Published var screen: Screen = .home
    @Published var activeSheet: ActiveSheet?
    @Published var toast: String?
    /// Server currently mid-connect; its card shows a spinner.
    @Published var connectingID: UUID?

    // Browser session
    @Published var browserTitle = ""
    @Published var browserKind = ""
    @Published var path = "/"
    @Published var entries: [FileEntry] = []
    @Published var browserLoading = false
    @Published var browserError: String?
    @Published var searchText = ""
    /// Browser type filter; folders always pass.
    @Published var typeFilter: FileTypeFilter = .all
    /// Multi-select mode in the browser.
    @Published var selecting = false
    @Published var selectedPaths: Set<String> = []
    /// smb://host/share style prefix for the connected volume (copy path).
    @Published var browserAddress = ""
    /// Pulse dots on the server cards: id -> answered the last probe.
    @Published var reachable: [UUID: Bool] = [:]

    // System sheets
    @Published var quickLookURL: URL?
    @Published var shareURL: URL?
    @Published var showingImporter = false
    @Published var showingFolderPicker = false
    /// Non-nil while the full screen player is up.
    @Published var playerRequest: PlayerRequest?

    @Published var linkedFolders: [LinkedFolder] = LinkedFolderStore.load()

    private(set) var volume: (any RemoteVolume)?
    private var rawEntries: [FileEntry] = []
    private var listGeneration = 0
    private var toastGeneration = 0
    private var demoMode = false

    let transfers = TransferQueue()
    let discovery = Discovery()
    let ftpServer = FTPServer()

    var theme: ThemeTokens { .tokens(for: settings.theme) }

    init() {
        settings = SettingsStore.load()
        servers = ServerStore.load()
        ButtonHaptics.shared.enabled = settings.haptics
        transfers.onFinished = { [weak self] item in self?.transferFinished(item) }
        transfers.onActivity = { [weak self] in
            guard let self else { return }
            self.updateIdleTimer()
            if #available(iOS 16.2, *) {
                LiveActivityManager.shared.queueChanged(self.transfers)
            }
        }
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.onProblem = { [weak self] message in
                self?.showToast(message)
            }
        }
        #if DEBUG
        handleLaunchArguments()
        #endif
        if !demoMode { discovery.start() }
    }

    var sortedServers: [SavedServer] {
        servers.sorted { a, b in
            let da = a.lastConnected ?? .distantPast
            let db = b.lastConnected ?? .distantPast
            if da != db { return da > db }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    var visibleEntries: [FileEntry] {
        var list = entries
        if typeFilter != .all {
            list = list.filter { typeFilter.matches($0) }
        }
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Sheets & toasts

    func openSheet(_ sheet: ActiveSheet?) {
        activeSheet = sheet
    }

    func showToast(_ message: String) {
        withAnimation { toast = message }
        toastGeneration += 1
        let generation = toastGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: - Server list

    func save(_ server: SavedServer, password: String?) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        if let password { Keychain.setPassword(password, for: server.id) }
        persistServers()
    }

    func forget(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        Keychain.deletePassword(for: server.id)
        persistServers()
        showToast("Forgot \(server.displayName)")
    }

    private func persistServers() {
        guard !demoMode else { return }
        ServerStore.save(servers)
    }

    func addDiscovered(_ service: DiscoveredService) {
        Task {
            var draft = SavedServer()
            draft.kind = service.kind
            draft.name = service.name
            if let resolved = await discovery.resolve(service) {
                draft.host = resolved.host
                if resolved.port != service.kind.defaultPort { draft.port = resolved.port }
            }
            openSheet(.addServer(draft, isEdit: false))
        }
    }

    // MARK: - Connecting

    func connect(_ server: SavedServer) {
        guard connectingID == nil else { return }
        if server.asksForPassword {
            openSheet(.passwordPrompt(server))
            return
        }
        startConnect(server, password: Keychain.password(for: server.id) ?? "")
    }

    /// From the password prompt; the password is used once and not stored.
    func connect(_ server: SavedServer, oneTimePassword: String) {
        guard connectingID == nil else { return }
        openSheet(nil)
        startConnect(server, password: oneTimePassword)
    }

    private func startConnect(_ server: SavedServer, password: String) {
        connectingID = server.id
        let volume = makeVolume(for: server, password: password)
        Task {
            do {
                try await volume.connect()
                self.volume = volume
                browserTitle = server.displayName
                browserKind = volume.kindLabel
                browserAddress = server.addressLine
                reachable[server.id] = true
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].lastConnected = Date()
                    persistServers()
                }
                let start = server.kind == .smb ? "/" : Self.normalized(server.startPath)
                enterBrowser(at: start)
            } catch {
                if let volumeError = error as? VolumeError, case .authFailed = volumeError {
                    // Wrong or missing sign in: ask instead of just complaining.
                    openSheet(.passwordPrompt(server))
                } else {
                    showToast(Self.friendly(error))
                }
            }
            connectingID = nil
        }
    }

    /// Tap a fellow Packmule under Nearby: resolve it and walk right in.
    func connectNearby(_ service: DiscoveredService) {
        Task {
            guard let resolved = await discovery.resolve(service) else {
                showToast("Couldn't reach \(service.name)")
                return
            }
            var server = SavedServer()
            server.kind = .ftp
            server.name = service.name
            server.host = resolved.host
            if resolved.port != ServerKind.ftp.defaultPort {
                server.port = resolved.port
            }
            connect(server)
        }
    }

    private static func normalized(_ startPath: String) -> String {
        let trimmed = startPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private func makeVolume(for server: SavedServer, password: String) -> any RemoteVolume {
        switch server.kind {
        case .smb:
            return SMBVolume(host: server.host, port: server.port, share: server.share,
                             username: server.username, password: password)
        case .ftp:
            return FTPVolume(host: server.host, port: server.port,
                             username: server.username, password: password)
        case .sftp:
            return SFTPVolume(host: server.host, port: server.port,
                              username: server.username, password: password)
        case .jellyfin:
            return JellyfinVolume(host: server.host, port: server.port,
                                  https: server.https ?? false,
                                  username: server.username, password: password)
        }
    }

    func openLocal() {
        let volume = LocalVolume()
        Task {
            try? await volume.connect()
            self.volume = volume
            browserTitle = "This iPhone"
            browserKind = volume.kindLabel
            browserAddress = ""
            enterBrowser(at: "/")
        }
    }

    func openPhotos() {
        let volume = PhotosVolume()
        Task {
            do {
                try await volume.connect()
            } catch {
                showToast(Self.friendly(error))
                return
            }
            self.volume = volume
            browserTitle = "Photos"
            browserKind = volume.kindLabel
            browserAddress = ""
            enterBrowser(at: "/")
        }
    }

    // MARK: - Linked folders

    func openLinked(_ folder: LinkedFolder) {
        guard let url = LinkedFolderStore.resolve(folder) else {
            showToast("Lost access. Unlink it, then link it again")
            return
        }
        let volume = LocalVolume(root: url, securityScoped: true, kindLabel: "Linked")
        Task {
            do {
                try await volume.connect()
            } catch {
                showToast(Self.friendly(error))
                return
            }
            self.volume = volume
            browserTitle = folder.name
            browserKind = volume.kindLabel
            browserAddress = ""
            enterBrowser(at: "/")
        }
    }

    func handlePickedFolder(_ url: URL) {
        showingFolderPicker = false
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            showToast("Couldn't keep access to that folder")
            return
        }
        // Names double as FTP mount names, so keep them unique.
        let base = url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
        let existing = Set(linkedFolders.map(\.name))
        var name = base
        var counter = 2
        while existing.contains(name) {
            name = "\(base) \(counter)"
            counter += 1
        }
        linkedFolders.append(LinkedFolder(name: name, bookmark: bookmark))
        LinkedFolderStore.save(linkedFolders)
        showToast("Linked \(name)")
    }

    func unlink(_ folder: LinkedFolder) {
        linkedFolders.removeAll { $0.id == folder.id }
        LinkedFolderStore.save(linkedFolders)
        showToast("Unlinked \(folder.name)")
    }

    private func enterBrowser(at start: String) {
        searchText = ""
        withAnimation(.easeInOut(duration: 0.25)) { screen = .browser }
        load(start)
    }

    func closeBrowser() {
        withAnimation(.easeInOut(duration: 0.25)) { screen = .home }
        let volume = self.volume
        self.volume = nil
        rawEntries = []
        entries = []
        path = "/"
        browserError = nil
        searchText = ""
        browserAddress = ""
        selecting = false
        selectedPaths = []
        typeFilter = .all
        // Leave the connection alive while it still has transfers to finish.
        if transfers.activeCount == 0 {
            Task { await volume?.disconnect() }
        }
    }

    // MARK: - Listing

    func load(_ newPath: String) {
        guard let volume else { return }
        selecting = false
        selectedPaths = []
        path = newPath
        browserError = nil
        browserLoading = true
        rawEntries = []
        entries = []
        listGeneration += 1
        let generation = listGeneration
        Task {
            do {
                let raw = try await volume.list(newPath)
                guard generation == listGeneration else { return }
                rawEntries = raw
                entries = Self.arrange(raw, settings: settings)
                browserLoading = false
            } catch {
                guard generation == listGeneration else { return }
                browserLoading = false
                browserError = Self.friendly(error)
            }
        }
    }

    static func arrange(_ raw: [FileEntry], settings: AppSettings) -> [FileEntry] {
        var list = raw
        if !settings.showHidden { list.removeAll { $0.name.hasPrefix(".") } }
        list.sort { a, b in
            if settings.foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
            switch settings.sort {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size:
                return (a.size ?? -1) > (b.size ?? -1)
            case .date:
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
        return list
    }

    func open(_ entry: FileEntry) {
        if selecting {
            toggleSelection(entry)
            return
        }
        if entry.isDirectory {
            searchText = ""
            load(entry.path)
        } else {
            openSheet(.fileActions(entry))
        }
    }

    // MARK: - Multi-select

    func beginSelecting() {
        selecting = true
        selectedPaths = []
    }

    func endSelecting() {
        selecting = false
        selectedPaths = []
    }

    func toggleSelection(_ entry: FileEntry) {
        ButtonHaptics.shared.tick()
        if selectedPaths.contains(entry.path) {
            selectedPaths.remove(entry.path)
        } else {
            selectedPaths.insert(entry.path)
        }
    }

    var selectedEntries: [FileEntry] {
        entries.filter { selectedPaths.contains($0.path) }
    }

    func downloadSelected() {
        guard let volume else { return }
        let picked = selectedEntries
        for entry in picked {
            if entry.isDirectory {
                transfers.enqueueFolderDownload(volume: volume, folder: entry, from: browserTitle)
            } else {
                transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle)
            }
        }
        endSelecting()
        guard !picked.isEmpty else { return }
        showToast(picked.count == 1 ? "Hauling \(picked[0].name)" : "Hauling \(picked.count) items")
    }

    func requestDeleteSelected() {
        let picked = selectedEntries
        guard !picked.isEmpty else { return }
        openSheet(.confirmDeleteMany(picked))
    }

    func performDeleteSelected(_ picked: [FileEntry]) {
        guard let volume else { return }
        openSheet(nil)
        endSelecting()
        Task {
            var failed = 0
            for entry in picked {
                do {
                    try await volume.delete(entry)
                } catch {
                    failed += 1
                }
            }
            showToast(failed == 0 ? "Deleted \(picked.count) items"
                                  : "Deleted \(picked.count - failed), \(failed) refused")
            refresh()
        }
    }

    // MARK: - Paths for people who think in paths

    func goTo(_ rawPath: String) {
        openSheet(nil)
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchText = ""
        load(trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }

    func copyPath(_ entry: FileEntry) {
        UIPasteboard.general.string = browserAddress.isEmpty
            ? entry.path
            : browserAddress + entry.path
        openSheet(nil)
        showToast("Copied")
    }

    // MARK: - Reachability pulse

    func probeServers() {
        for server in servers {
            let host = server.host
            let port = server.port ?? server.kind.defaultPort
            let id = server.id
            Task { [weak self] in
                let result = await Probe.tcp(host: host, port: port)
                self?.reachable[id] = result.rttMillis != nil
            }
        }
    }

    func goUp() {
        if path == "/" || path.isEmpty {
            closeBrowser()
        } else {
            searchText = ""
            load(VolumePath.parent(of: path))
        }
    }

    func refresh() {
        load(path)
    }

    // MARK: - File actions

    func download(_ entry: FileEntry) {
        guard let volume else { return }
        if entry.isDirectory {
            transfers.enqueueFolderDownload(volume: volume, folder: entry, from: browserTitle)
        } else {
            transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle)
        }
        openSheet(nil)
        showToast("Hauling \(entry.name)")
    }

    func preview(_ entry: FileEntry) {
        guard let volume else { return }
        openSheet(nil)
        if let local = volume.localURL(for: entry) {
            quickLookURL = local
            return
        }
        transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle, purpose: .preview)
        showToast("Fetching \(entry.name)")
    }

    func share(_ entry: FileEntry) {
        guard let volume else { return }
        openSheet(nil)
        if let local = volume.localURL(for: entry) {
            shareURL = local
            return
        }
        transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle, purpose: .share)
        showToast("Fetching \(entry.name)")
    }

    func requestDelete(_ entry: FileEntry) {
        if settings.confirmDelete {
            openSheet(.confirmDelete(entry))
        } else {
            performDelete(entry)
        }
    }

    func performDelete(_ entry: FileEntry) {
        guard let volume else { return }
        openSheet(nil)
        Task {
            do {
                try await volume.delete(entry)
                showToast("Deleted \(entry.name)")
                refresh()
            } catch {
                showToast(Self.friendly(error))
            }
        }
    }

    func performRename(_ entry: FileEntry, to newName: String) {
        openSheet(nil)
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let volume, !trimmed.isEmpty, trimmed != entry.name else { return }
        Task {
            do {
                try await volume.rename(entry, to: trimmed)
                showToast("Renamed")
                refresh()
            } catch {
                showToast(Self.friendly(error))
            }
        }
    }

    func performNewFolder(_ name: String) {
        openSheet(nil)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let volume, !trimmed.isEmpty else { return }
        Task {
            do {
                try await volume.createFolder(named: trimmed, in: path)
                showToast("Made \(trimmed)")
                refresh()
            } catch {
                showToast(Self.friendly(error))
            }
        }
    }

    func handlePicked(_ urls: [URL]) {
        showingImporter = false
        guard let volume, !urls.isEmpty else { return }
        for url in urls {
            transfers.enqueueUpload(volume: volume, localURL: url, toDirectory: path, on: browserTitle)
        }
        showToast(urls.count == 1 ? "Hauling \(urls[0].lastPathComponent)" : "Hauling \(urls.count) files")
    }

    private func transferFinished(_ item: TransferItem) {
        switch item.purpose {
        case .keep:
            if item.direction == .download {
                showToast("Saved to Downloads: \(item.name)")
            } else {
                showToast("Sent \(item.name)")
                if screen == .browser { refresh() }
            }
        case .preview:
            if let url = item.destination { quickLookURL = url }
        case .share:
            if let url = item.destination { shareURL = url }
        case .play:
            if let url = item.destination {
                playerRequest = PlayerRequest(title: item.name, url: url)
            }
        }
    }

    // MARK: - Playback

    func play(_ entry: FileEntry) {
        guard let volume else { return }
        openSheet(nil)
        if let jellyfin = volume as? JellyfinVolume {
            if let url = jellyfin.playbackURL(for: entry) {
                playerRequest = PlayerRequest(title: entry.name, url: url)
            } else {
                showToast("Jellyfin wouldn't stream that item")
            }
            return
        }
        if let local = volume.localURL(for: entry) {
            playerRequest = PlayerRequest(title: entry.name, url: local)
            return
        }
        // Apple's player refuses raw FLAC over HTTP (a format whitelist, not a
        // server problem); as a local file it plays fine, so fetch first.
        if MediaFile.ext(entry.name) == "flac" {
            transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle, purpose: .play)
            showToast("FLAC can't stream on the Apple player yet: fetching a copy")
            return
        }
        let title = entry.name
        Task {
            do {
                if let url = try await MediaStreamer.shared.makeURL(entry: entry, volume: volume) {
                    playerRequest = PlayerRequest(title: title, url: url)
                } else {
                    // Plain FTP can't seek; fetch a copy and play that.
                    transfers.enqueueDownload(volume: volume, entry: entry,
                                              from: browserTitle, purpose: .play)
                    showToast("FTP can't seek: fetching a copy to play")
                }
            } catch {
                showToast(Self.friendly(error))
            }
        }
    }

    func playerClosed() {
        MediaStreamer.shared.clearTarget()
        updateIdleTimer()
    }

    /// One place decides whether the screen may sleep: hauling (when the
    /// setting allows), hosting, and the player all keep it lit.
    func updateIdleTimer() {
        let hauling = settings.keepAwakeWhileHauling && transfers.activeCount > 0
        UIApplication.shared.isIdleTimerDisabled =
            hauling || ftpServer.running || playerRequest != nil
    }

    // MARK: - Errors people can read

    static func friendly(_ error: Error) -> String {
        if let volumeError = error as? VolumeError {
            return volumeError.localizedDescription
        }
        if let nw = error as? NWError, case .posix(let code) = nw {
            switch code {
            case .ETIMEDOUT: return "Timed out. Is the server awake, and the VPN on?"
            case .ECONNREFUSED: return "The server refused the connection"
            case .EHOSTUNREACH, .ENETUNREACH: return "Can't reach that host. Check the network or VPN"
            case .ECONNRESET: return "The server closed the connection"
            default: break
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case 60: return "Timed out. Is the server awake, and the VPN on?"
            case 61: return "The server refused the connection"
            case 64, 65: return "Can't reach that host. Check the network or VPN"
            case 13: return "Permission denied. Check the user and password"
            default: break
            }
        }
        let message = error.localizedDescription
        // libsmb2 reports NT status codes; translate the two everyone hits.
        let lower = message.lowercased()
        if lower.contains("0xc0000022") || lower.contains("access_denied")
            || lower.contains("0xc000006d") || lower.contains("logon_failure") {
            return "The server refused the sign in. Guest may be disabled: set the user and password (hold the card, Edit). Server said: \(message)"
        }
        if lower.contains("0xc00000cc") || lower.contains("bad_network_name") {
            return "The server has no share by that name. Server said: \(message)"
        }
        return message.isEmpty ? "Something went wrong" : message
    }

    // MARK: - CI screenshot hooks (Debug builds only)

    #if DEBUG
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }
        if let themeName = value(after: "-packmule-theme"), let theme = ThemeName(rawValue: themeName) {
            settings.theme = theme
        }
        if args.contains("-packmule-demo") {
            demoMode = true
            var home = SavedServer()
            home.kind = .smb; home.name = "Home media"; home.host = "10.0.0.253"; home.share = "media"
            home.lastConnected = Date(timeIntervalSinceNow: -3600)
            var pi = SavedServer()
            pi.kind = .ftp; pi.name = "Backup pi"; pi.host = "192.168.1.40"; pi.port = 2121
            var workshop = SavedServer()
            workshop.kind = .smb; workshop.name = "Workshop PC"; workshop.host = "10.0.0.20"
            servers = [home, pi, workshop]
            discovery.injectDemo()
        }
        if args.contains("-packmule-transfers") {
            transfers.injectDemo()
        }
        if args.contains("-packmule-browse") {
            demoMode = true
            let volume = DemoVolume()
            self.volume = volume
            browserTitle = "Home media"
            browserKind = "SMB"
            screen = .browser
            load("/")
        }
        if let sheetName = value(after: "-packmule-sheet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                switch sheetName {
                case "addServer": self.activeSheet = .addServer(nil, isEdit: false)
                case "serverActions":
                    if let server = self.sortedServers.first { self.activeSheet = .serverActions(server) }
                case "fileActions":
                    let entry = self.entries.first { !$0.isDirectory }
                        ?? FileEntry(name: "family-trip-2019.mp4", path: "/family-trip-2019.mp4",
                                     isDirectory: false, size: 1_502_000_000, modified: Date())
                    self.activeSheet = .fileActions(entry)
                case "transfers": self.activeSheet = .transfers
                case "settings": self.activeSheet = .settings
                case "about": self.activeSheet = .about
                case "newFolder": self.activeSheet = .newFolder
                case "host": self.activeSheet = .host
                default: break
                }
            }
        }
    }
    #endif
}
