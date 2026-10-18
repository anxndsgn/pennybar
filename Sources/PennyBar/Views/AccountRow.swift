import AppKit
import PennyBarCore
import SwiftUI

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let account: Account
    let isExpanded: Bool
    var now: Date?
    let toggle: () -> Void

    private var status: AccountStatus? { model.statuses[account.id] }
    private var snapshot: UsageSnapshot? { status?.snapshot }
    private var descriptor: ProviderDescriptor? { model.descriptor(for: account) }
    private var currentTime: Date { now ?? .now }
    private var budgetStatus: BudgetStatus { model.budgetStatus(for: account) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                summary
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse details" : "Show details")

            if isExpanded {
                details
                    .padding(.top, 12)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight(isActive: isExpanded)
        .contextMenu { contextMenu }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 10) {
            ProviderBadge(descriptor: descriptor)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CostText(money: snapshot?.total, kind: snapshot?.totalKind ?? .billed)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status?.issue != nil ? AnyShapeStyle(.secondary) : budgetStatus == .exceeded ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                // Overlaid so the spinner appearing during a refresh doesn't shift the amount.
                .overlay(alignment: .leading) {
                    if status?.isRefreshing == true {
                        ProgressView()
                            .controlSize(.mini)
                            .offset(x: -22)
                    }
                }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        let providerName = descriptor?.displayName ?? account.providerID
        if let issue = status?.issue {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        } else if let budget = account.budget, let total = snapshot?.total, budgetStatus != .normal {
            HStack(spacing: 3) {
                Image(systemName: budgetStatus == .exceeded ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(budgetStatus.color(normal: .secondary))
                Text("\(providerName) · \((total.amount / budget).formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current))) of \(Money(budget).formattedCompact) budget")
                    .foregroundStyle(budgetStatus == .exceeded ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        } else if let snapshot {
            Text("\(providerName) · \(snapshot.period.resetDescription(at: currentTime))")
                .foregroundStyle(.secondary)
        } else if status?.isRefreshing == true {
            Text("\(providerName) · Loading…")
                .foregroundStyle(.secondary)
        } else {
            Text(providerName)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = status?.issue {
                issueBox(issue)
            }
            if let snapshot {
                if let budget = account.budget, let total = snapshot.total {
                    BudgetBar(title: "Budget", spent: total, limit: budget, tint: descriptor?.tint ?? .accentColor)
                }
                if let limit = snapshot.limit, let total = snapshot.total, limit.amount > 0 {
                    BudgetBar(title: "\(descriptor?.displayName ?? "Provider") usage limit", spent: total, limit: limit.amount, tint: descriptor?.tint ?? .accentColor)
                }
                if let projected = snapshot.projectedTotal(at: currentTime), projected != snapshot.total {
                    HStack {
                        Text("On pace for")
                        Spacer()
                        Text("≈ \(projected.formatted) by \(snapshot.period.effectiveEnd.dayDescription)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                breakdown(snapshot)
                if !snapshot.notes.isEmpty {
                    Text(snapshot.notes.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
    }

    private func issueBox(_ issue: AccountIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue.detail)
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot {
                Text("Showing data from \(snapshot.fetchedAt.relativeDescription).")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func breakdown(_ snapshot: UsageSnapshot) -> some View {
        let items = snapshot.activeItems
        let largest = items.compactMap { $0.cost?.amount }.max() ?? 0
        let tint = descriptor?.tint ?? .accentColor
        if items.isEmpty {
            Text("No usage recorded yet this period.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.shortName)
                                .lineLimit(1)
                                .help(item.name)
                            Spacer(minLength: 4)
                            if let quantity = item.formattedQuantity {
                                Text(quantity)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            CostText(money: item.cost, kind: item.costKind)
                                .frame(minWidth: 58, alignment: .trailing)
                        }
                        .font(.caption)
                        if largest > 0, let cost = item.cost?.amount, cost > 0 {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(tint.opacity(0.55))
                                    .frame(width: max(geometry.size.width * NSDecimalNumber(decimal: cost / largest).doubleValue, 2))
                            }
                            .frame(height: 3)
                        }
                    }
                }
            }
            let hidden = snapshot.items.count - items.count
            if hidden > 0 {
                Text("\(hidden) more with no usage")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if let descriptor {
                Button {
                    openURL(descriptor.dashboardURL)
                } label: {
                    Label("Dashboard", systemImage: "arrow.up.right.square")
                }
            }
            Button {
                Task { await model.refresh(account) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(status?.isRefreshing == true)
            Spacer()
            if let snapshot {
                Text(snapshot.fetchedAt.relativeDescription)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Refresh") {
            Task { await model.refresh(account) }
        }
        if let descriptor {
            Button("Open \(descriptor.displayName) Dashboard") {
                openURL(descriptor.dashboardURL)
            }
        }
        if let total = snapshot?.total {
            Button("Copy Total") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(total.formatted, forType: .string)
            }
        }
        Divider()
        Button("Hide from Menu") {
            model.setEnabled(false, for: account)
        }
    }
}
