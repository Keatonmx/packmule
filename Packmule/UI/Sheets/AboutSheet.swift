//
//  AboutSheet.swift
//  Packmule
//
//  About · the free manifesto · privacy · open-source credits.
//

import SwiftUI
import UIKit

struct AboutSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        BottomSheet(maxHeightFraction: 0.86, onDismiss: { model.openSheet(.settings) }) {
            SheetHeader(title: "About", onBack: { model.openSheet(.settings) }) { EmptyView() }
            HuggingScrollView {
                VStack(spacing: 0) {
                    Card {
                        SettingsRow(title: "Packmule", subtitle: "by Redfern's Outpost") {
                            Text(AppInfo.versionString)
                                .font(Typography.detail)
                                .foregroundColor(Palette.text40)
                        }
                        link("Source code", url: AppInfo.sourceURL, showsSeparator: true)
                        link("Privacy policy", url: AppInfo.privacyURL, showsSeparator: false)
                    }

                    SectionHeader(title: "Free means free")
                    Card {
                        SettingsRow(title: "No Pro tier, ever",
                                    subtitle: "SMB, FTP, uploads, downloads: all of it, free. No subscription, no unlock. A file app should not ransom your own files back to you.",
                                    showsSeparator: false) { EmptyView() }
                    }

                    SectionHeader(title: "Privacy")
                    Card {
                        SettingsRow(title: "No accounts, ads or analytics",
                                    subtitle: "Files move between this phone and the servers you point it at, nowhere else. Passwords stay in the iOS Keychain on this phone.",
                                    showsSeparator: false) { EmptyView() }
                    }

                    SectionHeader(title: "VPN friendly")
                    Card {
                        SettingsRow(title: "Works over WireGuard",
                                    subtitle: "Turn the tunnel on and use the tunnel address, that's it. Packmule doesn't care how the packets get there.",
                                    showsSeparator: false) { EmptyView() }
                    }

                    SectionHeader(title: "Open source & credits")
                    Card(bottomSpacing: 0) {
                        credit(name: "AMSMB2", licence: "MIT",
                               note: "SMB2/3 client by Amir Abbas Mousavian.",
                               url: "https://github.com/amosavian/AMSMB2", showsSeparator: true)
                        credit(name: "libsmb2", licence: "LGPL-2.1",
                               note: "The SMB core underneath, by Ronnie Sahlberg and contributors.",
                               url: "https://github.com/sahlberg/libsmb2", showsSeparator: true)
                        credit(name: "FTP engine", licence: "This app",
                               note: "Written for Packmule on Apple's Network framework. That's why it's free.",
                               url: AppInfo.sourceURL, showsSeparator: false)
                    }
                }
            }
        }
    }

    private func link(_ title: String, url: String, showsSeparator: Bool) -> some View {
        NavRow(title: title, detail: url.replacingOccurrences(of: "https://", with: ""),
               showsSeparator: showsSeparator) {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        }
    }

    private func credit(name: String, licence: String, note: String, url: String, showsSeparator: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                if let u = URL(string: url) { UIApplication.shared.open(u) }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(Typography.row).foregroundColor(.white)
                        Text(note).font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(licence)
                        .font(Typography.meta)
                        .foregroundColor(theme.accentText)
                        .multilineTextAlignment(.trailing)
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

enum AppInfo {
    static let sourceURL = "https://github.com/Keatonmx/packmule"
    static let privacyURL = "https://github.com/Keatonmx/packmule/blob/main/PRIVACY.md"

    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}
