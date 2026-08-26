//
//  AppModel.swift
//  Packmule
//
//  One observable object driving everything: saved servers, the active
//  browser session, sheets, toasts and the transfer queue.
//

import SwiftUI
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

    // System sheets
    @Published var quickLookURL: URL?
    @Published var shareURL: URL?
    @Published var showingImporter = false

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
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
        connectingID = server.id
        let volume = makeVolume(for: server)
        Task {
            do {
                try await volume.connect()
                self.volume = volume
                browserTitle = server.displayName
                browserKind = volume.kindLabel
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].lastConnected = Date()
                    persistServers()
                }
                let start = server.kind == .smb ? "/" : Self.normalized(server.startPath)
                enterBrowser(at: start)
            } catch {
                showToast(Self.friendly(error))
            }
            connectingID = nil
        }
    }

    private static func normalized(_ startPath: String) -> String {
        let trimmed = startPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private func makeVolume(for server: SavedServer) -> any RemoteVolume {
        let password = Keychain.password(for: server.id) ?? ""
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
        }
    }

    func openLocal() {
        let volume = LocalVolume()
        Task {
            try? await volume.connect()
            self.volume = volume
            browserTitle = "This iPhone"
            browserKind = volume.kindLabel
            enterBrowser(at: "/")
        }
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
        // Leave the connection alive while it still has transfers to finish.
        if transfers.activeCount == 0 {
            Task { await volume?.disconnect() }
        }
    }

    // MARK: - Listing

    func load(_ newPath: String) {
        guard let volume else { return }
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
        if entry.isDirectory {
            searchText = ""
            load(entry.path)
        } else {
            openSheet(.fileActions(entry))
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
        transfers.enqueueDownload(volume: volume, entry: entry, from: browserTitle)
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
        }
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
