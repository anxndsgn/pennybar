import PennyBarCore
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, accounts, budgets, general

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .accounts: "Accounts"
        case .budgets: "Budgets"
        case .general: "General"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .accounts: "creditcard"
        case .budgets: "gauge.with.dots.needle.67percent"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage? = .overview

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbolName)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let page = page ?? .overview
            Group {
                switch page {
                case .overview: OverviewSettingsView()
                case .accounts: AccountsSettingsView()
                case .budgets: BudgetsSettingsView()
                case .general: GeneralSettingsView()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(width: 720, height: 500)
        .environment(\.locale, AppLocale.current)
    }
}

// MARK: - Accounts

enum AccountSheet: Identifiable {
    case add
    case edit(AccountDraft)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let draft): draft.id.uuidString
        }
    }
}

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: AccountSheet?
    @State private var pendingDeletion: Account?

    var body: some View {
        Group {
            if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "creditcard")
                } description: {
                    Text("Connect \(model.registry.displayNames) to track spend.")
                } actions: {
                    Button("Add Account…") { sheet = .add }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Form {
                    Section {
                        ForEach(model.accounts) { account in
                            AccountSettingsRow(account: account) { edit(account) }
                                .contextMenu { menu(for: account) }
                        }
                        .onMove(perform: model.move)
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Shown in the menu in this order")
                            Spacer()
                            Button {
                                sheet = .add
                            } label: {
                                Label("Add Account…", systemImage: "plus")
                            }
                            .controlSize(.small)
                            .help("Add account (⌘N)")
                        }
                    } footer: {
                        Text("Each account is one token plus one billing scope. Drag to reorder, click to edit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        // Reachable from the empty state too, so it isn't tied to the header button.
        .background {
            Button("") { sheet = .add }
                .keyboardShortcut("n")
                .hidden()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: AddAccountFlow()
            case .edit(let draft): AccountEditor(draft: draft)
            }
        }
        .confirmationDialog(
            "Remove \(pendingDeletion?.name ?? "account")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { account in
            Button("Remove", role: .destructive) { model.delete(account) }
        } message: { _ in
            Text("Its token is deleted from the Keychain. This doesn't revoke the token on the provider.")
        }
    }

    @ViewBuilder
    private func menu(for account: Account) -> some View {
        Button("Edit…") { edit(account) }
        Button(account.isEnabled ? "Hide from Menu" : "Show in Menu") {
            model.setEnabled(!account.isEnabled, for: account)
        }
        if let index = model.accounts.firstIndex(where: { $0.id == account.id }) {
            Divider()
            Button("Move Up") { model.move(from: [index], to: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { model.move(from: [index], to: index + 2) }
                .disabled(index == model.accounts.count - 1)
        }
        Divider()
        Button("Remove…", role: .destructive) { pendingDeletion = account }
    }

    private func edit(_ account: Account) {
        guard let provider = model.provider(for: account) else { return }
        sheet = .edit(AccountDraft(provider: provider, account: account, token: model.token(for: account)))
    }
}

struct AccountSettingsRow: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let onEdit: () -> Void

    var body: some View {
        let descriptor = model.descriptor(for: account)
        let status = model.statuses[account.id]
        Button(action: onEdit) {
            HStack(spacing: 10) {
                ProviderBadge(descriptor: descriptor, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .foregroundStyle(.primary)
                    Text(subtitle(descriptor))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(account.isEnabled ? 1 : 0.5)
                Spacer()
                // Only problems need attention; a healthy account shows its spend instead of a status.
                if let issue = status?.issue {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let snapshot = status?.snapshot {
                    CostText(money: snapshot.total, kind: snapshot.totalKind)
                        .foregroundStyle(.secondary)
                        .opacity(account.isEnabled ? 1 : 0.5)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ descriptor: ProviderDescriptor?) -> String {
        let base = "\(descriptor?.displayName ?? account.providerID) · \(account.scopeID)"
        return account.isEnabled ? base : "\(base) · " + String(localized: "Hidden")
    }
}

// MARK: - Budgets

struct BudgetsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                BudgetField(title: "Total budget", value: Binding(
                    get: { model.totalBudget },
                    set: { model.setTotalBudget($0) }
                ))
                if let budget = model.totalBudget {
                    BudgetBar(title: "This period", spent: model.grandTotal ?? Money(0), limit: budget, tint: .accentColor)
                        .padding(.vertical, 2)
                }
            } header: {
                Text("All Accounts")
            } footer: {
                Text("Compared with the combined spend of the accounts shown in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.accounts.isEmpty {
                    Text("Add an account to set its budget.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    AccountBudgetRow(account: account)
                }
            } header: {
                Text("Per Account")
            } footer: {
                Text("Budgets apply to each account's current billing period. The menu bar icon turns yellow at 80% of any budget and shows a red ! once one is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountBudgetRow: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let snapshot = model.statuses[account.id]?.snapshot
        let status = model.budgetStatus(for: account)
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot: snapshot, status: status)
            if let budget = account.budget, let spent = snapshot?.total {
                BudgetProgress(fraction: BudgetBar.fraction(spent: spent, limit: budget), color: status.color(normal: model.descriptor(for: account)?.tint ?? .accentColor))
                    .padding(.leading, 34)
                    .opacity(account.isEnabled ? 1 : 0.5)
            }
        }
    }

    private func header(snapshot: UsageSnapshot?, status: BudgetStatus) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(descriptor: model.descriptor(for: account), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                HStack(spacing: 3) {
                    // Yellow text is unreadable on light backgrounds, so warnings use an icon instead.
                    if status != .normal {
                        Image(systemName: status == .exceeded ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.color(normal: .secondary))
                    }
                    Text(spendText(snapshot?.total))
                        .foregroundStyle(status == .exceeded ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .font(.caption)
            }
            .opacity(account.isEnabled ? 1 : 0.5)
            Spacer()
            BudgetField(title: "Budget", value: Binding(
                get: { account.budget },
                set: { model.setBudget($0, for: account) }
            ))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
        }
    }

    private func spendText(_ total: Money?) -> String {
        guard let total else { return "No data yet" }
        guard let budget = account.budget, budget > 0 else { return "\(total.formatted) this period" }
        let percent = BudgetBar.fraction(spent: total, limit: budget)
            .formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current))
        return "\(total.formatted) this period · \(percent)"
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Picker("Refresh every", selection: $model.refreshMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                }
                LabeledContent("Last refreshed") {
                    HStack {
                        Text(model.lastRefresh?.relativeDescription ?? "Never")
                            .foregroundStyle(.secondary)
                        Button("Refresh Now") {
                            Task { await model.refreshAll() }
                        }
                        .disabled(model.isRefreshing)
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Most providers update billing data hourly or daily, so frequent refreshes rarely show new numbers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let storageError = model.storageError {
                Section {
                    Label(storageError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Launch at login needs the bundled app: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
