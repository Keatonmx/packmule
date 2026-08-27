//
//  HomeView.swift
//  Packmule
//
//  "PACKMULE" eyebrow over the "Servers" large title, the saved-server cards,
//  nearby Bonjour finds, and the door into the phone's own files.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfers: TransferQueue
    @EnvironmentObject private var discovery: Discovery
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if transfers.activeCount > 0 {
                        ActiveTransfersCard()
                            .padding(.bottom, 16)
                    }

                    serversCard

                    addServerTile
                        .padding(.bottom, 20)

                    if !discovery.services.isEmpty {
                        SectionHeader(title: "Nearby")
                        Card {
                            ForEach(Array(discovery.services.enumerated()), id: \.element.id) { index, service in
                                NearbyRow(service: service,
                                          showsSeparator: index < discovery.services.count - 1)
                            }
                        }
                    }

                    SectionHeader(title: "This iPhone")
                    Card {
                        NavRow(title: "Browse this iPhone",
                               subtitle: "Downloads land here, visible in the Files app") {
                            model.openLocal()
                        }
                        NavRow(title: "Photos",
                               subtitle: "Read only. Asks for photo access once, used only to show your library and copy items out of it") {
                            model.openPhotos()
                        }
                        HostRow(showsSeparator: true)
                        ForEach(model.linkedFolders) { folder in
                            LinkedFolderRow(folder: folder)
                        }
                        NavRow(title: "Link a folder",
                               subtitle: "Optional: iOS keeps every app inside its own folder. Linking folders from Files lets Packmule browse and host them too",
                               showsSeparator: false, showsChevron: false) {
                            model.showingFolderPicker = true
                        }
                    }

                    if !transfers.items.isEmpty, transfers.activeCount == 0 {
                        Button {
                            ButtonHaptics.shared.tap()
                            model.openSheet(.transfers)
                        } label: {
                            Text("Transfer log")
                                .font(Typography.meta13)
                                .foregroundColor(Palette.text40)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(FadePressStyle())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                    }

                    Text("EVERYTHING HERE IS FREE · THERE IS NO PRO")
                        .font(Typography.mono8Bold)
                        .tracking(1)
                        .foregroundColor(Palette.textQuaternary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 60)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .onAppear { model.probeServers() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                MuleStamp()
                Text("Servers")
                    .font(Typography.largeTitle)
                    .tracking(0.3)
                    .foregroundColor(.white)
            }
            Spacer()
            CircleIconButton(size: 44, action: { model.openSheet(.settings) }) {
                SettingsGlyph()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var serversCard: some View {
        let servers = model.sortedServers
        if servers.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Palette.text40)
                Text("No servers yet")
                    .font(Typography.cardTitle)
                    .foregroundColor(Palette.text55)
                Text("Add your NAS, your PC, another phone: anything that speaks SMB, FTP or SFTP. On a VPN like WireGuard, just use the tunnel address.")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 12)
        } else {
            Card {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    ServerRow(server: server, showsSeparator: index < servers.count - 1)
                }
            }
        }
    }

    private var addServerTile: some View {
        Button {
            ButtonHaptics.shared.tap()
            model.openSheet(.addServer(nil, isEdit: false))
        } label: {
            HStack(spacing: 8) {
                Text("+").font(.system(size: 20, weight: .regular)).foregroundColor(theme.accent)
                Text("Add server").font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.text55)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundColor(Color(rgba: 235, 235, 245, 0.2))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle())
    }
}

// MARK: - Rows

/// A folder linked from the Files app; hold to unlink.
struct LinkedFolderRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let folder: LinkedFolder

    var body: some View {
        NavRow(title: folder.name,
               subtitle: "Linked folder, served while hosting. Hold to unlink") {
            model.openLinked(folder)
        }
        .contextMenu {
            Button { model.openLinked(folder) } label: { Label("Open", systemImage: "folder") }
            Button(role: .destructive) { model.unlink(folder) } label: { Label("Unlink", systemImage: "minus.circle") }
        }
    }
}

