import Foundation
import Testing
@testable import PennyBarCore

@Suite struct FOCUSTests {
    @Test func parsesJSONLinesWithStringAndNumberCosts() throws {
        let data = Data("""
            {"ServiceName":"Fast Data Transfer","BilledCost":"1.25","BillingCurrency":"USD","ConsumedQuantity":"10","ConsumedUnit":"GB","ChargeCategory":"Usage"}

            {"ServiceName":"Fast Data Transfer","BilledCost":0.75,"BillingCurrency":"USD","ConsumedQuantity":5,"ConsumedUnit":"GB","ChargeCategory":"Usage"}
            {"ServiceName":"Credits","BilledCost":-0.5,"BillingCurrency":"USD","ChargeCategory":"Credit"}
            """.utf8)
        let records = try FOCUS.parseJSONLines(data)
        #expect(records.count == 3)

        let (total, items) = FOCUS.summarize(records)
        #expect(total == Money(1.5))
        let transfer = try #require(items.first { $0.name == "Fast Data Transfer" })
        #expect(transfer.cost == Money(2))
        #expect(transfer.quantity == 15)
        #expect(transfer.unit == "GB")
    }

    @Test func dropsQuantityWhenUnitsDiffer() throws {
        let data = Data("""
            {"ServiceName":"Workers","BilledCost":1,"ConsumedQuantity":1,"ConsumedUnit":"requests"}
            {"ServiceName":"Workers","BilledCost":1,"ConsumedQuantity":1,"ConsumedUnit":"ms"}
            """.utf8)
        let items = FOCUS.summarize(try FOCUS.parseJSONLines(data)).items
        #expect(items.first?.quantity == nil)
    }
}

@Suite struct CloudflareTests {
    @Test func summarizesBillableUsage() async throws {
        let http = MockHTTPClient([
            "/client/v4/accounts/acc1/billable-usage": (200, """
                {"success":true,"errors":[],"result":[
                  {"ServiceName":"Workers","BilledCost":3.2,"BillingCurrency":"USD","BillingPeriodStart":"2026-10-05T00:00:00Z","BillingPeriodEnd":"2026-11-05T00:00:00Z"},
                  {"ServiceName":"R2","BilledCost":1.1,"BillingCurrency":"USD","BillingPeriodStart":"2026-10-05T00:00:00Z","BillingPeriodEnd":"2026-11-05T00:00:00Z"}
                ]}
                """),
        ])
        let snapshot = try await CloudflareProvider(http: http).snapshot(token: "t", scopeID: "acc1", now: fixedNow)
        #expect(snapshot.total == Money(Decimal(string: "4.3")!))
        #expect(snapshot.totalKind == .billed)
        #expect(snapshot.items.map(\.name) == ["Workers", "R2"])
        #expect(snapshot.period.start == UTC.parse("2026-10-05T00:00:00Z"))
        #expect(!snapshot.period.isApproximate)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func surfacesEnvelopeErrors() async {
        let http = MockHTTPClient([
            "/client/v4/accounts/acc1/billable-usage": (200, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}"#),
        ])
        await #expect(throws: ProviderError.invalidResponse("Cloudflare: Authentication error")) {
            try await CloudflareProvider(http: http).snapshot(token: "t", scopeID: "acc1", now: fixedNow)
        }
    }

    @Test func mapsHTTPStatuses() async {
        let http = MockHTTPClient(["/client/v4/accounts": (401, "{}")])
        await #expect(throws: ProviderError.unauthorized) {
            try await CloudflareProvider(http: http).scopes(token: "bad")
        }
    }
}

