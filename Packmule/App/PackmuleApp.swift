//
//  PackmuleApp.swift
//  Packmule — a free file mule for SMB and FTP, by Redfern's Outpost.
//

import SwiftUI

@main
struct PackmuleApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.transfers)
                .environmentObject(model.discovery)
                .environmentObject(model.ftpServer)
                .environment(\.theme, model.theme)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            switch model.screen {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .browser:
                BrowserView()
                    .transition(.opacity)
            }

            sheetHost
                .zIndex(40)

            if let toast = model.toast {
                VStack {
                    Spacer()
                    ToastView(message: toast)
                        .padding(.bottom, 90)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(60)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.activeSheet)
        .sheet(isPresented: $model.showingImporter) {
            DocumentPicker(onPick: { model.handlePicked($0) },
                           onCancel: { model.showingImporter = false })
                .ignoresSafeArea()
        }
        .sheet(isPresented: $model.showingFolderPicker) {
            FolderPicker(onPick: { model.handlePickedFolder($0) },
                         onCancel: { model.showingFolderPicker = false })
                .ignoresSafeArea()
        }
        .sheet(item: quickLookBinding) { item in
            QuickLookPreview(url: item.url).ignoresSafeArea()
        }
        .sheet(item: shareBinding) { item in
            ShareSheet(items: [item.url]).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var sheetHost: some View {
        if let sheet = model.activeSheet {
            Group {
                switch sheet {
                case .addServer(let prefill, let isEdit):
                    AddServerSheet(prefill: prefill, isEdit: isEdit)
                case .serverActions(let server):
                    ServerActionsSheet(server: server)
                case .fileActions(let entry):
                    FileActionsSheet(entry: entry)
                case .confirmDelete(let entry):
                    ConfirmDeleteSheet(entry: entry)
                case .rename(let entry):
                    TextPromptSheet(title: "Rename", subtitle: entry.name,
                                    initialText: entry.name, submitLabel: "Rename") { name in
                        model.performRename(entry, to: name)
                    }
                case .newFolder:
                    TextPromptSheet(title: "New folder", subtitle: "In \(model.path)",
                                    initialText: "", submitLabel: "Create") { name in
                        model.performNewFolder(name)
                    }
                case .transfers:
                    TransfersSheet()
                case .settings:
                    SettingsSheet()
                case .about:
                    AboutSheet()
                case .host:
                    HostSheet()
                }
            }
        }
    }

    private var quickLookBinding: Binding<URLItem?> {
        Binding(get: { model.quickLookURL.map(URLItem.init) },
                set: { if $0 == nil { model.quickLookURL = nil } })
    }

    private var shareBinding: Binding<URLItem?> {
        Binding(get: { model.shareURL.map(URLItem.init) },
                set: { if $0 == nil { model.shareURL = nil } })
    }
}

private struct URLItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
