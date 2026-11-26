import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

private func recountQueue() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseBootstrap.prepareSpace(db)
    return db
}

private func recountProvider() -> LLMProviderConfig {
    .init(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "fixture")
}

private func recountBalance(_ amount: String = "100.123456") -> ProviderBalance {
    .init(isAvailable: true, items: [.init(label: .total, amount: amount, currency: "CNY")])
}

private func recountReceipt(_ id: String, provider: LLMProviderConfig, at date: Date, input: Int? = 1_000_000, output: Int? = 1_000_000, reported: Bool = true) -> ProviderUsageRecord {
    .init(id: id, sessionID: nil, providerID: provider.id.uuidString, providerName: provider.name,
        requestedModel: provider.model, source: "chat", startedAt: date, finishedAt: date.addingTimeInterval(1),
        status: "succeeded", usage: .init(input: input, output: output, reportedModel: reported ? provider.model : nil))
}

@Suite("Cost recount")
struct CostRecountTests {
    @Test("A recount preserves history and excludes old in-flight receipts, including the exact timestamp boundary")
    func baselineHistoryAndRestart() async throws {
        let db = try recountQueue(), provider = recountProvider(), date = Date(timeIntervalSince1970: 10_000)
        let usage = UsageService(databaseQueue: db), prefs = ProductPreferencesService(databaseQueue: db)
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        try await prefs.save(prices, key: "model-prices")
        try await usage.importRecords([recountReceipt("before", provider: provider, at: date.addingTimeInterval(-2))])
        let pending = UUID()
        try await usage.begin(id: pending, providerID: provider.id, model: provider.model, source: "chat", sessionID: nil, at: date)
        let old = try await usage.costAccounting(prices: prices, providers: [provider])
        #expect(old.amounts == ["CNY": 6] && old.unknownGroups == 1)
        let balances = try ProductCostBalance.snapshots(provider: provider, balance: recountBalance(), observedAt: date)
        let checkpoint = try await usage.recountCosts(balances: balances, replacing: nil, at: date)
        #expect(checkpoint.excludedBoundaryRequestIDs == [pending.uuidString])
        try await usage.finish(id: pending, input: 1_000_000, output: 1_000_000, status: "succeeded")
        let reset = try await usage.costAccounting(prices: prices, providers: [provider])
        #expect(reset.amounts == ["CNY": 0] && reset.requests == 0 && reset.unknownGroups == 0)
        // A genuinely new request in the same millisecond must be counted.
        try await usage.importRecords([
            recountReceipt("after-boundary", provider: provider, at: date),
            recountReceipt("missing-output", provider: provider, at: date.addingTimeInterval(2), input: 100, output: nil, reported: false)
        ])
        let reopened = try await UsageService(databaseQueue: db).costAccounting(prices: prices, providers: [provider])
        #expect(reopened.checkpoint == checkpoint && reopened.amounts == ["CNY": 6])
        #expect(reopened.requests == 2 && reopened.unknownGroups == 1)
        #expect(try await usage.exportRecords().count == 4)
        #expect(try await prefs.load([ProductModelPrice].self, key: "model-prices") == prices)
        let filtered = try await usage.costAccounting(prices: prices, providers: [provider],
            in: DateInterval(start: date.addingTimeInterval(1), end: date.addingTimeInterval(4)))
        #expect(filtered.amounts.isEmpty && filtered.requests == 1 && filtered.unknownGroups == 1)
        let other = try await UsageService(databaseQueue: recountQueue()).costAccounting(prices: prices, providers: [provider])
        #expect(other.checkpoint == nil && other.requests == 0)
        #expect(try JSONDecoder().decode(ProductCostCheckpoint.self, from: JSONEncoder().encode(checkpoint)) == checkpoint)
    }

