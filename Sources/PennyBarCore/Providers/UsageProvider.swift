import Foundation

/// Static metadata the UI needs to present and configure a provider.
public struct ProviderDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    /// SF Symbol shown next to the provider's accounts, or "custom.<name>" for a mark the app draws.
    public let symbolName: String
    /// What the provider calls a billing scope: "Account", "Team", "Workspace", "Organization".
    public let scopeLabel: String
    public let tokenLabel: String
    /// The permissions the user should grant when creating the token.
    public let tokenHelp: String
    public let tokenURL: URL
    /// The provider's own billing or usage page, opened from the menu.
    public let dashboardURL: URL
    /// Brand color as RRGGBB, or nil to use the system label color (for monochrome brands).
    public let tintHex: String?
    /// Whether the headline total comes from the provider's billing system or local estimation.
    public let totalKind: CostKind
    /// Labels for credentials the provider issues in several pieces. The editor shows one field per
    /// piece and stores them joined with ":"; empty means a single token field.
    public var credentialParts: [String] = []
}

public struct ProviderScope: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One usage-billed service. Adding a service means adding a conforming type and
/// registering it in `ProviderRegistry.standard`; the UI and storage need no changes.
public protocol UsageProvider: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Billing scopes the token can see, offered in the account editor's picker.
    func scopes(token: String) async throws -> [ProviderScope]

    /// Usage and cost for the current billing period of one scope.
    func snapshot(token: String, scopeID: String, now: Date) async throws -> UsageSnapshot
}

public struct ProviderRegistry: Sendable {
    public let providers: [any UsageProvider]

    public init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    public static func standard(http: any HTTPClient = URLSessionHTTPClient()) -> ProviderRegistry {
        ProviderRegistry(providers: [
            CloudflareProvider(http: http),
            VercelProvider(http: http),
            RailwayProvider(http: http),
            NeonProvider(http: http),
            PlanetScaleProvider(http: http),
        ])
    }

    /// "Cloudflare, Vercel or Neon", for copy that lists the supported services.
    public var displayNames: String {
        let names = providers.map(\.descriptor.displayName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    public func provider(id: String) -> (any UsageProvider)? {
        providers.first { $0.descriptor.id == id }
    }
}

enum UTC {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    static func startOfNextMonth(_ date: Date) -> Date {
        calendar.date(byAdding: .month, value: 1, to: startOfMonth(date))!
    }

    static func startOfNextDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Parses the timestamp shapes billing APIs return: with or without fractional seconds, or a bare date.
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}