/// "Host this iPhone" row with a live green dot while the server runs.
struct HostRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var server: FTPServer
    @Environment(\.theme) private var theme
    var showsSeparator = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                model.openSheet(.host)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Host this iPhone").font(Typography.row).foregroundColor(.white)
                        Text(server.running
                             ? "Serving on port \(server.config.port). Keep the app open"
                             : "Let other devices connect here over FTP")
                            .font(Typography.rowSubtitle)
                            .foregroundColor(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if server.running {
                        Circle().fill(Color(hex: 0x58CC52)).frame(width: 8, height: 8)
                    }
                    RowChevron()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            if showsSeparator { RowSeparator() }
        }
    }
}

struct ServerRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let server: SavedServer
    var showsSeparator = true

    private var connecting: Bool { model.connectingID == server.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    ButtonHaptics.shared.tap()
                    model.connect(server)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.tint)
                            Image(systemName: Self.icon(for: server.kind))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(theme.accentText)
                        }
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .bottomTrailing) {
                            if let alive = model.reachable[server.id] {
                                Circle()
                                    .fill(alive ? theme.accent : Palette.text40.opacity(0.5))
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(theme.card, lineWidth: 2))
                                    .offset(x: 2, y: 2)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName)
                                .font(Typography.rowSemibold)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(meta)
                                .font(Typography.rowSubtitle)
                                .foregroundColor(Palette.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 12)
                    .frame(minHeight: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .contextMenu {
                    Button { model.connect(server) } label: { Label("Connect", systemImage: "bolt.fill") }
                    Button { model.openSheet(.addServer(server, isEdit: true)) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { model.forget(server) } label: { Label("Forget", systemImage: "trash") }
                }

                if connecting {
                    ProgressView()
                        .tint(theme.accentText)
                        .padding(.trailing, 16)
                } else {
                    Button {
                        ButtonHaptics.shared.tap()
                        model.openSheet(.serverActions(server))
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Palette.text40)
                            .frame(width: 44, height: 64)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FadePressStyle())
                }
            }
            if showsSeparator { RowSeparator().padding(.leading, 68) }
        }
    }

    private var meta: String {
        if let when = server.lastConnected {
            return "\(server.addressLine) · \(when.relativeShortString)"
        }
        return server.addressLine
    }

    static func icon(for kind: ServerKind) -> String {
        switch kind {
        case .smb: return "externaldrive.fill"
        case .ftp: return "arrow.up.arrow.down"
        case .sftp: return "terminal.fill"
        case .jellyfin: return "play.rectangle.fill"
        }
    }
}

struct NearbyRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let service: DiscoveredService
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.tint3)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.accentText)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(Typography.rowSemibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("Advertising \(service.kind.rawValue) on this network")
                        .font(Typography.rowSubtitle)
                        .foregroundColor(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TintPill(title: "Add") {
                    model.addDiscovered(service)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 64)
            if showsSeparator { RowSeparator().padding(.leading, 68) }
        }
    }
}

/// Slim card summarising the running transfer; tap for the full sheet.
struct ActiveTransfersCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfers: TransferQueue
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            ButtonHaptics.shared.tap()
            model.openSheet(.transfers)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(theme.accent)
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(transfers.runningItem?.name ?? "Waiting to start")
                        .font(Typography.rowSemibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let running = transfers.runningItem {
                        TransferProgressLine(item: running)
                    } else {
                        Text("\(transfers.activeCount) queued")
                            .font(Typography.meta)
                            .foregroundColor(Palette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .padding(12)
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.tintBorder.opacity(0.6), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle(opacity: 0.8))
    }
}

/// Observes one transfer item so only this line refreshes with progress.
struct TransferProgressLine: View {
    @ObservedObject var item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            ThinProgressBar(fraction: item.fraction)
            Text(label)
                .font(Typography.meta)
                .foregroundColor(Palette.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var label: String {
        var parts: [String] = []
        if item.fileCount > 0 {
            parts.append("\(item.filesDone) of \(item.fileCount)")
        }
        if item.total > 0 {
            parts.append("\(item.bytes.fileSizeString) of \(item.total.fileSizeString)")
        } else {
            parts.append(item.bytes.fileSizeString)
        }
        return parts.joined(separator: " · ")
    }
}
