//
//  FileActionsSheet.swift
//  Packmule
//
//  Tap a file: download, preview, share, rename, delete. Plus the two little
//  dialog sheets (confirm delete, text prompt) the browser leans on.
//

import SwiftUI

struct FileActionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let entry: FileEntry

    private var isRemote: Bool { !(model.volume?.isLocal ?? true) }

    /// Jellyfin plays everything (the server transcodes); elsewhere only what
    /// the Apple engine opens.
    private var canPlay: Bool {
        if model.volume is JellyfinVolume { return true }
        return MediaFile.isStreamable(entry.name)
    }

    private var playSubtitle: String? {
        if model.volume is JellyfinVolume { return "Streams now, the server converts if needed" }
        if isRemote { return "Streams without downloading" }
        return nil
    }

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(entry.isDirectory ? theme.tint : theme.well)
                    Image(systemName: FileGlyph.symbol(for: entry))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(entry.isDirectory ? theme.accentText : Palette.text70)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(Typography.rowSemibold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(entry.metaLine)
                        .font(Typography.rowSubtitle)
                        .foregroundColor(Palette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            Card(bottomSpacing: 0) {
                if entry.isDirectory {
                    NavRow(title: "Open") {
                        model.openSheet(nil)
                        model.open(entry)
                    }
                    if isRemote {
                        NavRow(title: "Download folder",
                               subtitle: "Everything inside, mirrored under Downloads",
                               showsChevron: false) {
                            model.download(entry)
                        }
                    }
                } else {
                    if canPlay {
                        NavRow(title: "Play", subtitle: playSubtitle, showsChevron: false) {
                            model.play(entry)
                        }
                    } else if MediaFile.needsEngine(entry.name) {
                        SettingsRow(title: "Can't play this container yet",
                                    subtitle: "MKV and friends play through a Jellyfin server today. The FFmpeg engine that plays them straight off the share is coming.") { EmptyView() }
                    }
                    if isRemote {
                        NavRow(title: "Download", subtitle: "To Downloads, visible in the Files app",
                               showsChevron: false) {
                            model.download(entry)
                        }
                    }
                    NavRow(title: "Preview", subtitle: isRemote ? "Fetches a copy first" : nil,
                           showsChevron: false) {
                        model.preview(entry)
                    }
                    NavRow(title: "Share", showsChevron: false) {
                        model.share(entry)
                    }
                }
                NavRow(title: "Copy path",
                       detail: entry.path,
                       showsChevron: false) {
                    model.copyPath(entry)
                }
                if model.volume?.isReadOnly ?? false {
                    SettingsRow(title: "Read only",
                                subtitle: "This library can be copied from, never changed from here",
                                showsSeparator: false) { EmptyView() }
                } else {
                    NavRow(title: "Rename", showsChevron: false) {
                        model.openSheet(.rename(entry))
                    }
                    NavRow(title: "Delete", titleColor: Palette.destructive,
                           showsSeparator: false, showsChevron: false) {
                        model.requestDelete(entry)
                    }
                }
            }
        }
    }
}

struct ConfirmDeleteManySheet: View {
    @EnvironmentObject private var model: AppModel
    let picked: [FileEntry]

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            VStack(spacing: 10) {
                Text("Delete \(picked.count) items?")
                    .font(Typography.dialogTitle)
                    .foregroundColor(.white)
                Text(picked.contains(where: \.isDirectory)
                     ? "Folders go with everything inside them. There is no undo."
                     : "They come off the server. There is no undo.")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    SecondaryPill(title: "Cancel") { model.openSheet(nil) }
                    DestructivePill(title: "Delete all") { model.performDeleteSelected(picked) }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

struct ConfirmDeleteSheet: View {
    @EnvironmentObject private var model: AppModel
    let entry: FileEntry

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            VStack(spacing: 10) {
                Text("Delete \(entry.name)?")
                    .font(Typography.dialogTitle)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text(entry.isDirectory
                     ? "The folder and everything in it comes off the server. There is no undo."
                     : "It comes off the server. There is no undo.")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    SecondaryPill(title: "Cancel") { model.openSheet(nil) }
                    DestructivePill(title: "Delete") { model.performDelete(entry) }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

/// Small one-field dialog used for Rename and New folder.
struct TextPromptSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    let initialText: String
    let submitLabel: String
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        BottomSheet(onDismiss: { model.openSheet(nil) }) {
            VStack(spacing: 12) {
                VStack(spacing: 3) {
                    Text(title)
                        .font(Typography.dialogTitle)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(Typography.meta)
                        .foregroundColor(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TextField("", text: $text,
                          prompt: Text("Name").foregroundColor(Palette.textQuaternary))
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { onSubmit(text) }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 10) {
                    SecondaryPill(title: "Cancel") { model.openSheet(nil) }
                    AccentPill(title: submitLabel) { onSubmit(text) }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                text = initialText
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
            }
        }
    }
}
