//
//  HostSheet.swift
//  Packmule
//
//  Host this iPhone: start an FTP server on the phone so other devices can
//  browse the Packmule folder. Shows the addresses to dial while running.
//

import SwiftUI
import UIKit

struct HostSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var server: FTPServer
    @Environment(\.theme) private var theme

    @State private var username = ""
    @State private var password = ""
    @State private var port = ""

    var body: some View {
        BottomSheet(maxHeightFraction: 0.9, onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: "Host this iPhone") {
                if server.running {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0x58CC52)).frame(width: 8, height: 8)
                        Text("SERVING")
                            .font(Typography.badge)
                            .tracking(1)
                            .foregroundColor(theme.accentText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.tint)
                    .clipShape(Capsule())
                }
            }
            HuggingScrollView {
                VStack(spacing: 14) {
                    if server.running {
                        Card(bottomSpacing: 0) {
                            ForEach(Array(addressLines.enumerated()), id: \.offset) { index, line in
                                NavRow(title: line.address,
                                       subtitle: "Over \(line.label). Tap to copy",
                                       showsSeparator: index < addressLines.count - 1,
                                       showsChevron: false) {
                                    UIPasteboard.general.string = line.address
                                    model.showToast("Copied")
                                }
                            }
                            if addressLines.isEmpty {
                                SettingsRow(title: "No network address found",
                                            subtitle: "Join WiFi or turn the VPN on, then start again",
                                            showsSeparator: false) { EmptyView() }
                            }
                        }
                        Text("Open the address in Windows Explorer, another Packmule, or any FTP client. \(server.connectionCount) connected now.")
                            .font(Typography.meta13)
                            .foregroundColor(Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .bottom, spacing: 10) {
                            LabeledField(label: "User", placeholder: "Empty means anyone may connect", text: $username)
                            LabeledField(label: "Port", placeholder: "2121", text: $port, keyboard: .numberPad)
                                .frame(width: 92)
                        }
                        LabeledField(label: "Password", placeholder: "Optional", text: $password, secure: true)
                        Text("Serves the Packmule folder (the one in the Files app) and your linked folders to your network. Anyone with the address\(usernameHint) can browse them, so home networks and VPNs only. iOS pauses servers in the background: keep Packmule open while hosting.")
                            .font(Typography.meta13)
                            .foregroundColor(Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        if server.running {
                            DestructivePill(title: "Stop serving") {
                                server.stop()
                                model.showToast("Server stopped")
                            }
                        } else {
                            AccentPill(title: "Start serving") {
                                var config = server.config
                                config.username = username.trimmingCharacters(in: .whitespaces)
                                config.password = password
                                config.port = Int(port) ?? 2121
                                server.config = config
                                server.start()
                                if server.running {
                                    model.showToast("Serving on port \(server.config.port)")
                                }
                            }
                        }
                    }

                    if let error = server.lastError {
                        Text(error)
                            .font(Typography.meta13)
                            .foregroundColor(Palette.destructive.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            username = server.config.username
            password = server.config.password
            port = server.config.port == 2121 ? "" : String(server.config.port)
        }
    }

    private var usernameHint: String {
        server.config.username.isEmpty ? "" : " and password"
    }

    private var addressLines: [(label: String, address: String)] {
        FTPServer.deviceAddresses().map { entry in
            (entry.label, "ftp://\(entry.ip):\(server.config.port)")
        }
    }
}
