import Foundation
import Observation
import PennyBarCore

struct AccountStatus {
    var snapshot: UsageSnapshot?
    var issue: AccountIssue?
    var isRefreshing = false
}

/// A refresh failure, split into a short label for the row and the full message for details.
struct AccountIssue: Equatable {
    var title: String
    var detail: String

    init(_ error: any Error) {
        detail = error.localizedDescription
        switch error {
        case let error as ProviderError:
            title = switch error {
            case .unauthorized: "Token rejected"
            case .forbidden: "Missing permission"
            case .rateLimited: "Rate limited"
            case .http(let status, _): "Server error \(status)"
            case .decoding: "Unexpected response"
            case .invalidResponse: "Couldn't load"
            }
        case let error as URLError where error.code == .notConnectedToInternet:
            title = "Offline"
        case is URLError:
            title = "Network error"
        default:
            title = "Couldn't load"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case total
    case iconAndTotal
    case icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .total: "Total"
        case .iconAndTotal: "Icon and total"
        case .icon: "Icon only"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let registry: ProviderRegistry
    private let tokens: any TokenStore
    private let accountStore: JSONFileStore<[Account]>?
    private let snapshotStore: JSONFileStore<[String: UsageSnapshot]>?
    private let defaults: UserDefaults

    private(set) var accounts: [Account] = []
    private(set) var statuses: [UUID: AccountStatus] = [:]
    private(set) var lastRefresh: Date?
    var storageError: String?

    var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: "refreshMinutes")
            scheduleRefresh()
        }
    }

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }

    /// Budget for the combined spend of all accounts shown in the menu, in USD. Nil means none.
    private(set) var totalBudget: Decimal? {
        didSet {
            if let totalBudget {
                defaults.set(totalBudget.description, forKey: "totalBudget")
            } else {
                defaults.removeObject(forKey: "totalBudget")
            }
        }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        registry: ProviderRegistry = .standard(),
        tokens: any TokenStore = KeychainTokenStore(),
        accountStore: JSONFileStore<[Account]>? = JSONFileStore(filename: "accounts.json"),
        snapshotStore: JSONFileStore<[String: UsageSnapshot]>? = JSONFileStore(filename: "snapshots.json"),
        defaults: UserDefaults = .standard,
        autoRefresh: Bool = true
    ) {
        self.registry = registry
        self.tokens = tokens
        self.accountStore = accountStore
        self.snapshotStore = snapshotStore
        self.defaults = defaults
        let storedMinutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = storedMinutes > 0 ? storedMinutes : 30
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) ?? .iconAndTotal
        totalBudget = defaults.string(forKey: "totalBudget").flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        do {
            accounts = try accountStore?.load() ?? []
            for (id, snapshot) in try snapshotStore?.load() ?? [:] {
                if let uuid = UUID(uuidString: id) { statuses[uuid] = AccountStatus(snapshot: snapshot) }
            }
        } catch {
            storageError = error.localizedDescription
        }
        if autoRefresh { scheduleRefresh() }
    }

    // MARK: Derived state

    var enabledAccounts: [Account] { accounts.filter(\.isEnabled) }

    /// Sum of every enabled account's current-period total. Accounts without a total are skipped.
    var grandTotal: Money? {
        Money.sum(enabledAccounts.compactMap { statuses[$0.id]?.snapshot?.total })
    }

    /// Sum of per-account forecasts, falling back to the current total where no forecast exists yet.
    func projectedTotal(at now: Date) -> Money? {
        Money.sum(enabledAccounts.compactMap { account in
            guard let snapshot = statuses[account.id]?.snapshot else { return nil }
            return snapshot.projectedTotal(at: now) ?? snapshot.total
        })
    }

    var totalIncludesEstimates: Bool {
        enabledAccounts.contains { statuses[$0.id]?.snapshot?.totalKind == .estimated }
    }

    // MARK: Budgets

    var totalBudgetStatus: BudgetStatus {
        BudgetStatus(spent: grandTotal, budget: totalBudget)
    }

    func budgetStatus(for account: Account) -> BudgetStatus {
        BudgetStatus(spent: statuses[account.id]?.snapshot?.total, budget: account.budget)
    }

    /// The most severe of the total budget and every visible account's budget; drives the menu bar icon.
    var overallBudgetStatus: BudgetStatus {
        (enabledAccounts.map(budgetStatus(for:)) + [totalBudgetStatus]).max() ?? .normal
    }

    func setTotalBudget(_ budget: Decimal?) {
        totalBudget = budget.flatMap { $0 > 0 ? $0 : nil }
    }

    func setBudget(_ budget: Decimal?, for account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].budget = budget.flatMap { $0 > 0 ? $0 : nil }
        persistAccounts()
    }

    var failingAccounts: [Account] {
        enabledAccounts.filter { statuses[$0.id]?.issue != nil }
    }

    var isRefreshing: Bool { statuses.values.contains(where: \.isRefreshing) }

    func provider(for account: Account) -> (any UsageProvider)? {
        registry.provider(id: account.providerID)
    }

    func descriptor(for account: Account) -> ProviderDescriptor? {
        provider(for: account)?.descriptor
    }

    // MARK: Refresh

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let interval = Duration.seconds(refreshMinutes * 60)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refreshAll() async {
        await withTaskGroup { group in
            for account in enabledAccounts {
                group.addTask { await self.refresh(account) }
            }
        }
        lastRefresh = .now
        persistSnapshots()
    }

    func refresh(_ account: Account) async {
        statuses[account.id, default: AccountStatus()].isRefreshing = true
        defer { statuses[account.id]?.isRefreshing = false }
        do {
            guard let provider = provider(for: account) else {
                throw ProviderError.invalidResponse("Unknown provider \"\(account.providerID)\".")
            }
            guard let token = try tokens.token(for: account.id), !token.isEmpty else {
                throw ProviderError.invalidResponse("No token saved. Edit the account to add one.")
            }
            let snapshot = try await provider.snapshot(token: token, scopeID: account.scopeID, now: .now)
            statuses[account.id]?.snapshot = snapshot
            statuses[account.id]?.issue = nil
        } catch {
            // Keep the last good snapshot visible next to the error.
            statuses[account.id]?.issue = AccountIssue(error)
        }
    }

    // MARK: Account management

    func token(for account: Account) -> String {
        (try? tokens.token(for: account.id)) ?? ""
    }

    func save(_ account: Account, token: String) throws {
        try tokens.setToken(token, for: account.id)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        statuses[account.id]?.snapshot = nil
        try accountStore?.save(accounts)
        Task {
            await refresh(account)
            persistSnapshots()
        }
    }

    func setEnabled(_ enabled: Bool, for account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].isEnabled = enabled
        persistAccounts()
        if enabled { Task { await refresh(accounts[index]) } }
    }

    func delete(_ account: Account) {
        try? tokens.deleteToken(for: account.id)
        accounts.removeAll { $0.id == account.id }
        statuses[account.id] = nil
        persistAccounts()
        persistSnapshots()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persistAccounts()
    }

    private func persistAccounts() {
        do { try accountStore?.save(accounts) } catch { storageError = error.localizedDescription }
    }

    private func persistSnapshots() {
        let snapshots = statuses.reduce(into: [String: UsageSnapshot]()) { result, entry in
            if let snapshot = entry.value.snapshot { result[entry.key.uuidString] = snapshot }
        }
        do { try snapshotStore?.save(snapshots) } catch { storageError = error.localizedDescription }
    }
}

