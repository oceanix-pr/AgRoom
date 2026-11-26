import Foundation
import Observation
import AgRoomCore

@MainActor @Observable
final class ProductCostAccountingModel {
    typealias BalanceFetcher = @Sendable (LLMProviderConfig) async throws -> ProviderBalance

    private let service: UsageService?
    private let fetchBalance: BalanceFetcher
    private var generation = UUID()
    private var providerContext: [LLMProviderConfig] = []
    private var recountTask: Task<Void, Never>?
    private var lastBalanceAttempt: Date?
    private(set) var snapshot: ProductCostAccountingSnapshot?
    private(set) var loading = false
    private(set) var refreshingBalances = false
    private(set) var recounting = false
    private(set) var errorKey: String?

    init(service: UsageService?, fetchBalance: @escaping BalanceFetcher = ProductCostAccountingModel.fetchLiveBalance) {
        self.service = service; self.fetchBalance = fetchBalance
    }

    var isAvailable: Bool { service != nil }
    var canRecount: Bool { service != nil && snapshot != nil && !loading && !refreshingBalances && !recounting }

    func load(prices: [ProductModelPrice], providers: [LLMProviderConfig], interval: DateInterval?) async {
        guard let service else { return }
        if providerContext != providers {
            invalidate(); providerContext = providers; lastBalanceAttempt = nil
        }
        guard !recounting else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false; refreshingBalances = false } }
        do {
            let value = try await service.costAccounting(prices: prices, providers: providers, in: interval)
            guard isCurrent(ticket) else { return }
            snapshot = value; errorKey = nil; loading = false
            let supported = supportedProviders(providers)
            guard let checkpoint = value.checkpoint, !supported.isEmpty,
                  lastBalanceAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
            // Reopening reads current account balances; ordinary usage notifications
            // are throttled and never move the consumption baseline.
            if supported.allSatisfy({ provider in checkpoint.balances.contains { balance in
                let age = Date().timeIntervalSince(balance.observedAt)
                return balance.applies(to: provider) && age >= 0 && age < 60
            } }) { return }
            refreshingBalances = true
            do {
                let balances = try await balances(for: providers)
                guard isCurrent(ticket) else { return }
                lastBalanceAttempt = Date()
                try await service.updateCostBalances(balances, checkpointID: checkpoint.id)
                let updated = try await service.costAccounting(prices: prices, providers: providers, in: interval)
                guard isCurrent(ticket) else { return }
                snapshot = updated
            } catch {
                guard isCurrent(ticket) else { return }
                lastBalanceAttempt = Date()
                errorKey = "product.cost.balance.failed"
            }
        } catch {
            guard isCurrent(ticket) else { return }
            errorKey = "product.cost.load.failed"
        }
    }

    func startRecount(prices: [ProductModelPrice], providers: [LLMProviderConfig], interval: DateInterval?) {
        guard canRecount else { return }
        recountTask = Task { await recount(prices: prices, providers: providers, interval: interval) }
    }

    func recount(prices: [ProductModelPrice], providers: [LLMProviderConfig], interval: DateInterval?) async {
        guard canRecount, let service else { return }
        let ticket = UUID(), expectedID = snapshot?.checkpoint?.id
        generation = ticket; recounting = true; errorKey = nil
        var fetched = false, committed = false
        defer { if generation == ticket { recounting = false; recountTask = nil } }
        do {
            let balances = try await balances(for: providers)
            fetched = true
            guard isCurrent(ticket) else { return }
            let checkpoint = try await service.recountCosts(balances: balances, replacing: expectedID)
            committed = true
            guard isCurrent(ticket) else { return }
            lastBalanceAttempt = Date()
            let currencies = Set(prices.map(\.currency))
            snapshot = .init(checkpoint: checkpoint, amounts: Dictionary(uniqueKeysWithValues:
                (currencies.isEmpty ? [ProductModelPrice.defaultCurrency] : currencies.sorted()).map { ($0, 0.0) }))
            let updated = try await service.costAccounting(prices: prices, providers: providers, in: interval)
            guard isCurrent(ticket) else { return }
            snapshot = updated
        } catch ProductCostAccountingError.changed {
            guard isCurrent(ticket) else { return }
            errorKey = "product.cost.recount.conflict"
        } catch {
            guard isCurrent(ticket) else { return }
            errorKey = committed ? "product.cost.recount.refresh.failed" : (fetched ? "product.cost.recount.save.failed" : "product.cost.recount.failed")
        }
    }

    func invalidate() {
        generation = UUID(); recountTask?.cancel(); recountTask = nil
        loading = false; refreshingBalances = false; recounting = false
    }

    private func isCurrent(_ ticket: UUID) -> Bool { generation == ticket && !Task.isCancelled }

    private func supportedProviders(_ providers: [LLMProviderConfig]) -> [LLMProviderConfig] {
        providers.filter { $0.isEnabled && CloudProvider.supportsBalanceQuery(endpoint: $0.endpoint) }
    }

    private func balances(for providers: [LLMProviderConfig]) async throws -> [ProductCostBalance] {
        let fetch = fetchBalance, supported = supportedProviders(providers)
        return try await withThrowingTaskGroup(of: [ProductCostBalance].self) { group in
            for provider in supported {
                group.addTask {
                    let observedAt = Date()
                    let balance = try await fetch(provider)
                    try Task.checkCancellation()
                    return try ProductCostBalance.snapshots(provider: provider, balance: balance, observedAt: observedAt)
                }
            }
            var values: [ProductCostBalance] = []
            for try await balances in group { values += balances }
            try Task.checkCancellation()
            return values.sorted { $0.id < $1.id }
        }
    }

    nonisolated static func fetchLiveBalance(_ provider: LLMProviderConfig) async throws -> ProviderBalance {
        guard let key = KeychainService.loadAPIKey(for: provider.id), !key.isEmpty else { throw LLMError.invalidAPIKey }
        return try await CloudProvider(config: provider, apiKey: key).fetchBalance()
    }
}
