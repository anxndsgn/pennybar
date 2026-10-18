import Foundation

/// A configured connection: one token plus one billing scope on one provider.
/// The token itself lives in the Keychain under `id`; nothing secret is stored here.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var providerID: String
    public var name: String
    /// Provider-specific billing scope: Cloudflare account, Vercel team, Railway workspace, Neon org.
    public var scopeID: String
    public var isEnabled: Bool
    /// Spending budget for this account's billing period, in USD. Nil means no budget.
    public var budget: Decimal?

    public init(
        id: UUID = UUID(),
        providerID: String,
        name: String,
        scopeID: String,
        isEnabled: Bool = true,
        budget: Decimal? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.scopeID = scopeID
        self.isEnabled = isEnabled
        self.budget = budget
    }
}