    @Test("Balance refresh preserves consumption; stale replies and competing recounts cannot overwrite the new baseline")
    func refreshAndCompetingReset() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), provider = recountProvider()
        let date = Date(timeIntervalSince1970: 20_000)
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        let first = try await usage.recountCosts(balances: ProductCostBalance.snapshots(provider: provider, balance: recountBalance("100"), observedAt: date), replacing: nil, at: date)
        try await usage.importRecords([recountReceipt("spent", provider: provider, at: date.addingTimeInterval(1))])
        try await usage.updateCostBalances(ProductCostBalance.snapshots(provider: provider, balance: recountBalance("94"), observedAt: date.addingTimeInterval(2)), checkpointID: first.id)
        try await usage.updateCostBalances(ProductCostBalance.snapshots(provider: provider, balance: recountBalance("999"), observedAt: date.addingTimeInterval(-1)), checkpointID: first.id)
        let refreshed = try await usage.costAccounting(prices: prices, providers: [provider])
        #expect(refreshed.checkpoint?.id == first.id && refreshed.checkpoint?.startedAt == date)
        #expect(refreshed.checkpoint?.balances.first?.amount == "94" && refreshed.amounts == ["CNY": 6])
        let second = try await usage.recountCosts(balances: ProductCostBalance.snapshots(provider: provider, balance: recountBalance("90"), observedAt: date.addingTimeInterval(3)), replacing: first.id, at: date.addingTimeInterval(3))
        await #expect(throws: ProductCostAccountingError.self) {
            try await usage.recountCosts(balances: [], replacing: first.id)
        }
        await #expect(throws: ProductCostAccountingError.self) {
            try await usage.updateCostBalances([], checkpointID: first.id)
        }
        let current = try await usage.costAccounting(prices: prices, providers: [provider])
        #expect(current.checkpoint == second && current.amounts == ["CNY": 0])
        var changed = provider; changed.endpoint = "https://api.moonshot.cn/v1/chat/completions"
        #expect(current.checkpoint?.balances.first?.applies(to: changed) == false)
    }

    @Test("A failed checkpoint write rolls back both balances and the spending start time")
    func failedSaveIsAtomic() async throws {
        let db = try recountQueue(), usage = UsageService(databaseQueue: db), provider = recountProvider()
        let date = Date(timeIntervalSince1970: 30_000)
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        let first = try await usage.recountCosts(balances: ProductCostBalance.snapshots(provider: provider, balance: recountBalance("100"), observedAt: date), replacing: nil, at: date)
        try await usage.importRecords([recountReceipt("keep", provider: provider, at: date.addingTimeInterval(1))])
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_cost_recount BEFORE UPDATE ON product_preferences WHEN NEW.key = 'cost-checkpoint' BEGIN SELECT RAISE(ABORT, 'synthetic cost write failure'); END")
        }
        await #expect(throws: DatabaseError.self) { try await usage.recountCosts(balances: [], replacing: first.id) }
        let retained = try await usage.costAccounting(prices: prices, providers: [provider])
        #expect(retained.checkpoint == first && retained.amounts == ["CNY": 6])
        #expect(try await usage.exportRecords().count == 1)
    }
}