// MARK: - Sample data

extension AppModel {
    /// A model filled with representative accounts, for SwiftUI previews and `--render-previews`.
    static func preview(now: Date = .now, empty: Bool = false) -> AppModel {
        let model = AppModel(
            tokens: InMemoryTokenStore(),
            accountStore: nil,
            snapshotStore: nil,
            defaults: UserDefaults(suiteName: "PennyBarPreview")!,
            autoRefresh: false
        )
        guard !empty else { return model }

        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let cycleStart = calendar.date(byAdding: .day, value: -9, to: now)!
        func period(_ start: Date, approximate: Bool = false) -> BillingPeriod {
            BillingPeriod(start: start, end: calendar.date(byAdding: .month, value: 1, to: start), isApproximate: approximate)
        }
        func item(_ name: String, _ quantity: Double?, _ unit: String?, _ cost: Decimal, _ kind: CostKind = .billed) -> LineItem {
            LineItem(name: name, quantity: quantity, unit: unit, cost: Money(cost), costKind: kind)
        }

        let samples: [(Account, AccountStatus)] = [
            (Account(providerID: "vercel", name: "Acme", scopeID: "team_acme", budget: 50), AccountStatus(snapshot: UsageSnapshot(
                period: period(monthStart, approximate: true), total: Money(46.10), totalKind: .billed,
                items: [
                    item("Fast Data Transfer", 312, "GB", 21.40),
                    item("Function Duration", 1_840, "GB-Hrs", 14.25),
                    item("Edge Requests", 9_800_000, "Requests", 8.95),
                    item("Image Optimization", 4_200, "Images", 1.50),
                ],
                notes: ["Daily charges since the 1st (UTC). Your billing cycle may start on a different day."],
                fetchedAt: now.addingTimeInterval(-240)))),
            (Account(providerID: "neon", name: "acme-org", scopeID: "org-acme"), AccountStatus(snapshot: UsageSnapshot(
                period: period(monthStart), total: Money(19.84), totalKind: .estimated,
                items: [
                    item("Compute", 152.4, "CU-hr", 16.15, .estimated),
                    item("Storage", 10.5, "GB-mo", 3.69, .estimated),
                    item("Public transfer", 41, "GB", 0, .estimated),
                    item("Snapshots", 0, "GB-mo", 0, .estimated),
                ],
                notes: ["Estimated from Neon's Launch plan prices. Data refreshes about every 15 minutes."],
                fetchedAt: now.addingTimeInterval(-240)))),
            (Account(providerID: "railway", name: "Side projects", scopeID: "ws_side", budget: 30), AccountStatus(snapshot: UsageSnapshot(
                period: period(cycleStart), total: Money(38.35), totalKind: .billed,
                items: [
                    item("Memory", 98_000, "GB-min", 22.64, .estimated),
                    item("CPU", 26_000, "vCPU-min", 12.04, .estimated),
                    item("Egress", 52, "GB", 2.60, .estimated),
                    item("Volumes", 310_000, "GB-min", 1.07, .estimated),
                ],
                limit: Money(50),
                notes: ["Usage so far this cycle. Your plan's included credit is applied on the invoice."],
                fetchedAt: now.addingTimeInterval(-240)))),
            (Account(providerID: "cloudflare", name: "Personal", scopeID: "cf_personal"), AccountStatus(snapshot: UsageSnapshot(
                period: period(cycleStart), total: Money(8.42), totalKind: .billed,
                items: [
                    item("Workers Standard", 31_000_000, "Requests", 6.30),
                    item("R2 Storage", 140, "GB-mo", 2.12),
                ],
                notes: ["Updated daily by Cloudflare. Excludes the plan's base subscription fee."],
                fetchedAt: now.addingTimeInterval(-240)))),
            (Account(providerID: "cloudflare", name: "Client work", scopeID: "cf_client"), AccountStatus(
                snapshot: UsageSnapshot(
                    period: period(cycleStart), total: Money(3.10), totalKind: .billed,
                    items: [item("Workers Standard", 12_000_000, "Requests", 3.10)],
                    fetchedAt: now.addingTimeInterval(-2 * 86_400)),
                issue: AccountIssue(ProviderError.unauthorized))),
        ]
        for (account, status) in samples {
            model.accounts.append(account)
            model.statuses[account.id] = status
        }
        model.lastRefresh = now.addingTimeInterval(-240)
        model.setTotalBudget(150)
        return model
    }
}
