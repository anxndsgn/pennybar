import Foundation

/// PlanetScale's invoice API returns billed dollar totals and line items per organization.
/// https://planetscale.com/docs/api/reference/list_invoices
public struct PlanetScaleProvider: UsageProvider {
    static let baseURL = URL(string: "https://api.planetscale.com/v1")!

    public let descriptor = ProviderDescriptor(
        id: "planetscale",
        displayName: "PlanetScale",
        symbolName: "custom.planetscale",
        scopeLabel: "Organization",
        tokenLabel: "Service Token",
        tokenHelp: "Create a service token with read_organization and read_invoices access.",
        tokenURL: URL(string: "https://app.planetscale.com")!,
        dashboardURL: URL(string: "https://app.planetscale.com")!,
        tintHex: "F35815",
        totalKind: .billed,
        // PlanetScale shows a token ID and a token separately; the API wants them joined as "ID:TOKEN".
        credentialParts: ["Token ID", "Token"]
    )

    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func scopes(token: String) async throws -> [ProviderScope] {
        struct Organization: Decodable { let name: String }
        let url = Self.baseURL.appending(path: "organizations").appending(query: ["per_page": "100"])
        let page = try await http.decode(Page<Organization>.self, for: try request(url, token: token))
        // The organization name is the slug used in every other path.
        return page.data.map { ProviderScope(id: $0.name, name: $0.name) }
    }

    public func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot {
        let invoicesURL = Self.baseURL.appending(path: "organizations/\(scopeID)/invoices").appending(query: ["per_page": "12"])
        let invoices = try await http.decode(Page<Invoice>.self, for: try request(invoicesURL, token: token)).data

        guard let current = invoices.first(where: { $0.contains(now) }) else {
            // If the API omits the in-progress invoice, say so rather than presenting
            // last month's bill as this period's spend.
            var notes = ["PlanetScale hasn't published an invoice for the current period yet."]
            if let latest = invoices.max(by: { ($0.end ?? .distantPast) < ($1.end ?? .distantPast) }) {
                notes.append("Last invoice: $\(latest.total) (\(latest.billing_period_start) – \(latest.billing_period_end)).")
            }
            return UsageSnapshot(
                period: BillingPeriod(start: UTC.startOfMonth(now), end: UTC.startOfNextMonth(now), isApproximate: true),
                total: nil,
                totalKind: .billed,
                items: [],
                notes: notes,
                fetchedAt: now
            )
        }

        let lineItems = try await allLineItems(token: token, organization: scopeID, invoiceID: current.id)
        let items = Dictionary(grouping: lineItems, by: \.label)
            .map { label, rows in
                LineItem(name: label, cost: Money(rows.reduce(0) { $0 + $1.subtotal }), costKind: .billed)
            }
            .sorted { (lhs: LineItem, rhs: LineItem) in
                let (lhsCost, rhsCost) = (lhs.cost?.amount ?? 0, rhs.cost?.amount ?? 0)
                return lhsCost != rhsCost ? lhsCost > rhsCost : lhs.name < rhs.name
            }

        return UsageSnapshot(
            period: BillingPeriod(start: current.start ?? UTC.startOfMonth(now), end: current.end),
            total: Money(current.amount),
            totalKind: .billed,
            items: items,
            notes: ["From the current PlanetScale invoice. Spend alerts set in the PlanetScale dashboard aren't readable through the API."],
            fetchedAt: now
        )
    }

    private func allLineItems(token: String, organization: String, invoiceID: String) async throws -> [InvoiceLineItem] {
        var items: [InvoiceLineItem] = []
        var page = 1
        while true {
            let url = Self.baseURL
                .appending(path: "organizations/\(organization)/invoices/\(invoiceID)/line-items")
                .appending(query: ["page": String(page), "per_page": "100"])
            let response = try await http.decode(Page<InvoiceLineItem>.self, for: try request(url, token: token))
            items += response.data
            guard let next = response.next_page, next > page else { return items }
            page = next
        }
    }

    /// Service tokens go in the Authorization header as "ID:TOKEN" with no scheme.
    private func request(_ url: URL, token: String) throws -> URLRequest {
        guard token.contains(":") else {
            throw ProviderError.invalidResponse("Enter both the service token ID and the token.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

private struct Page<Item: Decodable>: Decodable {
    let data: [Item]
    let next_page: Int?
}

struct Invoice: Decodable {
    let id: String
    let amount: Decimal
    let billing_period_start: String
    let billing_period_end: String

    var total: String { "\(amount)" }

    enum CodingKeys: String, CodingKey { case id, total, billing_period_start, billing_period_end }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Amounts come back as decimal strings ("5.0") even where the OpenAPI spec says number.
        amount = try container.lenientDecimal(forKey: .total) ?? 0
        billing_period_start = try container.decode(String.self, forKey: .billing_period_start)
        billing_period_end = try container.decode(String.self, forKey: .billing_period_end)
    }

    var start: Date? { UTC.parse(billing_period_start) }
    var end: Date? { UTC.parse(billing_period_end) }

    func contains(_ date: Date) -> Bool {
        guard let start, let end else { return false }
        return start <= date && date < end
    }
}

struct InvoiceLineItem: Decodable {
    let subtotal: Decimal
    let description: String
    let metric_name: String?
    let database_name: String?

    enum CodingKeys: String, CodingKey { case subtotal, description, metric_name, database_name }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Documented as a number, returned as a string such as "5.0".
        subtotal = try container.lenientDecimal(forKey: .subtotal) ?? 0
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? "Other"
        metric_name = try container.decodeIfPresent(String.self, forKey: .metric_name)
        database_name = try container.decodeIfPresent(String.self, forKey: .database_name)
    }

    /// Groups the bill by database when the line names one, otherwise by its description.
    var label: String {
        if let database_name, !database_name.isEmpty { database_name } else { description }
    }
}
