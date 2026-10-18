import AppKit
import PennyBarCore
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// One expanded row at a time keeps the popover from growing past the screen.
    @State private var expandedID: UUID?
    private let now: Date?
    private let scrollable: Bool
    private let maxListHeight: CGFloat = 520

    /// `now` pins the clock for rendered previews; the live menu uses the current time.
    /// `scrollable: false` lays rows out flat, for offscreen rendering where scroll views draw empty.
    init(expandedID: UUID? = nil, now: Date? = nil, scrollable: Bool = true) {
        _expandedID = State(initialValue: expandedID)
        self.now = now
        self.scrollable = scrollable
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.accounts.isEmpty {
                emptyState
            } else {
                header
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 12)
                accountList
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .environment(\.locale, AppLocale.current)
    }

    // MARK: Header

    private var header: some View {
        let currentTime = now ?? .now
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Spend this period")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.grandTotal?.formatted ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: model.isRefreshing)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(model.isRefreshing)
                .help("Refresh all accounts")
                .keyboardShortcut("r")
            }

            if segments.count > 1 {
                ShareBar(segments: segments)
            }

            if let budget = model.totalBudget {
                BudgetBar(title: "Total budget", spent: model.grandTotal ?? Money(0), limit: budget, tint: .accentColor)
            }

            HStack(spacing: 4) {
                if let projected = model.projectedTotal(at: currentTime), projected != model.grandTotal {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("On pace for ≈ \(projected.formattedCompact)")
                }
                Spacer()
                if model.totalIncludesEstimates {
                    Text("≈ includes estimates")
                        .help("Neon and Railway's breakdown are computed from published prices.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Each account's share of the total; repeat accounts of one provider get lighter shades.
    private var segments: [ShareBar.Segment] {
        var seen: [String: Int] = [:]
        return model.enabledAccounts.compactMap { account in
            guard let total = model.statuses[account.id]?.snapshot?.total, total.amount > 0 else { return nil }
            let index = seen[account.providerID, default: 0]
            seen[account.providerID] = index + 1
            let tint = model.descriptor(for: account)?.tint ?? .secondary
            return ShareBar.Segment(
                id: account.id,
                value: NSDecimalNumber(decimal: total.amount).doubleValue,
                color: tint.opacity([1, 0.6, 0.35][index % 3])
            )
        }
    }

    // MARK: Accounts

    private var accountList: some View {
        let rows = VStack(spacing: 2) {
            ForEach(model.enabledAccounts) { account in
                AccountRow(account: account, isExpanded: expandedID == account.id, now: now) {
                    // No animation: the menu window resizes outside SwiftUI's animation, so an
                    // animated height change makes rows jump while the window catches up.
                    expandedID = expandedID == account.id ? nil : account.id
                }
            }
            if model.enabledAccounts.isEmpty {
                Text("All accounts are hidden. Turn them back on in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)

        // The menu window sizes itself to its content, which gives the ScrollView no height to
        // fill. fixedSize makes it report its content's height, capped by maxHeight, in the same
        // layout pass, so the window and rows resize together.
        return Group {
            if scrollable {
                ScrollView {
                    rows
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                rows
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(model.registry.providers, id: \.descriptor.id) { provider in
                    ProviderBadge(descriptor: provider.descriptor, size: 34)
                }
            }
            VStack(spacing: 4) {
                Text("Track your cloud spend")
                    .font(.headline)
                Text("Connect \(model.registry.displayNames) to see this period's usage and cost at a glance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add Account…", action: showSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(at: now ?? context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .keyboardShortcut(",")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit PennyBar")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func updatedText(at date: Date) -> String {
        if model.isRefreshing { return "Refreshing…" }
        guard let lastRefresh = model.lastRefresh else { return "" }
        if date.timeIntervalSince(lastRefresh) < 60 { return "Updated just now" }
        return "Updated \(lastRefresh.relativeDescription)"
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
