import AppKit
import PennyBarCore
import SwiftUI

@main
enum Main {
    static func main() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews") {
            let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "previews"
            MainActor.assumeIsolated { PreviewRenderer.render(to: URL(filePath: directory)) }
            return
        }
        #endif
        PennyBarApp.main()
    }
}

struct PennyBarApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keeps the app out of the Dock when run unbundled via `swift run`; the bundle sets LSUIElement.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let total = model.grandTotal.map { (model.totalIncludesEstimates ? "≈" : "") + $0.formattedCompact }
        let status = model.overallBudgetStatus
        // A budget alert always shows the icon, even in the total-only style.
        let showsIcon = model.menuBarStyle != .total || total == nil || status != .normal
        let showsTotal = model.menuBarStyle != .icon && total != nil
        HStack(spacing: 4) {
            if showsIcon {
                StatusIcon(status: status)
            }
            if showsTotal, let total {
                Text(total)
            }
        }
        .help(helpText(status))
    }

    private func helpText(_ status: BudgetStatus) -> String {
        switch status {
        case .normal: "PennyBar"
        case .warning: "PennyBar: a budget is above 80%"
        case .exceeded: "PennyBar: a budget has been exceeded"
        }
    }
}

/// The menu bar symbol: a template mark normally, a colored one for budget alerts.
/// Alerts are non-template images because the menu bar strips SwiftUI colors.
struct StatusIcon: View {
    let status: BudgetStatus

    private static let normal = MenuBarIcon.template()
    private static let warning = MenuBarIcon.colored(.dollar, color: MenuBarIcon.warningFill)
    private static let exceeded = MenuBarIcon.colored(.exclamation, color: .systemRed)

    var body: some View {
        switch status {
        case .normal: Image(nsImage: Self.normal)
        case .warning: Image(nsImage: Self.warning)
        case .exceeded: Image(nsImage: Self.exceeded)
        }
    }
}
