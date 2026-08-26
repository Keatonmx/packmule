//
//  AddServerSheet.swift
//  Packmule
//
//  Add or edit a server. Pasting a full address into Host works, including
//  Windows style: "\\10.0.0.253\media" fills the host and the share.
//

import SwiftUI

struct AddServerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let prefill: SavedServer?
    let isEdit: Bool

    @State private var kind: ServerKind
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var share: String
    @State private var startPath: String
    @State private var username: String
    @State private var password = ""
    @State private var passwordTouched = false

    init(prefill: SavedServer?, isEdit: Bool) {
        self.prefill = prefill
        self.isEdit = isEdit
        let s = prefill ?? SavedServer()
        _kind = State(initialValue: s.kind)
        _name = State(initialValue: s.name)
        _host = State(initialValue: s.host)
        _port = State(initialValue: s.port.map(String.init) ?? "")
        _share = State(initialValue: s.share)
        _startPath = State(initialValue: s.startPath == "/" ? "" : s.startPath)
        _username = State(initialValue: s.username)
    }

    var body: some View {
        BottomSheet(maxHeightFraction: 0.92, onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: isEdit ? "Edit server" : "Add server") {
                SegmentedPill(options: ServerKind.allCases, label: { $0.rawValue }, selection: $kind)
            }
            HuggingScrollView {
                VStack(spacing: 14) {
                    LabeledField(label: "Name", placeholder: "Home media", text: $name, autocapitalize: true)

                    HStack(alignment: .bottom, spacing: 10) {
                        LabeledField(label: "Host", placeholder: "10.0.0.253 or mynas.local",
                                     text: $host, keyboard: .URL)
                        LabeledField(label: "Port", placeholder: "\(kind.defaultPort)",
                                     text: $port, keyboard: .numberPad)
                            .frame(width: 92)
                    }

                    if kind == .smb {
                        LabeledField(label: "Share", placeholder: "media, or empty to browse shares",
                                     text: $share, keyboard: .URL)
                    } else {
                        LabeledField(label: "Start in", placeholder: "/", text: $startPath, keyboard: .URL)
                    }

                    LabeledField(label: "User", placeholder: userPlaceholder,
                                 text: $username, keyboard: .emailAddress)
                    LabeledField(label: "Password",
                                 placeholder: isEdit ? "Unchanged" : "Optional",
                                 text: $password, secure: true)
                        .onChange(of: password) { _ in passwordTouched = true }

                    Text("Any address this phone can reach works: home network, or a VPN tunnel like WireGuard. If the packets get there, the mule can too.")
                        .font(Typography.meta13)
                        .foregroundColor(Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    HStack(spacing: 10) {
                        if isEdit, let existing = prefill {
                            DestructivePill(title: "Forget") {
                                model.forget(existing)
                                model.openSheet(nil)
                            }
                        }
                        Spacer()
                        SecondaryPill(title: "Save") {
                            if let server = buildServer() {
                                model.save(server, password: passwordValue)
                                model.openSheet(nil)
                                model.showToast("Saved \(server.displayName)")
                            }
                        }
                        AccentPill(title: isEdit ? "Save & Connect" : "Connect") {
                            if let server = buildServer() {
                                model.save(server, password: passwordValue)
                                model.openSheet(nil)
                                model.connect(server)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var userPlaceholder: String {
        switch kind {
        case .smb: return "guest"
        case .ftp: return "anonymous"
        case .sftp: return "pi, keaton, root…"
        }
    }

    /// New servers always write the password (empty clears); edits keep the
    /// stored one unless the field was touched.
    private var passwordValue: String? {
        if isEdit, !passwordTouched { return nil }
        return password
    }

    private func buildServer() -> SavedServer? {
        var server = prefill ?? SavedServer()
        server.kind = kind
        server.name = name.trimmingCharacters(in: .whitespaces)
        server.share = share.trimmingCharacters(in: .whitespaces)

        // Host: accept bare hosts, smb:// and ftp:// URLs, or \\host\share pastes.
        var rawHost = host.trimmingCharacters(in: .whitespaces)
        guard !rawHost.isEmpty else {
            model.showToast("A host is required")
            return nil
        }
        if let schemeRange = rawHost.range(of: "://") {
            rawHost = String(rawHost[schemeRange.upperBound...])
        }
        rawHost = rawHost.replacingOccurrences(of: "\\", with: "/")
        while rawHost.hasPrefix("/") { rawHost.removeFirst() }
        var pathParts = rawHost.split(separator: "/").map(String.init)
        guard !pathParts.isEmpty else {
            model.showToast("A host is required")
            return nil
        }
        var hostPart = pathParts.removeFirst()
        if let colon = hostPart.firstIndex(of: ":"), port.isEmpty {
            port = String(hostPart[hostPart.index(after: colon)...])
            hostPart = String(hostPart[..<colon])
        }
        server.host = hostPart
        if kind == .smb, server.share.isEmpty, let first = pathParts.first {
            server.share = first
        }

        if let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value),
           value != kind.defaultPort {
            server.port = value
        } else {
            server.port = nil
        }

        let start = startPath.trimmingCharacters(in: .whitespaces)
        server.startPath = start.isEmpty ? "/" : (start.hasPrefix("/") ? start : "/" + start)
        server.username = username.trimmingCharacters(in: .whitespaces)
        if kind == .sftp, server.username.isEmpty {
            model.showToast("SFTP needs a user name")
            return nil
        }
        return server
    }
}
