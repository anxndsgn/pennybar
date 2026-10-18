import Foundation

/// Neon reports invoice-aligned usage but no dollar amounts, so cost is computed from published prices.
/// https://neon.com/docs/guides/consumption-metrics and https://neon.com/docs/introduction/usage-calculations
public struct NeonProvider: UsageProvider {
    static let baseURL = URL(string: "https://console.neon.tech/api/v2")!

    public let descriptor = ProviderDescriptor(
        id: "neon",
        displayName: "Neon",
        symbolName: "cylinder.fill",
        scopeLabel: "Organization",
        tokenLabel: "API Key",
        tokenHelp: "A personal API key covers every organization you belong to. Usage data needs a paid plan.",
        tokenURL: URL(string: "https://console.neon.tech/app/settings/api-keys")!,
        dashboardURL: URL(string: "https://console.neon.tech/app/billing")!,
        tintHex: "00C98D",
        totalKind: .estimated
    )

    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func scopes(token: String) async throws -> [ProviderScope] {
        struct Organization: Decodable { let id: String; let name: String; let plan: String? }
        struct Response: Decodable { let organizations: [Organization] }
        let url = Self.baseURL.appending(path: "users/me/organizations")
        return try await http.decode(Response.self, for: .bearer(url, token: token)).organizations.map { org in
            ProviderScope(id: org.id, name: org.plan.map { "\(org.name) (\($0))" } ?? org.name)
        }
    }

    public func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot {
        let projects = try await consumption(token: token, orgID: scopeID, now: now)
        return NeonCostCalculator.snapshot(projects: projects, now: now)
    }

    private func consumption(token: String, orgID: String, now: Date) async throws -> [NeonProjectConsumption] {
        struct Pagination: Decodable { let cursor: String? }
        struct Page: Decodable { let projects: [NeonProjectConsumption]; let pagination: Pagination? }

        let pageSize = 100
        var projects: [NeonProjectConsumption] = []
        var cursor: String?
        repeat {
            var query = [
                "org_id": orgID,
                "from": UTC.string(UTC.startOfMonth(now)),
                // Day-granular and rounded down, so ask through the end of today.
                "to": UTC.string(UTC.startOfNextDay(now)),
                "granularity": "daily",
                "metrics": NeonMetric.allCases.map(\.rawValue).joined(separator: ","),
                "limit": String(pageSize),
            ]
            query["cursor"] = cursor
            let url = Self.baseURL.appending(path: "consumption_history/v2/projects").appending(query: query)
            let page = try await http.decode(Page.self, for: .bearer(url, token: token))
            projects += page.projects
            cursor = page.projects.count == pageSize ? page.pagination?.cursor : nil
        } while cursor != nil
        return projects
    }
}

enum NeonMetric: String, CaseIterable, Sendable {
    case computeUnitSeconds = "compute_unit_seconds"
    case rootBranchBytesMonth = "root_branch_bytes_month"
    case childBranchBytesMonth = "child_branch_bytes_month"
    case instantRestoreBytesMonth = "instant_restore_bytes_month"
    case snapshotStorageBytesMonth = "snapshot_storage_bytes_month"
    case publicNetworkTransferBytes = "public_network_transfer_bytes"
    case privateNetworkTransferBytes = "private_network_transfer_bytes"
    case extraBranchesMonth = "extra_branches_month"
}

struct NeonProjectConsumption: Decodable, Sendable {
    struct Metric: Decodable, Sendable { let metric_name: String; let value: Double }
    struct Timeframe: Decodable, Sendable { let metrics: [Metric] }
    struct Period: Decodable, Sendable {
        let period_plan: String
        let period_start: String
        let period_end: String?
        let consumption: [Timeframe]
    }

    let project_id: String
    let periods: [Period]
}

/// Neon's published usage-based rates, in dollars.
struct NeonPricing: Sendable {
    let computePerCUHour: Double
    let storagePerGBMonth: Double
    let instantRestorePerGBMonth: Double
    let snapshotPerGBMonth: Double
    let publicTransferPerGB: Double
    let includedPublicTransferGB: Double
    let privateTransferPerGB: Double?
    let extraBranchPerMonth: Double
    let includedBranchesPerProject: Double

    static func forPlan(_ plan: String) -> NeonPricing? {
        switch plan.lowercased() {
        case "launch":
            NeonPricing(
                computePerCUHour: 0.106, storagePerGBMonth: 0.35, instantRestorePerGBMonth: 0.20,
                snapshotPerGBMonth: 0.09, publicTransferPerGB: 0.10, includedPublicTransferGB: 500,
                privateTransferPerGB: nil, extraBranchPerMonth: 1.50, includedBranchesPerProject: 10
            )
        case "scale":
            NeonPricing(
                computePerCUHour: 0.222, storagePerGBMonth: 0.35, instantRestorePerGBMonth: 0.20,
                snapshotPerGBMonth: 0.09, publicTransferPerGB: 0.10, includedPublicTransferGB: 500,
                privateTransferPerGB: 0.01, extraBranchPerMonth: 1.50, includedBranchesPerProject: 25
            )
        default:
            nil
        }
    }
}

