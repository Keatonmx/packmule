//
//  BrowserView.swift
//  Packmule
//
//  The file browser: compact header with the folder name and path, a card of
//  rows, search past a dozen entries, and a slim transfers bar when the mule
//  is hauling.
//

import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transfers: TransferQueue
    @Environment(\.theme) private var theme

    @FocusState private var searchFocused: Bool
    @State private var showingFilters = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if showingFilters {
                        filterChips
                    }
                    if model.entries.count > 12 || !model.searchText.isEmpty {
                        searchBar
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 80)
            }
            .scrollDismissesKeyboard(.interactively)

            if transfers.activeCount > 0 {
                transfersBar
            }
            if model.selecting {
                selectionBar
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(model.selectedPaths.isEmpty ? "Pick items" : "\(model.selectedPaths.count) picked")
                .font(Typography.detailSemibold)
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !(model.volume?.isLocal ?? true) {
                AccentPill(title: "Haul", compact: true) { model.downloadSelected() }
            }
            if !(model.volume?.isReadOnly ?? false) {
                DestructivePill(title: "Delete") { model.requestDeleteSelected() }
            }
            SecondaryPill(title: "Done") { model.endSelecting() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.sheet)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.tintBorder.opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: header

    private var title: String {
        model.path == "/" || model.path.isEmpty ? model.browserTitle : VolumePath.name(of: model.path)
    }

    private var subtitle: String {
        model.path == "/" || model.path.isEmpty ? model.browserKind : "\(model.browserKind) · \(model.path)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackCircleButton {
                model.goUp()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.sheetTitle)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.meta)
                    .foregroundColor(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CircleIconButton(action: { withAnimation(.easeInOut(duration: 0.2)) { showingFilters.toggle() } }) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(model.typeFilter != .all ? theme.accentText : Palette.text70)
            }

            if !(model.volume?.isReadOnly ?? false) {
                CircleIconButton(action: { model.showingImporter = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.text70)
                }
            }

            Menu {
                if !(model.volume?.isReadOnly ?? false) {
                    Button {
                        model.openSheet(.newFolder)
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                }
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    model.beginSelecting()
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Button {
                    model.openSheet(.goToPath)
                } label: {
                    Label("Go to path", systemImage: "arrow.right.to.line")
                }
                Picker("Sort", selection: $model.settings.sort) {
                    ForEach(BrowseSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Button {
                    model.openSheet(.transfers)
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    model.closeBrowser()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                ZStack {
                    Circle().fill(theme.chip)
                    Circle().stroke(Palette.hairline08, lineWidth: 0.5)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.text70)
                }
                .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Type chips plus the tidy name toggles, one scrollable row.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(FileTypeFilter.allCases) { filter in
                    let selected = model.typeFilter == filter
                    Button {
                        ButtonHaptics.shared.tap()
                        model.typeFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(Typography.chip)
                            .foregroundColor(selected ? .white : Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? theme.accent : theme.chip)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Rectangle().fill(Palette.separator).frame(width: 0.5, height: 18).padding(.horizontal, 4)

                tidyChip("Tidy ROMs", isOn: $model.settings.tidyROMNames)
                tidyChip("Tidy songs", isOn: $model.settings.tidySongNames)
            }
            .padding(.horizontal, 2)
        }
        .padding(.top, -6)
    }

    private func tidyChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            ButtonHaptics.shared.tap()
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(Typography.chip)
            }
            .foregroundColor(isOn.wrappedValue ? theme.accentText : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn.wrappedValue ? theme.tint : theme.chip)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isOn.wrappedValue ? theme.tintBorder : Palette.hairline08, lineWidth: isOn.wrappedValue ? 1 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Palette.text40)
            TextField("", text: $model.searchText,
                      prompt: Text("Search this folder").foregroundColor(Palette.textQuaternary))
                .font(.system(size: 15))
                .foregroundColor(.white)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Palette.text40)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(theme.chip)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.browserLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(theme.accentText)
                    .scaleEffect(1.2)
                Text("Fetching the list")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
        } else if let error = model.browserError {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Palette.text40)
                Text(error)
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                TintPill(title: "Try again") { model.refresh() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
            .padding(.horizontal, 16)
        } else if model.visibleEntries.isEmpty {
            VStack(spacing: 10) {
                RestingMule(height: 54)
                    .opacity(0.9)
                Text(!model.searchText.isEmpty ? "No files match"
                     : (model.typeFilter == .all ? "Nothing to haul here" : "Nothing of that type here"))
                    .font(Typography.cardTitle)
                    .foregroundColor(Palette.text55)
                if model.searchText.isEmpty, !(model.volume?.isReadOnly ?? false) {
                    Text("Tap + to send files here from this phone.")
                        .font(Typography.meta13)
                        .foregroundColor(Palette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            Card(bottomSpacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        FileRow(entry: entry, showsSeparator: index < model.visibleEntries.count - 1)
                    }
                }
            }
        }
    }

    private var transfersBar: some View {
        Button {
            ButtonHaptics.shared.tap()
            model.openSheet(.transfers)
        } label: {
            HStack(spacing: 10) {
                WalkingMule(height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfers.runningItem?.name ?? "Queued")
                        .font(Typography.detailSemibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let running = transfers.runningItem {
                        TransferProgressLine(item: running)
                    }
                }
                Spacer(minLength: 8)
                Text(transfers.activeCount == 1 ? "1 job" : "\(transfers.activeCount) jobs")
                    .font(Typography.chip)
                    .foregroundColor(theme.accentText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.sheet)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.tintBorder.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle(opacity: 0.8))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

// MARK: - Row

struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let entry: FileEntry
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                model.open(entry)
            } label: {
                HStack(spacing: 12) {
                    if model.selecting {
                        Image(systemName: model.selectedPaths.contains(entry.path)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(model.selectedPaths.contains(entry.path)
                                             ? theme.accent : Palette.text40)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(entry.isDirectory ? theme.tint : theme.well)
                        if entry.isDirectory {
                            GlyphIcon(map: GlyphSprites.sack, size: 24)
                        } else {
                            Image(systemName: FileGlyph.symbol(for: entry))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(FileGlyph.tint(for: entry) ?? Palette.text55)
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName ?? entry.name)
                            .font(Typography.row)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(meta)
                            .font(Typography.rowSubtitle)
                            .foregroundColor(Palette.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if entry.isDirectory {
                        RowChevron()
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .contextMenu {
                // The tidied row hides tags and extension; hold shows the truth.
                if displayName != nil {
                    Section(entry.name) { EmptyView() }
                }
                if !model.selecting {
                    if !entry.isDirectory {
                        if model.volume is JellyfinVolume || MediaFile.isStreamable(entry.name) {
                            Button { model.play(entry) } label: { Label("Play", systemImage: "play.fill") }
                        }
                        if !(model.volume?.isLocal ?? false) {
                            Button { model.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
                        }
                        Button { model.preview(entry) } label: { Label("Preview", systemImage: "eye") }
                        Button { model.share(entry) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    } else if !(model.volume?.isLocal ?? false) {
                        Button { model.download(entry) } label: { Label("Download folder", systemImage: "arrow.down.circle") }
                    }
                    Button { model.copyPath(entry) } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    if !(model.volume?.isReadOnly ?? false) {
                        Button { model.openSheet(.rename(entry)) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { model.requestDelete(entry) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            if showsSeparator { RowSeparator().padding(.leading, 60) }
        }
    }

    /// Tidied title when a setting is on and the file qualifies.
    private var displayName: String? {
        guard !entry.isDirectory else { return nil }
        if model.settings.tidyROMNames, let tidy = ROMNames.tidy(entry.name) { return tidy }
        if model.settings.tidySongNames, let tidy = SongNames.tidy(entry.name) { return tidy }
        return nil
    }

    /// When the title hides the extension, the meta line carries it instead.
    private var meta: String {
        guard displayName != nil else { return entry.metaLine }
        let ext = (entry.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? entry.metaLine : "\(ext) · \(entry.metaLine)"
    }
}
