import Foundation

/// Vercel's billing charges endpoint streams daily FOCUS rows as JSONL.
/// https://vercel.com/docs/rest-api/billing/list-focus-billing-charges
public struct VercelProvider: UsageProvider {
    static let baseURL = URL(string: "https://api.vercel.com")!

    public let descriptor = ProviderDescriptor(
        id: "vercel",
        displayName: "Vercel",
        symbolName: "triangle.fill",
        scopeLabel: "Team",
        tokenLabel: "Access Token",
        tokenHelp: "Vercel tokens have no read-only scope. Limit the token to one team and set an expiry.",
        tokenURL: URL(string: "https://vercel.com/account/tokens")!,
        dashboardURL: URL(string: "https://vercel.com/dashboard")!,
        tintHex: nil,
        totalKind: .billed
    )

    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func scopes(token: String) async throws -> [ProviderScope] {
        struct Team: Decodable { let id: String; let name: String? }
        struct Teams: Decodable { let teams: [Team] }
        let url = Self.baseURL.appending(path: "v2/teams").appending(query: ["limit": "100"])
        return try await http.decode(Teams.self, for: .bearer(url, token: token))
            .teams.map { ProviderScope(id: $0.id, name: $0.name ?? $0.id) }
    }

    public func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot {
        // The API doesn't expose the team's billing anchor, so assume the calendar month in UTC.
        // `to` is exclusive and day-granular, so ask through the end of today.
        let from = UTC.startOfMonth(now)
        let url = Self.baseURL.appending(path: "v1/billing/charges").appending(query: [
            "teamId": scopeID,
            "from": UTC.string(from),
            "to": UTC.string(UTC.startOfNextDay(now)),
        ])
        var request = URLRequest.bearer(url, token: token)
        request.setValue("application/jsonl", forHTTPHeaderField: "Accept")
        let records = try FOCUS.parseJSONLines(try await http.checkedData(for: request))
        let (total, items) = FOCUS.summarize(records)

        return UsageSnapshot(
            period: BillingPeriod(start: from, end: UTC.startOfNextMonth(now), isApproximate: true),
            total: total,
            totalKind: .billed,
            items: items,
            notes: ["Daily charges since the 1st (UTC). Your billing cycle may start on a different day."],
            fetchedAt: now
        )
    }
}