enum NeonCostCalculator {
    /// Neon bills against a fixed 744-hour (31-day) month and decimal gigabytes.
    static let hoursPerBillingMonth = 744.0
    static let bytesPerGB = 1_000_000_000.0

    static func snapshot(projects: [NeonProjectConsumption], now: Date) -> UsageSnapshot {
        // A query starting on the 1st can overlap the tail of a previous billing period; keep the latest.
        let latestStart = projects.flatMap(\.periods).map(\.period_start).max()
        let currentPeriods = projects.compactMap { project in
            project.periods.first { $0.period_start == latestStart }.map { (project.project_id, $0) }
        }
        let plan = currentPeriods.first?.1.period_plan ?? "unknown"
        let periodStart = latestStart.flatMap(UTC.parse) ?? UTC.startOfMonth(now)
        let hoursElapsed = max(now.timeIntervalSince(periodStart) / 3600, 0)

        var sums: [NeonMetric: Double] = [:]
        var extraBranchMonths = 0.0
        let pricing = NeonPricing.forPlan(plan)
        for (_, period) in currentPeriods {
            var projectSums: [NeonMetric: Double] = [:]
            for metric in period.consumption.flatMap(\.metrics) {
                guard let key = NeonMetric(rawValue: metric.metric_name) else { continue }
                projectSums[key, default: 0] += metric.value
            }
            for (key, value) in projectSums { sums[key, default: 0] += value }
            // The branch allowance applies per project, pro-rated to the part of the month elapsed so far.
            let branchMonths = (projectSums[.extraBranchesMonth] ?? 0) / hoursPerBillingMonth
            let allowance = (pricing?.includedBranchesPerProject ?? 0) * hoursElapsed / hoursPerBillingMonth
            extraBranchMonths += max(branchMonths - allowance, 0)
        }

        func value(_ metric: NeonMetric) -> Double { sums[metric] ?? 0 }
        let cuHours = value(.computeUnitSeconds) / 3600
        let storageGBMonths = (value(.rootBranchBytesMonth) + value(.childBranchBytesMonth)) / bytesPerGB
        let restoreGBMonths = value(.instantRestoreBytesMonth) / bytesPerGB
        let snapshotGBMonths = value(.snapshotStorageBytesMonth) / bytesPerGB
        let publicGB = value(.publicNetworkTransferBytes) / bytesPerGB
        let privateGB = value(.privateNetworkTransferBytes) / bytesPerGB

        func item(_ name: String, _ quantity: Double, _ unit: String, _ dollars: Double?) -> LineItem {
            LineItem(
                name: name,
                quantity: quantity,
                unit: unit,
                cost: dollars.map { Money(Decimal($0, roundedTo: 2)) },
                costKind: .estimated
            )
        }
        let p = pricing
        let items = [
            item("Compute", cuHours, "CU-hr", p.map { cuHours * $0.computePerCUHour }),
            item("Storage", storageGBMonths, "GB-mo", p.map { storageGBMonths * $0.storagePerGBMonth }),
            item("Instant restore", restoreGBMonths, "GB-mo", p.map { restoreGBMonths * $0.instantRestorePerGBMonth }),
            item("Snapshots", snapshotGBMonths, "GB-mo", p.map { snapshotGBMonths * $0.snapshotPerGBMonth }),
            item("Public transfer", publicGB, "GB", p.map { max(publicGB - $0.includedPublicTransferGB, 0) * $0.publicTransferPerGB }),
            item("Private transfer", privateGB, "GB", p.map { privateGB * ($0.privateTransferPerGB ?? 0) }),
            item("Extra branches", extraBranchMonths, "branch-mo", p.map { extraBranchMonths * $0.extraBranchPerMonth }),
        ]

        var notes = ["Estimated from Neon's \(plan.capitalized) plan prices. Data refreshes about every 15 minutes."]
        if pricing == nil {
            notes = ["No usage-based prices known for the \"\(plan)\" plan, so only quantities are shown."]
        }
        return UsageSnapshot(
            period: BillingPeriod(start: periodStart, end: UTC.startOfNextMonth(periodStart)),
            total: pricing == nil ? nil : Money.sum(items.compactMap(\.cost)),
            totalKind: .estimated,
            items: items,
            notes: notes,
            fetchedAt: now
        )
    }
}
