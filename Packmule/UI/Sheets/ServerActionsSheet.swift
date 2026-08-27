//
//  ServerActionsSheet.swift
//  Packmule
//
//  The ellipsis menu for a saved server: connect, edit, copy, forget.
//

import SwiftUI
import UIKit

struct ServerActionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let server: SavedServer

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: server.displayName) {
                Text(server.kind.rawValue)
                    .font(Typography.chip)
                    .foregroundColor(theme.accentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.tint)
                    .clipShape(Capsule())
            }
            Text(server.addressLine)
                .font(Typography.mono12)
                .foregroundColor(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            Card(bottomSpacing: 0) {
                NavRow(title: "Connect", showsChevron: false) {
                    model.openSheet(nil)
                    model.connect(server)
                }
                NavRow(title: "Edit", subtitle: "Address, share, password") {
                    model.openSheet(.addServer(server, isEdit: true))
                }
                NavRow(title: "Copy address", detail: server.addressLine, showsChevron: false) {
                    UIPasteboard.general.string = server.addressLine
                    model.showToast("Copied")
                }
                NavRow(title: "Connection details", subtitle: "Reachability, timing, server banner") {
                    model.openSheet(.connectionDetails(server))
                }
                NavRow(title: "Forget", titleColor: Palette.destructive,
                       showsSeparator: false, showsChevron: false) {
                    model.forget(server)
                    model.openSheet(nil)
                }
            }
        }
    }
}

/// What actually answers at that address: alive or not, how fast, and the
/// first thing it says (FTP greetings, SSH idents; SMB is the strong silent type).
struct ConnectionDetailsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let server: SavedServer

    @State private var probing = true
    @State private var result: Probe.Result?

    private var port: Int { server.port ?? server.kind.defaultPort }

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(.serverActions(server)) }) {
            SheetHeader(title: "Connection details",
                        onBack: { model.openSheet(.serverActions(server)) }) { EmptyView() }
            Card(bottomSpacing: 0) {
                SettingsRow(title: "Address") {
                    Text("\(server.host):\(port)")
                        .font(Typography.mono12)
                        .foregroundColor(Palette.text55)
                }
                SettingsRow(title: "Protocol") {
                    Text(server.kind.rawValue)
                        .font(Typography.detail)
                        .foregroundColor(Palette.text55)
                }
                SettingsRow(title: "Reachable", subtitle: reachSubtitle) {
                    if probing {
                        ProgressView().tint(theme.accentText)
                    } else if let rtt = result?.rttMillis {
                        Text("\(rtt) ms")
                            .font(Typography.mono12)
                            .foregroundColor(theme.accentText)
                    } else {
                        Text("No")
                            .font(Typography.detailSemibold)
                            .foregroundColor(Palette.destructive)
                    }
                }
                SettingsRow(title: "Server says",
                            subtitle: bannerText,
                            showsSeparator: false) { EmptyView() }
            }
        }
        .onAppear { runProbe() }
    }

    private var reachSubtitle: String {
        if probing { return "Knocking on \(server.host)" }
        if result?.rttMillis != nil { return "TCP answered on port \(port)" }
        return "Nothing answered. Server asleep, or the VPN is off"
    }

    private var bannerText: String {
        if probing { return "Listening…" }
        if let banner = result?.banner, !banner.isEmpty { return banner }
        return server.kind == .smb ? "SMB servers don't announce themselves, silence is normal"
                                   : "No greeting before sign in"
    }

    private func runProbe() {
        probing = true
        let host = server.host
        let port = self.port
        let wantsBanner = server.kind == .ftp || server.kind == .sftp
        Task {
            let outcome = await Probe.tcp(host: host, port: port, readBanner: wantsBanner)
            result = outcome
            probing = false
            model.reachable[server.id] = outcome.rttMillis != nil
        }
    }
}
