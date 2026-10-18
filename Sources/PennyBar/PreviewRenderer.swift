#if DEBUG
import AppKit
import PennyBarCore
import SwiftUI

/// Renders the main UI states to PNGs with sample data: `PennyBar --render-previews <dir>`.
/// Lets layout changes be reviewed without clicking through the menu bar.
@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date.now
        let model = AppModel.preview(now: now)
        let railway = model.accounts.first { $0.providerID == "railway" }?.id
        let failing = model.accounts.first { model.statuses[$0.id]?.issue != nil }?.id
        let empty = AppModel.preview(empty: true)
        // The saved accounts and last snapshots on this machine, without network or Keychain access.
        let saved = AppModel(tokens: InMemoryTokenStore(), autoRefresh: false)

        let states: [(String, AppModel, AnyView)] = [
            ("menu", model, AnyView(MenuView(now: now, scrollable: false))),
            ("menu-expanded", model, AnyView(MenuView(expandedID: railway, now: now, scrollable: false))),
            ("menu-error", model, AnyView(MenuView(expandedID: failing, now: now, scrollable: false))),
            ("menu-empty", empty, AnyView(MenuView(now: now, scrollable: false))),
            ("menu-saved", saved, AnyView(MenuView(expandedID: saved.accounts.first?.id, now: now, scrollable: false))),
            ("add-provider", model, AnyView(ProviderPicker(onPick: { _ in }, onCancel: {}))),
            ("add-editor", model, AnyView(AccountEditor(draft: AccountDraft(provider: model.registry.providers[0]), onBack: {}))),
        ]

        // ImageRenderer can't draw AppKit-backed views (scroll views, buttons, forms), so also host the
        // live menu in a real window and snapshot it, which matches what the menu bar extra shows.
        let windowStates: [(String, AppModel, UUID?)] = [
            ("window-menu", model, nil),
            ("window-menu-expanded", model, railway),
            ("window-menu-saved", saved, saved.accounts.first?.id),
        ]
        let windowViews: [(String, AnyView)] = windowStates.map { name, stateModel, expandedID in
            (name, AnyView(MenuView(expandedID: expandedID).environment(stateModel)))
        } + [
            ("window-settings", AnyView(SettingsView().environment(model))),
            ("window-settings-overview", AnyView(OverviewSettingsView(now: now).frame(width: 540, height: 640).environment(model))),
            ("window-settings-budgets", AnyView(BudgetsSettingsView().frame(width: 540, height: 500).environment(model))),
            ("window-settings-accounts", AnyView(AccountsSettingsView().frame(width: 540, height: 500).environment(model))),
            ("window-settings-accounts-empty", AnyView(AccountsSettingsView().frame(width: 540, height: 500).environment(empty))),
            ("window-settings-general", AnyView(GeneralSettingsView().frame(width: 540, height: 500).environment(model))),
            ("window-add-provider", AnyView(ProviderPicker(onPick: { _ in }, onCancel: {}).environment(model))),
            ("window-badge-large", AnyView(HStack(spacing: 24) {
                ProviderBadge(descriptor: model.registry.provider(id: "planetscale")?.descriptor, size: 120)
                // The official favicon, for comparison.
                Image(nsImage: NSImage(contentsOf: URL(filePath: "/private/tmp/claude-501/-Users-xinan-Developer-pennybar/d7b42aee-bb64-4dbc-a7f9-998a8008704c/scratchpad/pslogo/favicon.svg")) ?? NSImage())
                    .resizable().frame(width: 60, height: 60)
                ProviderBadge(descriptor: model.registry.provider(id: "planetscale")?.descriptor, size: 28)
            }.padding(20))),
            ("window-editor-planetscale", AnyView(AccountEditor(draft: AccountDraft(provider: model.registry.provider(id: "planetscale")!, token: "abc123:")).environment(model))),
            ("window-editor", AnyView(AccountEditor(draft: AccountDraft(provider: model.registry.provider(id: model.accounts[0].providerID)!, account: model.accounts[0])).environment(model))),
        ]
        for (name, rootView) in windowViews {
            let host = NSHostingView(rootView: rootView)
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.3))
            let size = host.fittingSize
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.3))
            print("\(name) fitting size: \(size)")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "\(name).png"))
            }
        }

        for (name, stateModel, view) in states {
            for scheme in [ColorScheme.light, .dark] {
                let content = view
                    .environment(stateModel)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else {
                    print("Failed to render \(name)")
                    continue
                }
                let url = directory.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}

#Preview("Menu") {
    MenuView().environment(AppModel.preview())
}

#Preview("Menu – empty") {
    MenuView().environment(AppModel.preview(empty: true))
}

#Preview("Settings") {
    SettingsView().environment(AppModel.preview())
}
#endif
