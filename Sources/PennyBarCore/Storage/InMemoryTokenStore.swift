import Foundation

/// Token store for previews and tests; nothing touches the Keychain.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String]

    public init(_ tokens: [UUID: String] = [:]) {
        self.tokens = tokens
    }

    public func token(for accountID: UUID) throws -> String? {
        lock.withLock { tokens[accountID] }
    }

    public func setToken(_ token: String, for accountID: UUID) throws {
        lock.withLock { tokens[accountID] = token }
    }

    public func deleteToken(for accountID: UUID) throws {
        lock.withLock { tokens[accountID] = nil }
    }
}