@Suite struct VercelTests {
    @Test func requestsCalendarMonthForTeam() async throws {
        let http = MockHTTPClient([
            "/v1/billing/charges": (200, #"{"ServiceName":"Edge Requests","BilledCost":"2.00","BillingCurrency":"USD"}"#),
        ])
        let snapshot = try await VercelProvider(http: http).snapshot(token: "t", scopeID: "team_1", now: fixedNow)
        #expect(snapshot.total == Money(2))
        #expect(snapshot.period.isApproximate)

        let query = http.query(of: 0)
        #expect(query["teamId"] == "team_1")
        #expect(query["from"] == "2026-10-01T00:00:00Z")
        #expect(query["to"] == "2026-10-12T00:00:00Z")
    }
}

@Suite struct RailwayTests {
    final class SequencedClient: HTTPClient, @unchecked Sendable {
        var bodies: [String]
        var sent: [URLRequest] = []
        init(_ bodies: [String]) { self.bodies = bodies }
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.append(request)
            let body = bodies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func usesCurrentUsageAsBilledTotal() async throws {
        let http = SequencedClient([
            #"{"data":{"workspace":{"customer":{"currentUsage":12.345,"billingPeriod":{"start":"2026-10-03T00:00:00.000Z","end":"2026-11-03T00:00:00.000Z"},"usageLimit":{"softLimit":null,"hardLimit":50}}}}}"#,
            #"{"data":{"usage":[{"measurement":"CPU_USAGE","value":10000},{"measurement":"NETWORK_TX_GB","value":20}]}}"#,
        ])
        let snapshot = try await RailwayProvider(http: http).snapshot(token: "t", scopeID: "ws1", now: fixedNow)
        #expect(snapshot.total == Money(Decimal(string: "12.35")!))
        #expect(snapshot.totalKind == .billed)
        #expect(snapshot.limit == Money(50))
        #expect(snapshot.period.start == UTC.parse("2026-10-03T00:00:00Z"))

        let cpu = try #require(snapshot.items.first { $0.name == "CPU" })
        #expect(cpu.cost == Money(Decimal(string: "4.63")!))
        #expect(cpu.costKind == .estimated)
        let egress = try #require(snapshot.items.first { $0.name == "Egress" })
        #expect(egress.cost == Money(1))

        let body = try JSONSerialization.jsonObject(with: http.sent[1].httpBody!) as! [String: Any]
        let variables = body["variables"] as! [String: Any]
        #expect(variables["start"] as? String == "2026-10-03T00:00:00Z")
    }

    @Test func mapsNotAuthorizedToUnauthorized() async {
        let http = SequencedClient([#"{"data":null,"errors":[{"message":"Not Authorized"}]}"#])
        await #expect(throws: ProviderError.unauthorized) {
            try await RailwayProvider(http: http).scopes(token: "t")
        }
    }
}

@Suite struct NeonTests {
    static func page(plan: String, metrics: [String: Double]) -> String {
        let values = metrics.map { #"{"metric_name":"\#($0.key)","value":\#(Int($0.value))}"# }.joined(separator: ",")
        return """
            {"projects":[{"project_id":"p1","periods":[{"period_id":"x","period_plan":"\(plan)","period_start":"2026-10-01T00:00:00Z",
              "consumption":[{"timeframe_start":"2026-10-01T00:00:00Z","timeframe_end":"2026-10-02T00:00:00Z","metrics":[\(values)]}]}]}],
             "pagination":{"cursor":"p1"}}
            """
    }

    @Test func estimatesCostFromLaunchPrices() async throws {
        let http = MockHTTPClient([
            "/api/v2/consumption_history/v2/projects": (200, Self.page(plan: "launch", metrics: [
                "compute_unit_seconds": 360_000,               // 100 CU-hours → $10.60
                "root_branch_bytes_month": 10_000_000_000,     // 10 GB-months → $3.50
                "public_network_transfer_bytes": 600_000_000_000, // 600 GB, 100 over allowance → $10.00
            ])),
        ])
        let snapshot = try await NeonProvider(http: http).snapshot(token: "t", scopeID: "org-1", now: fixedNow)
        #expect(snapshot.totalKind == .estimated)
        #expect(snapshot.total == Money(Decimal(string: "24.10")!))
        #expect(snapshot.items.first { $0.name == "Compute" }?.quantity == 100)

        let query = http.query(of: 0)
        #expect(query["org_id"] == "org-1")
        #expect(query["granularity"] == "daily")
        #expect(query["metrics"]?.split(separator: ",").count == NeonMetric.allCases.count)
    }

    @Test func unknownPlanShowsQuantitiesOnly() async throws {
        let http = MockHTTPClient([
            "/api/v2/consumption_history/v2/projects": (200, Self.page(plan: "enterprise", metrics: ["compute_unit_seconds": 3600])),
        ])
        let snapshot = try await NeonProvider(http: http).snapshot(token: "t", scopeID: "org-1", now: fixedNow)
        #expect(snapshot.total == nil)
        #expect(snapshot.items.first { $0.name == "Compute" }?.quantity == 1)
        #expect(snapshot.items.allSatisfy { $0.cost == nil })
    }

    @Test func extraBranchAllowanceIsProRated() {
        // 30 branches running for the first 10 days on Launch (10 included): 20 extra × 240h.
        let hours = 240.0
        let project = NeonProjectConsumption(project_id: "p1", periods: [
            .init(period_plan: "launch", period_start: "2026-10-01T00:00:00Z", period_end: nil, consumption: [
                .init(metrics: [.init(metric_name: "extra_branches_month", value: 30 * hours)]),
            ]),
        ])
        let now = try! Date("2026-10-11T00:00:00Z", strategy: .iso8601)
        let snapshot = NeonCostCalculator.snapshot(projects: [project], now: now)
        let branches = snapshot.items.first { $0.name == "Extra branches" }
        let expectedMonths = 20 * hours / NeonCostCalculator.hoursPerBillingMonth
        #expect(abs((branches?.quantity ?? 0) - expectedMonths) < 0.0001)
    }
}

@Suite struct MoneyTests {
    @Test func sumRejectsMixedCurrencies() {
        #expect(Money.sum([Money(1), Money(2)]) == Money(3))
        #expect(Money.sum([Money(1), Money(2, currency: "EUR")]) == nil)
        #expect(Money.sum([Money]()) == nil)
    }
}

@Suite struct ProjectionTests {
    static func snapshot(total: Decimal, start: String, end: String?) -> UsageSnapshot {
        UsageSnapshot(
            period: BillingPeriod(start: UTC.parse(start)!, end: end.flatMap(UTC.parse)),
            total: Money(total),
            totalKind: .billed,
            items: [],
            fetchedAt: fixedNow
        )
    }

