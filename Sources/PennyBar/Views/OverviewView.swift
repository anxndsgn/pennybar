import PennyBarCore
import SwiftUI

/// Settings landing page: this period's spend, what needs attention, and every account at a glance.
struct OverviewSettingsView: View {
    @Environment(AppModel.self) private var model
    var now: Date?
    @State private var sheet: AccountSheet?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Connect \(model.registry.displayNames) to see this period's spend here.")
                } actions: {
                    Button("Add Account…") { sheet = .add }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summary
                        attention
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Accounts")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(model.accounts) { account in
                                    OverviewAccountCard(account: account, now: now) { edit(account) }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddAccountFlow()
            case .edit(let draft): AccountEditor(draft: draft)
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let currentTime = now ?? .now
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spend this period")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.grandTotal?.formatted ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: model.isRefreshing)
                    }
                    .controlSize(.small)
                    .disabled(model.isRefreshing)
                    .keyboardShortcut("r")
                    Text("Updated \(model.lastRefresh?.relativeDescription ?? "never")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if segments.count > 1 {
                ShareBar(segments: segments, height: 8)
            }

            if let budget = model.totalBudget {
                BudgetBar(title: "Total budget", spent: model.grandTotal ?? Money(0), limit: budget, tint: .accentColor)
            }

            HStack(spacing: 4) {
                if let projected = model.projectedTotal(at: currentTime), projected != model.grandTotal {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("On pace for ≈ \(projected.formatted) by period end")
                }
                Spacer()
                if model.totalIncludesEstimates {
                    Text("≈ includes estimates")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .cardBackground()
    }

    /// Each shown account's share of the total; repeat accounts of one provider get lighter shades.
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

    // MARK: Attention

    private struct Alert: Identifiable {
        let account: Account
        let symbol: String
        let color: Color
        let message: String
        var id: UUID { account.id }
    }

    private var alerts: [Alert] {
        model.accounts.compactMap { account in
            if let issue = model.statuses[account.id]?.issue {
                return Alert(account: account, symbol: "exclamationmark.triangle.fill", color: .orange, message: issue.title)
            }
            switch model.budgetStatus(for: account) {
            case .exceeded:
                return Alert(account: account, symbol: "exclamationmark.circle.fill", color: .red, message: String(localized: "Over budget"))
            case .warning:
                return Alert(account: account, symbol: "exclamationmark.triangle.fill", color: BudgetStatus.warning.color(normal: .secondary), message: String(localized: "Near budget"))
            case .normal:
                return nil
            }
        }
    }

    @ViewBuilder
    private var attention: some View {
        let alerts = alerts
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Needs Attention")
                VStack(spacing: 0) {
                    ForEach(alerts) { alert in
                        if alert.id != alerts.first?.id {
                            Divider().padding(.leading, 46)
                        }
                        HStack(spacing: 10) {
                            ProviderBadge(descriptor: model.descriptor(for: alert.account), size: 24)
                            Text(alert.account.name)
                            Spacer()
                            Label(alert.message, systemImage: alert.symbol)
                                .font(.callout)
                                .foregroundStyle(alert.color)
                            Button("Edit…") { edit(alert.account) }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .cardBackground()
            }
        }
    }

    private func edit(_ account: Account) {
        guard let provider = model.provider(for: account) else { return }
        sheet = .edit(AccountDraft(provider: provider, account: account, token: model.token(for: account)))
    }
}

// MARK: - Account card

private struct OverviewAccountCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var now: Date?
    let onEdit: () -> Void
    @State private var isHovering = false

    var body: some View {
        let descriptor = model.descriptor(for: account)
        let status = model.statuses[account.id]
        let snapshot = status?.snapshot
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProviderBadge(descriptor: descriptor, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(descriptor?.displayName ?? account.providerID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !account.isEnabled {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.tertiary)
                            .help("Hidden from the menu")
                    }
                }

                if let issue = status?.issue {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxHeight: .infinity, alignment: .bottomLeading)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        CostText(money: snapshot?.total, kind: snapshot?.totalKind ?? .billed)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        if let snapshot {
                            Text(daysLeft(snapshot))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let budget = account.budget, let spent = snapshot?.total {
                        BudgetProgress(
                            fraction: BudgetBar.fraction(spent: spent, limit: budget),
                            color: model.budgetStatus(for: account).color(normal: descriptor?.tint ?? .accentColor)
                        )
                        .help("\(spent.formatted) of \(Money(budget, currency: spent.currency).formatted)")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .opacity(account.isEnabled ? 1 : 0.6)
            .cardBackground(highlighted: isHovering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func daysLeft(_ snapshot: UsageSnapshot) -> String {
        let end = snapshot.period.effectiveEnd
        let days = Calendar.current.dateComponents([.day], from: now ?? .now, to: end).day ?? 0
        return days <= 0 ? String(localized: "Ends today") : String(localized: "\(days) days left")
    }
}

// MARK: - Helpers

private struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.leading, 4)
    }
}

extension View {
    /// The soft rounded fill grouped settings use, so custom cards sit naturally next to forms.
    func cardBackground(highlighted: Bool = false) -> some View {
        background(
            Color.primary.opacity(highlighted ? 0.07 : 0.04),
            in: .rect(cornerRadius: 12, style: .continuous)
        )
    }
}
