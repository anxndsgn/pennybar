import Foundation

/// Where a dollar figure came from. The UI marks estimates so they are never mistaken for the bill.
public enum CostKind: String, Codable, Sendable {
    /// Reported by the provider's billing system.
    case billed
    /// Computed locally from usage quantities and published prices.
    case estimated
}

public struct BillingPeriod: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date?
    /// True when the provider doesn't expose its billing cycle and the calendar month was assumed.
    public var isApproximate: Bool

    public init(start: Date, end: Date? = nil, isApproximate: Bool = false) {
        self.start = start
        self.end = end
        self.isApproximate = isApproximate
    }
}

public struct LineItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var quantity: Double?
    public var unit: String?
    public var cost: Money?
    public var costKind: CostKind

    public init(name: String, quantity: Double? = nil, unit: String? = nil, cost: Money? = nil, costKind: CostKind) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.cost = cost
        self.costKind = costKind
    }
}

/// Provider-neutral view of one billing scope's current period. Every provider maps into this.
public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var period: BillingPeriod
    public var total: Money?
    public var totalKind: CostKind
    public var items: [LineItem]
    /// Spending cap or budget configured on the provider, if it exposes one.
    public var limit: Money?
    public var notes: [String]
    public var fetchedAt: Date

    public init(
        period: BillingPeriod,
        total: Money?,
        totalKind: CostKind,
        items: [LineItem],
        limit: Money? = nil,
        notes: [String] = [],
        fetchedAt: Date
    ) {
        self.period = period
        self.total = total
        self.totalKind = totalKind
        self.items = items
        self.limit = limit
        self.notes = notes
        self.fetchedAt = fetchedAt
    }
}

extension BillingPeriod {
    /// The period end, assuming a one-month cycle when the provider doesn't report one.
    public var effectiveEnd: Date {
        end ?? Calendar.current.date(byAdding: .month, value: 1, to: start)!
    }

    /// Fraction of the period elapsed at `now`, clamped to 0...1.
    public func progress(at now: Date) -> Double {
        let length = effectiveEnd.timeIntervalSince(start)
        guard length > 0 else { return 1 }
        return min(max(now.timeIntervalSince(start) / length, 0), 1)
    }
}

extension UsageSnapshot {
    /// Straight-line forecast of the period-end total. Nil in the first day of a period,
    /// where extrapolating a few hours of usage would be noise.
    public func projectedTotal(at now: Date) -> Money? {
        guard let total else { return nil }
        let elapsed = now.timeIntervalSince(period.start)
        guard elapsed >= 86_400 else { return nil }
        let progress = period.progress(at: now)
        guard progress < 1 else { return total }
        return Money(Decimal(NSDecimalNumber(decimal: total.amount).doubleValue / progress, roundedTo: 2), currency: total.currency)
    }

    /// Line items that carry any usage or cost, so empty meters don't crowd the breakdown.
    public var activeItems: [LineItem] {
        items.filter { ($0.cost?.amount ?? 0) != 0 || ($0.quantity ?? 0) != 0 }
    }
}
