import Foundation

/// Railway's public GraphQL API. The billing fields used here (`customer`, `usage`) are not in Railway's
/// docs; they were confirmed by schema introspection and may change without notice.
public struct RailwayProvider: UsageProvider {
    static let endpoint = URL(string: "https://backboard.railway.com/graphql/v2")!

    public let descriptor = ProviderDescriptor(
        id: "railway",
        displayName: "Railway",
        symbolName: "train.side.front.car",
        scopeLabel: "Workspace",
        tokenLabel: "Account Token",
        tokenHelp: "Use an account token so workspaces can be listed. A workspace token also works if you paste the workspace ID.",
        tokenURL: URL(string: "https://railway.com/account/tokens")!,
        dashboardURL: URL(string: "https://railway.com/account/usage")!,
        tintHex: "A855F7",
        totalKind: .billed
    )

    /// Published per-unit rates, used only for the per-resource breakdown.
    /// The headline total comes from Railway's `customer.currentUsage`.
    /// https://docs.railway.com/reference/pricing/plans
    static let rates: [(measurement: String, name: String, unit: String, dollarsPerUnit: Double)] = [
        ("CPU_USAGE", "CPU", "vCPU-min", 0.000463),
        ("MEMORY_USAGE_GB", "Memory", "GB-min", 0.000231),
        ("NETWORK_TX_GB", "Egress", "GB", 0.05),
        ("DISK_USAGE_GB", "Volumes", "GB-min", 0.00000347),
    ]

    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func scopes(token: String) async throws -> [ProviderScope] {
        struct Workspace: Decodable { let id: String; let name: String }
        struct Me: Decodable { let workspaces: [Workspace] }
        struct Response: Decodable { let me: Me }
        let response = try await query(Response.self, token: token, "query { me { workspaces { id name } } }")
        return response.me.workspaces.map { ProviderScope(id: $0.id, name: $0.name) }
    }

    public func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot {
        struct Period: Decodable { let start: String; let end: String }
        struct Limit: Decodable { let softLimit: Int?; let hardLimit: Int? }
        struct Customer: Decodable {
            let currentUsage: Double
            let billingPeriod: Period
            let usageLimit: Limit?
        }
        struct Workspace: Decodable { let customer: Customer? }
        struct BillingResponse: Decodable { let workspace: Workspace }

        let billing = try await query(BillingResponse.self, token: token, """
            query Billing($ws: String!) {
              workspace(workspaceId: $ws) {
                customer { currentUsage billingPeriod { start end } usageLimit { softLimit hardLimit } }
              }
            }
            """, variables: ["ws": scopeID])
        guard let customer = billing.workspace.customer else {
            throw ProviderError.forbidden("Railway returned no billing data for this workspace.")
        }
        let start = UTC.parse(customer.billingPeriod.start) ?? UTC.startOfMonth(now)

        struct Usage: Decodable { let measurement: String; let value: Double }
        struct UsageResponse: Decodable { let usage: [Usage] }
        let usage = try await query(UsageResponse.self, token: token, """
            query Usage($ws: String!, $start: DateTime!, $end: DateTime!, $m: [MetricMeasurement!]!) {
              usage(workspaceId: $ws, startDate: $start, endDate: $end, measurements: $m, includeDeleted: true) {
                measurement value
              }
            }
            """, variables: [
                "ws": scopeID,
                "start": UTC.string(start),
                "end": UTC.string(now),
                "m": Self.rates.map(\.measurement),
            ])

        let totals = Dictionary(usage.usage.map { ($0.measurement, $0.value) }, uniquingKeysWith: +)
        let items = Self.rates.map { rate in
            let quantity = totals[rate.measurement] ?? 0
            return LineItem(
                name: rate.name,
                quantity: quantity,
                unit: rate.unit,
                cost: Money(Decimal(quantity * rate.dollarsPerUnit, roundedTo: 2)),
                costKind: .estimated
            )
        }
        let limit = (customer.usageLimit?.hardLimit ?? customer.usageLimit?.softLimit).map { Money(Decimal($0)) }

        return UsageSnapshot(
            period: BillingPeriod(start: start, end: UTC.parse(customer.billingPeriod.end)),
            total: Money(Decimal(customer.currentUsage, roundedTo: 2)),
            totalKind: .billed,
            items: items,
            limit: limit,
            notes: ["Usage so far this cycle. Your plan's included credit is applied on the invoice."],
            fetchedAt: now
        )
    }

    private func query<T: Decodable>(
        _ type: T.Type,
        token: String,
        _ query: String,
        variables: [String: any Sendable] = [:]
    ) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let envelope = try await http.decode(GraphQLEnvelope<T>.self, for: .bearer(Self.endpoint, token: token, method: "POST", body: body))
        if let errors = envelope.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "; ")
            // Railway reports auth failures as GraphQL errors on a 200 response.
            if message.localizedCaseInsensitiveContains("not authorized") { throw ProviderError.unauthorized }
            throw ProviderError.invalidResponse("Railway: \(message)")
        }
        guard let data = envelope.data else {
            throw ProviderError.invalidResponse("Railway returned no data.")
        }
        return data
    }
}

private struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct GraphQLError: Decodable { let message: String }
    let data: T?
    let errors: [GraphQLError]?
}