    @Test func projectsLinearlyToPeriodEnd() {
        // 10.5 of 31 days elapsed at $1/day → $31.
        let snapshot = Self.snapshot(total: 10.5, start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z")
        #expect(snapshot.projectedTotal(at: fixedNow) == Money(31))
    }

    @Test func skipsForecastOnFirstDay() {
        let snapshot = Self.snapshot(total: 2, start: "2026-10-11T00:00:00Z", end: "2026-11-11T00:00:00Z")
        #expect(snapshot.projectedTotal(at: fixedNow) == nil)
    }

    @Test func activeItemsDropEmptyMeters() {
        var snapshot = Self.snapshot(total: 1, start: "2026-10-01T00:00:00Z", end: nil)
        snapshot.items = [
            LineItem(name: "Used", quantity: 3, unit: "GB", cost: Money(1), costKind: .billed),
            LineItem(name: "Empty", quantity: 0, unit: "GB", cost: Money(0), costKind: .billed),
        ]
        #expect(snapshot.activeItems.map(\.name) == ["Used"])
    }
}

@Suite struct FOCUSOrderingTests {
    @Test func equalCostRowsHaveStableOrder() throws {
        let data = Data("""
            {"ServiceName":"B","BilledCost":0,"ConsumedQuantity":5,"ConsumedUnit":"x"}
            {"ServiceName":"A","BilledCost":0,"ConsumedQuantity":5,"ConsumedUnit":"x"}
            {"ServiceName":"C","BilledCost":0,"ConsumedQuantity":9,"ConsumedUnit":"x"}
            {"ServiceName":"D","BilledCost":1,"ConsumedQuantity":1,"ConsumedUnit":"x"}
            """.utf8)
        let names = FOCUS.summarize(try FOCUS.parseJSONLines(data)).items.map(\.name)
        #expect(names == ["D", "C", "A", "B"])
    }
}

@Suite struct BudgetTests {
    @Test func thresholds() {
        #expect(BudgetStatus(spent: Money(79.99), budget: 100) == .normal)
        #expect(BudgetStatus(spent: Money(80), budget: 100) == .warning)
        #expect(BudgetStatus(spent: Money(99.99), budget: 100) == .warning)
        #expect(BudgetStatus(spent: Money(100), budget: 100) == .exceeded)
        #expect(BudgetStatus(spent: Money(150), budget: 100) == .exceeded)
    }

