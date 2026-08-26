//
//  SettingsSheet.swift
//  Packmule
//
//  Appearance, browsing preferences, safety, storage, about.
//

import SwiftUI
import UIKit

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        BottomSheet(maxHeightFraction: 0.88, onDismiss: { model.openSheet(nil) }) {
            SheetHeader(title: "Settings") { EmptyView() }
            HuggingScrollView {
                VStack(spacing: 0) {
                    SectionHeader(title: "Appearance")
                    Card {
                        ForEach(Array(ThemeName.allCases.enumerated()), id: \.element.id) { index, name in
                            ThemeRow(name: name, showsSeparator: index < ThemeName.allCases.count - 1)
                        }
                    }
                    Card {
                        SettingsRow(title: "Haptics", subtitle: "A little tap on every button",
                                    showsSeparator: false) {
                            MuleToggle(isOn: $model.settings.haptics)
                        }
                    }

                    SectionHeader(title: "Browsing")
                    Card {
                        SettingsRow(title: "Sort by") {
                            SegmentedPill(options: BrowseSort.allCases, label: { $0.rawValue },
                                          selection: $model.settings.sort)
                        }
                        SettingsRow(title: "Folders first") {
                            MuleToggle(isOn: $model.settings.foldersFirst)
                        }
                        SettingsRow(title: "Hidden files", subtitle: "Names starting with a dot",
                                    showsSeparator: false) {
                            MuleToggle(isOn: $model.settings.showHidden)
                        }
                    }

                    SectionHeader(title: "Safety")
                    Card {
                        SettingsRow(title: "Ask before deleting", showsSeparator: false) {
                            MuleToggle(isOn: $model.settings.confirmDelete)
                        }
                    }

                    SectionHeader(title: "Storage")
                    Card {
                        NavRow(title: "Downloads in the Files app",
                               subtitle: "On My iPhone · Packmule · Downloads",
                               showsSeparator: false) {
                            openInFiles()
                        }
                    }

                    SectionHeader(title: "About")
                    Card(bottomSpacing: 0) {
                        NavRow(title: "About Packmule",
                               subtitle: "Free means free · credits · privacy",
                               showsSeparator: false) {
                            model.openSheet(.about)
                        }
                    }
                }
            }
        }
    }

    private func openInFiles() {
        let path = LocalFiles.downloadsURL.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "shareddocuments://" + path) {
            UIApplication.shared.open(url)
        }
    }
}

struct ThemeRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let name: ThemeName
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                model.settings.theme = name
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(ThemeTokens.tokens(for: name).bg)
                        Circle().stroke(Palette.hairline12, lineWidth: 1)
                        Circle().fill(ThemeTokens.tokens(for: name).accent)
                            .frame(width: 12, height: 12)
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name.rawValue).font(Typography.row).foregroundColor(.white)
                        Text(name.tagline).font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.settings.theme == name {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(theme.accentText)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            if showsSeparator { RowSeparator().padding(.leading, 54) }
        }
    }
}
