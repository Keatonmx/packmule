//
//  TransfersSheet.swift
//  Packmule
//
//  Everything the mule is hauling, has hauled, or dropped.
//

import SwiftUI

struct TransfersSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfers: TransferQueue
    @Environment(\.theme) private var theme

    private var hasFinished: Bool {
        transfers.items.contains { item in
            switch item.status {
            case .done, .cancelled, .failed: return true
            case .queued, .running: return false
            }
        }
    }

    var body: some View {
        BottomSheet(maxHeightFraction: 0.84, onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: "Transfers") {
                if hasFinished {
                    SecondaryPill(title: "Clear") { transfers.clearFinished() }
                }
            }
            if transfers.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(Palette.text40)
                    Text("Nothing moving")
                        .font(Typography.cardTitle)
                        .foregroundColor(Palette.text55)
                    Text("Downloads land in Downloads, visible in the Files app under On My iPhone · Packmule.")
                        .font(Typography.meta13)
                        .foregroundColor(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                HuggingScrollView {
                    Card(bottomSpacing: 0) {
                        ForEach(Array(transfers.items.enumerated()), id: \.element.id) { index, item in
                            TransferRow(item: item, showsSeparator: index < transfers.items.count - 1)
                        }
                    }
                }
            }
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfers: TransferQueue
    @Environment(\.theme) private var theme
    @ObservedObject var item: TransferItem
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(iconBackground)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(Typography.detailSemibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.status == .running {
                        TransferProgressLine(item: item)
                    } else {
                        Text(statusLine)
                            .font(Typography.rowSubtitle)
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingControl
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            if showsSeparator { RowSeparator().padding(.leading, 58) }
        }
    }

    private var iconName: String {
        switch item.status {
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        default: return item.direction == .download ? "arrow.down" : "arrow.up"
        }
    }

    private var iconBackground: Color {
        switch item.status {
        case .done: return theme.tint2
        case .failed: return Palette.destructive.opacity(0.2)
        default: return theme.tint
        }
    }

    private var iconColor: Color {
        if case .failed = item.status { return Palette.destructive }
        return theme.accentText
    }

    private var statusLine: String {
        switch item.status {
        case .queued: return "Queued · \(item.detail)"
        case .running: return item.detail
        case .done: return item.direction == .download ? "Done · from \(item.detail)" : "Done · to \(item.detail)"
        case .failed(let why): return why
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        if case .failed = item.status { return Palette.destructive.opacity(0.9) }
        return Palette.textTertiary
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch item.status {
        case .queued, .running:
            Button {
                ButtonHaptics.shared.tap()
                transfers.cancel(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Palette.text40)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FadePressStyle())
        case .done:
            if item.direction == .download, item.purpose == .keep, let url = item.destination {
                Button {
                    ButtonHaptics.shared.tap()
                    model.shareURL = url
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.text55)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FadePressStyle())
            }
        case .failed, .cancelled:
            EmptyView()
        }
    }
}
