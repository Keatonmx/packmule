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
    @State private var rememberPassword: Bool

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
        _rememberPassword = State(initialValue: !(s.rememberPassword == false))
    }

    private var passwordPlaceholder: String {
        if !rememberPassword { return "Asked when you connect" }
        return isEdit ? "Unchanged" : "Optional"
    }

    var body: some View {
        BottomSheet(maxHeightFraction: 0.92, onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: isEdit ? "Edit server" : "Add server") { EmptyView() }
            HuggingScrollView {
                VStack(spacing: 14) {
                    SegmentedPill(options: ServerKind.allCases, label: { $0.rawValue },
                                  selection: $kind, fontSize: 12, horizontalPadding: 10)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                    } else if kind == .ftp || kind == .sftp {
                        LabeledField(label: "Start in", placeholder: "/", text: $startPath, keyboard: .URL)
                    }

                    LabeledField(label: "User", placeholder: userPlaceholder,
                                 text: $username, keyboard: .emailAddress)
                    LabeledField(label: "Password",
                                 placeholder: passwordPlaceholder,
                                 text: $password, secure: true)
                        .onChange(of: password) { _ in passwordTouched = true }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember password")
                                .font(Typography.row)
                                .foregroundColor(.white)
                            Text(rememberPassword
                                 ? "Kept in the iOS Keychain on this phone"
                                 : "Packmule asks each time and keeps nothing")
                                .font(Typography.rowSubtitle)
                                .foregroundColor(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        MuleToggle(isOn: $rememberPassword)
                    }
                    .padding(.top, 2)

                    Text(kind == .jellyfin
                         ? "Sign in with your Jellyfin account, the same one the web app uses. Formats this phone can't play are converted by the server, so MKV works here. Paste an https address if yours sits behind a reverse proxy."
                         : "Any address this phone can reach works: home network, or a VPN tunnel like WireGuard. If the packets get there, the mule can too.")
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
                                if !rememberPassword, !password.isEmpty {
                                    model.connect(server, oneTimePassword: password)
                                } else {
                                    model.connect(server)
                                }
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
        case .jellyfin: return "your Jellyfin user"
        }
    }

    /// New servers always write the password (empty clears); edits keep the
    /// stored one unless the field was touched. Remember off always clears.
    private var passwordValue: String? {
        if !rememberPassword { return "" }
        if isEdit, !passwordTouched { return nil }
        return password
    }

    private func buildServer() -> SavedServer? {
        var server = prefill ?? SavedServer()
        server.kind = kind
        server.rememberPassword = rememberPassword ? nil : false
        server.name = name.trimmingCharacters(in: .whitespaces)
        server.share = share.trimmingCharacters(in: .whitespaces)

        // Host: accept bare hosts, smb:// and ftp:// URLs, or \\host\share pastes.
        var rawHost = host.trimmingCharacters(in: .whitespaces)
        guard !rawHost.isEmpty else {
            model.showToast("A host is required")
            return nil
        }
        if rawHost.lowercased().hasPrefix("https://") {
            server.https = true
        } else if rawHost.lowercased().hasPrefix("http://") {
            server.https = false
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
        if kind == .jellyfin, server.username.isEmpty {
            model.showToast("Jellyfin needs your user name")
            return nil
        }
        return server
    }
}

/// Asked when a server is set to not remember its password.
struct PasswordPromptSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let server: SavedServer

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            VStack(spacing: 12) {
                VStack(spacing: 3) {
                    Text("Password for \(server.displayName)")
                        .font(Typography.dialogTitle)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Used once, kept nowhere")
                        .font(Typography.meta)
                        .foregroundColor(Palette.textTertiary)
                }
                SecureField("", text: $password,
                            prompt: Text("Password").foregroundColor(Palette.textQuaternary))
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { model.connect(server, oneTimePassword: password) }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 10) {
                    SecondaryPill(title: "Cancel") { model.openSheet(nil) }
                    AccentPill(title: "Connect") {
                        model.connect(server, oneTimePassword: password)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
            }
        }
    }
}