@MainActor
@Suite("Cost recount UI")
struct CostRecountModelTests {
    @Test("Recount reads balances, resets consumption and persists the new start across reopening")
    func recountAndReopen() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), provider = recountProvider(), calls = RecountCalls()
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        try await usage.importRecords([recountReceipt("old", provider: provider, at: Date().addingTimeInterval(-60))])
        let model = ProductCostAccountingModel(service: usage, fetchBalance: { _ in await calls.record(); return recountBalance() })
        await model.load(prices: prices, providers: [provider], interval: nil)
        #expect(model.snapshot?.amounts == ["CNY": 6] && model.canRecount)
        #expect(await calls.count == 0)
        await model.recount(prices: prices, providers: [provider], interval: nil)
        #expect(model.snapshot?.amounts == ["CNY": 0])
        #expect(model.snapshot?.checkpoint?.balances.first?.amount == "100.123456")
        #expect(model.errorKey == nil && !model.recounting)
        let checkpoint = try #require(model.snapshot?.checkpoint)
        try await usage.importRecords([recountReceipt("new", provider: provider, at: checkpoint.startedAt.addingTimeInterval(1))])
        let reopened = ProductCostAccountingModel(service: usage, fetchBalance: { _ in await calls.record(); return recountBalance() })
        await reopened.load(prices: prices, providers: [provider], interval: nil)
        #expect(reopened.snapshot?.amounts == ["CNY": 6] && reopened.snapshot?.checkpoint?.id == checkpoint.id)
        #expect(await calls.count == 1)
    }

    @Test("A failed balance query preserves the previous balance and consumption")
    func failedBalancePreservesCounters() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), provider = recountProvider(), now = Date()
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        let checkpoint = try await usage.recountCosts(balances: ProductCostBalance.snapshots(provider: provider, balance: recountBalance("80"), observedAt: now), replacing: nil, at: now.addingTimeInterval(-2))
        try await usage.importRecords([recountReceipt("keep", provider: provider, at: now.addingTimeInterval(-1))])
        let model = ProductCostAccountingModel(service: usage, fetchBalance: { _ in throw URLError(.notConnectedToInternet) })
        await model.load(prices: prices, providers: [provider], interval: nil)
        await model.recount(prices: prices, providers: [provider], interval: nil)
        #expect(model.errorKey == "product.cost.recount.failed")
        #expect(model.snapshot?.checkpoint == checkpoint && model.snapshot?.amounts == ["CNY": 6])
        #expect(try await usage.costAccounting(prices: prices, providers: [provider]).checkpoint == checkpoint)
    }

    @Test("A late balance reply after leaving the page does not commit a recount")
    func cancelledRecount() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), provider = recountProvider(), gate = RecountGate()
        let model = ProductCostAccountingModel(service: usage, fetchBalance: { _ in await gate.fetch() })
        await model.load(prices: [], providers: [provider], interval: nil)
        let pending = Task { await model.recount(prices: [], providers: [provider], interval: nil) }
        await gate.waitUntilStarted()
        model.invalidate(); pending.cancel()
        await gate.finish()
        await pending.value
        #expect(!model.recounting)
        #expect(try await usage.costAccounting(prices: [], providers: [provider]).checkpoint == nil)
    }

    @Test("Refreshing a stale provider balance leaves the original consumption baseline intact")
    func refreshDoesNotResetConsumption() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), provider = recountProvider(), now = Date()
        let prices = [ProductModelPrice(providerID: provider.id, model: provider.model, inputPerMillion: 2, outputPerMillion: 4)]
        let checkpoint = try await usage.recountCosts(balances: ProductCostBalance.snapshots(provider: provider, balance: recountBalance("100"), observedAt: now.addingTimeInterval(-120)), replacing: nil, at: now.addingTimeInterval(-120))
        try await usage.importRecords([recountReceipt("keep", provider: provider, at: now.addingTimeInterval(-60))])
        let model = ProductCostAccountingModel(service: usage, fetchBalance: { _ in recountBalance("94") })
        await model.load(prices: prices, providers: [provider], interval: nil)
        #expect(model.snapshot?.checkpoint?.id == checkpoint.id && model.snapshot?.checkpoint?.startedAt == checkpoint.startedAt)
        #expect(model.snapshot?.checkpoint?.balances.first?.amount == "94" && model.snapshot?.amounts == ["CNY": 6])
    }

    @Test("Local and unsupported providers can restart costs while their balance remains unknown")
    func unsupportedBalanceRemainsUnknown() async throws {
        let usage = UsageService(databaseQueue: try recountQueue()), calls = RecountCalls()
        let provider = LLMProviderConfig(name: "Local", endpoint: "http://localhost:1234/v1/chat/completions", model: "local")
        let model = ProductCostAccountingModel(service: usage, fetchBalance: { _ in await calls.record(); return recountBalance() })
        await model.load(prices: [], providers: [provider], interval: nil)
        await model.recount(prices: [], providers: [provider], interval: nil)
        #expect(model.snapshot?.checkpoint?.balances.isEmpty == true)
        #expect(model.snapshot?.amounts == ["CNY": 0] && model.errorKey == nil)
        #expect(await calls.count == 0)
    }
}

private actor RecountCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor RecountGate {
    private var pending: CheckedContinuation<ProviderBalance, Never>?
    private var started = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func fetch() async -> ProviderBalance {
        await withCheckedContinuation { continuation in
            pending = continuation; started = true
            let callbacks = watchers; watchers = []
            for watcher in callbacks { watcher.resume() }
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func finish() { pending?.resume(returning: recountBalance()); pending = nil }
}
