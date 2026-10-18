import Foundation

/// One row of a FinOps FOCUS cost export (https://focus.finops.org).
/// Cloudflare and Vercel both bill through this shape; future providers that adopt FOCUS can reuse it.
public struct FOCUSRecord: Decodable, Sendable, Equatable {
    public var serviceName: String
    public var chargeCategory: String?
    public var billedCost: Decimal
    public var billingCurrency: String?
    public var consumedQuantity: Double?
    public var consumedUnit: String?
    public var billingPeriodStart: Date?
    public var billingPeriodEnd: Date?

    enum CodingKeys: String, CodingKey {
        case serviceName = "ServiceName"
        case chargeCategory = "ChargeCategory"
        case billedCost = "BilledCost"
        case billingCurrency = "BillingCurrency"
        case consumedQuantity = "ConsumedQuantity"
        case consumedUnit = "ConsumedUnit"
        case billingPeriodStart = "BillingPeriodStart"
        case billingPeriodEnd = "BillingPeriodEnd"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName) ?? "Other"
        chargeCategory = try container.decodeIfPresent(String.self, forKey: .chargeCategory)
        billedCost = try container.lenientDecimal(forKey: .billedCost) ?? 0
        billingCurrency = try container.decodeIfPresent(String.self, forKey: .billingCurrency)
        consumedQuantity = try container.lenientDecimal(forKey: .consumedQuantity).map { NSDecimalNumber(decimal: $0).doubleValue }
        consumedUnit = try container.decodeIfPresent(String.self, forKey: .consumedUnit)
        billingPeriodStart = try container.decodeIfPresent(String.self, forKey: .billingPeriodStart).flatMap(UTC.parse)
        billingPeriodEnd = try container.decodeIfPresent(String.self, forKey: .billingPeriodEnd).flatMap(UTC.parse)
    }
}

extension KeyedDecodingContainer {
    /// FOCUS exports encode numbers as either JSON numbers or strings depending on the provider.
    func lenientDecimal(forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let string = try? decode(String.self, forKey: key) {
            return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        }
        return try decode(Decimal.self, forKey: key)
    }
}

public enum FOCUS {
    /// Parses newline-delimited JSON, skipping blank lines.
    public static func parseJSONLines(_ data: Data) throws -> [FOCUSRecord] {
        let decoder = JSONDecoder()
        return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard line.contains(where: { !$0.isWhitespace }) else { return nil }
            do {
                return try decoder.decode(FOCUSRecord.self, from: Data(line))
            } catch {
                throw ProviderError.decoding("FOCUS row: \(error.localizedDescription) — \(snippet(Data(line)))")
            }
        }
    }

    /// Groups rows by service. The total includes credits and adjustments so it matches what will be billed.
    public static func summarize(_ records: [FOCUSRecord]) -> (total: Money, items: [LineItem]) {
        let currency = records.first?.billingCurrency ?? "USD"
        var total = Money(0, currency: currency)
        var byService: [String: (cost: Decimal, quantity: Double, units: Set<String>)] = [:]
        for record in records {
            total.amount += record.billedCost
            var entry = byService[record.serviceName] ?? (0, 0, [])
            entry.cost += record.billedCost
            entry.quantity += record.consumedQuantity ?? 0
            if let unit = record.consumedUnit { entry.units.insert(unit) }
            byService[record.serviceName] = entry
        }
        let items = byService
            .map { name, entry in
                // Quantities only add up when every row uses the same unit.
                let unit = entry.units.count == 1 ? entry.units.first : nil
                return LineItem(
                    name: name,
                    quantity: unit == nil ? nil : entry.quantity,
                    unit: unit,
                    cost: Money(entry.cost, currency: currency),
                    costKind: .billed
                )
            }
            // Fully ordered so equal-cost rows (often all $0 inside free tiers) keep their place across refreshes.
            .sorted { (lhs: LineItem, rhs: LineItem) in
                let (lhsCost, rhsCost) = (lhs.cost?.amount ?? 0, rhs.cost?.amount ?? 0)
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                let (lhsQuantity, rhsQuantity) = (lhs.quantity ?? 0, rhs.quantity ?? 0)
                if lhsQuantity != rhsQuantity { return lhsQuantity > rhsQuantity }
                return lhs.name < rhs.name
            }
        return (total, items)
    }
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0D || self == 0x0A }
}
