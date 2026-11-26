import Foundation

/// A provider-reported account balance, scoped to the space that requested it.
/// Endpoint identity contains no query, user information or credentials.
public struct ProductCostBalance: Codable, Equatable, Identifiable, Sendable {
    public let providerID: UUID
    public let endpoint: String
    public let currency: String
    public let amount: String
    public let observedAt: Date
    public var id: String { providerID.uuidString + ":" + currency }

    public init(providerID: UUID, endpoint: String, currency: String, amount: String, observedAt: Date) {
        self.providerID = providerID; self.endpoint = endpoint; self.currency = currency
        self.amount = amount; self.observedAt = observedAt
    }

    public var isValid: Bool {
        guard amount.utf8.count <= 128, let value = Double(amount), value.isFinite, observedAt.timeIntervalSince1970.isFinite,
              currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let url = URLComponents(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    public func applies(to provider: LLMProviderConfig) -> Bool {
        providerID == provider.id && endpoint == (try? CloudProvider.balanceURL(for: provider.endpoint).absoluteString)
    }

    public static func snapshots(provider: LLMProviderConfig, balance: ProviderBalance, observedAt: Date) throws -> [Self] {
        try EndpointSafety.validate(provider.endpoint)
        let endpoint = try CloudProvider.balanceURL(for: provider.endpoint).absoluteString
        let values = balance.items.filter { $0.label == .total }.map {
            Self(providerID: provider.id, endpoint: endpoint, currency: $0.currency.uppercased(), amount: $0.amount, observedAt: observedAt)
        }
        guard !values.isEmpty, values.allSatisfy(\.isValid), Set(values.map(\.id)).count == values.count else {
            throw ProductCostAccountingError.invalidBalance
        }
        return values
    }
}

/// A recount moves the cost baseline. The underlying usage ledger is preserved.
public struct ProductCostCheckpoint: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var balances: [ProductCostBalance]
    /// SQLite dates have millisecond precision. Existing receipts at the boundary
    /// stay excluded even when they finish after recounting or are restored later.
    public let excludedBoundaryRequestIDs: [String]?

    public init(id: UUID = UUID(), startedAt: Date, balances: [ProductCostBalance], excludedBoundaryRequestIDs: [String] = []) {
        self.id = id; self.startedAt = startedAt; self.balances = balances
        self.excludedBoundaryRequestIDs = excludedBoundaryRequestIDs
    }
}

public struct ProductCostAccountingSnapshot: Equatable, Sendable {
    public var checkpoint: ProductCostCheckpoint?
    public var amounts: [String: Double]
    public var unknownGroups: Int
    public var requests: Int

    public init(checkpoint: ProductCostCheckpoint? = nil, amounts: [String: Double] = [:], unknownGroups: Int = 0, requests: Int = 0) {
        self.checkpoint = checkpoint; self.amounts = amounts
        self.unknownGroups = unknownGroups; self.requests = requests
    }
}

public enum ProductCostAccountingError: Error {
    case changed
    case invalidBalance
}
