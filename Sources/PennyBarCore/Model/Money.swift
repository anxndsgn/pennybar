import Foundation

public struct Money: Codable, Hashable, Sendable {
    public var amount: Decimal
    public var currency: String

    public init(_ amount: Decimal, currency: String = "USD") {
        self.amount = amount
        self.currency = currency.uppercased()
    }
}

extension Money {
    /// Sums amounts that share a currency. Returns nil for an empty sequence or mixed currencies.
    public static func sum(_ values: some Sequence<Money>) -> Money? {
        var iterator = values.makeIterator()
        guard var total = iterator.next() else { return nil }
        while let next = iterator.next() {
            guard next.currency == total.currency else { return nil }
            total.amount += next.amount
        }
        return total
    }
}

extension Decimal {
    init(_ value: Double, roundedTo scale: Int) {
        var raw = Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, scale, .plain)
        self = rounded
    }
}