    @Test func missingOrZeroBudgetIsNormal() {
        #expect(BudgetStatus(spent: Money(500), budget: nil) == .normal)
        #expect(BudgetStatus(spent: Money(500), budget: 0) == .normal)
        #expect(BudgetStatus(spent: nil, budget: 10) == .normal)
    }

    @Test func worstStatusWins() {
        #expect([BudgetStatus.normal, .exceeded, .warning].max() == .exceeded)
    }

    @Test func accountsSavedBeforeBudgetsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","providerID":"neon","name":"n","scopeID":"o","isEnabled":true}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.budget == nil)
    }
}

@Suite struct PlanetScaleTests {
    static let invoices = """
        {"type":"list","current_page":1,"next_page":null,"data":[
          {"id":"inv_cur","total":"42.50","billing_period_start":"2026-10-01T00:00:00.000Z","billing_period_end":"2026-11-01T00:00:00.000Z","paid":false,"overdue":false},
          {"id":"inv_prev","total":"39.00","billing_period_start":"2026-09-01T00:00:00.000Z","billing_period_end":"2026-10-01T00:00:00.000Z","paid":true,"overdue":false}
        ]}
        """

    @Test func usesCurrentInvoiceAndGroupsLineItemsByDatabase() async throws {
        let http = MockHTTPClient([
            "/v1/organizations/acme/invoices": (200, Self.invoices),
            "/v1/organizations/acme/invoices/inv_cur/line-items": (200, """
                {"type":"list","current_page":1,"next_page":null,"data":[
                  {"id":"1","subtotal":"30.0","description":"PS-10 cluster","metric_name":"cluster","cloudflare_billed":false,"database_id":"d1","database_name":"app-db","resource":{"id":"r","name":"main","created_at":"","updated_at":"","deleted_at":null}},
                  {"id":"2","subtotal":2.5,"description":"Storage","metric_name":"storage","cloudflare_billed":false,"database_id":"d1","database_name":"app-db","resource":{"id":"r","name":"main","created_at":"","updated_at":"","deleted_at":null}},
                  {"id":"3","subtotal":10.0,"description":"Development branches","metric_name":"dev","cloudflare_billed":false,"database_id":"","database_name":"","resource":{"id":"r","name":"x","created_at":"","updated_at":"","deleted_at":null}}
                ]}
                """),
        ])
        let snapshot = try await PlanetScaleProvider(http: http).snapshot(token: "id:secret", scopeID: "acme", now: fixedNow)
        #expect(snapshot.total == Money(Decimal(string: "42.50")!))
        #expect(snapshot.totalKind == .billed)
        #expect(snapshot.period.start == UTC.parse("2026-10-01T00:00:00Z"))
        #expect(snapshot.items.map(\.name) == ["app-db", "Development branches"])
        #expect(snapshot.items.first?.cost == Money(Decimal(string: "32.5")!))
        // Service tokens are sent raw, without a Bearer scheme.
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "id:secret")
    }

    @Test func missingCurrentInvoiceShowsNoTotal() async throws {
        let http = MockHTTPClient(["/v1/organizations/acme/invoices": (200, """
            {"type":"list","current_page":1,"next_page":null,"data":[
              {"id":"inv_prev","total":"39.00","billing_period_start":"2026-09-01T00:00:00.000Z","billing_period_end":"2026-10-01T00:00:00.000Z","paid":true,"overdue":false}
            ]}
            """)])
        let snapshot = try await PlanetScaleProvider(http: http).snapshot(token: "id:secret", scopeID: "acme", now: fixedNow)
        #expect(snapshot.total == nil)
        #expect(snapshot.notes.contains { $0.contains("$39") })
    }

    @Test func rejectsTokenWithoutID() async {
        await #expect(throws: ProviderError.self) {
            try await PlanetScaleProvider(http: MockHTTPClient([:])).scopes(token: "pscale_tkn_only")
        }
    }
}
