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
                NavRow(title: "Edit", subtitle: "Address, share, sign-in") {
                    model.openSheet(.addServer(server, isEdit: true))
                }
                NavRow(title: "Copy address", detail: server.addressLine, showsChevron: false) {
                    UIPasteboard.general.string = server.addressLine
                    model.showToast("Copied")
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
