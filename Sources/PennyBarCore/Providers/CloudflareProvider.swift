import Foundation

/// Cloudflare's Billable Usage API (alpha, PayGo accounts only) returns FOCUS rows with dollar costs.
/// https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/get_account_usage_v1/
public struct CloudflareProvider: UsageProvider {
    static let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    public let descriptor = ProviderDescriptor(
        id: "cloudflare",
        displayName: "Cloudflare",
        symbolName: "cloud.fill",
        scopeLabel: "Account",
        tokenLabel: "API Token",
        tokenHelp: "Create a custom token with Account › Billing › Read.",
        tokenURL: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!,
        dashboardURL: URL(string: "https://dash.cloudflare.com/?to=/:account/billing")!,
        tintHex: "F38020",
        totalKind: .billed
    )

    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func scopes(token: String) async throws -> [ProviderScope] {
        struct Account: Decodable { let id: String; let name: String }
        let url = Self.baseURL.appending(path: "accounts").appending(query: ["per_page": "50"])
        let accounts = try await envelope([Account].self, for: .bearer(url, token: token))
        return accounts.map { ProviderScope(id: $0.id, name: $0.name) }
    }

    public func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot {
        // Without from/to the endpoint returns the account's current billing period.
        let url = Self.baseURL.appending(path: "accounts/\(scopeID)/billable-usage")
        let records = try await envelope([FOCUSRecord].self, for: .bearer(url, token: token))
        let (total, items) = FOCUS.summarize(records)

        let periodStart = records.compactMap(\.billingPeriodStart).min()
        let period = BillingPeriod(
            start: periodStart ?? UTC.startOfMonth(now),
            end: records.compactMap(\.billingPeriodEnd).max(),
            isApproximate: periodStart == nil
        )
        var notes = ["Updated daily by Cloudflare. Excludes the plan's base subscription fee."]
        if records.isEmpty {
            notes.append("No billable usage reported yet this period.")
        }
        return UsageSnapshot(period: period, total: total, totalKind: .billed, items: items, notes: notes, fetchedAt: now)
    }

    /// Unwraps Cloudflare's `{ success, errors, result }` envelope.
    private func envelope<T: Decodable & Sendable>(_ type: T.Type, for request: URLRequest) async throws -> T {
        let body = try await http.decode(CloudflareEnvelope<T>.self, for: request)
        guard body.success, let result = body.result else {
            let message = body.errors?.map(\.message).joined(separator: "; ") ?? "Request failed"
            throw ProviderError.invalidResponse("Cloudflare: \(message)")
        }
        return result
    }
}

private struct CloudflareEnvelope<T: Decodable>: Decodable {
    struct Message: Decodable { let code: Int?; let message: String }
    let success: Bool
    let errors: [Message]?
    let result: T?
}
