import Foundation

/// How spend compares with a budget. Ordered by severity so the worst of several can be taken with `max()`.
public enum BudgetStatus: Int, Comparable, Sendable {
    case normal
    /// At or above `warningFraction` of the budget.
    case warning
    /// At or above the budget.
    case exceeded

    public static let warningFraction: Decimal = 0.8

    public init(spent: Money?, budget: Decimal?) {
        guard let spent, let budget, budget > 0 else {
            self = .normal
            return
        }
        let fraction = spent.amount / budget
        self = fraction >= 1 ? .exceeded : fraction >= Self.warningFraction ? .warning : .normal
    }

    public static func < (lhs: BudgetStatus, rhs: BudgetStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
