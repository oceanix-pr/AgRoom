import Foundation
import GRDB
import Testing
import SwiftUI
import AppKit
@testable import AgRoomCore
@testable import AgRoomUI

private let pricingFixture = Data(#"""
{
  "deepseek": {"api":"https://api.deepseek.com", "models": {
    "deepseek-v4-pro":{"cost":{"input":0.66,"output":1.98}},
    "deepseek-flash":{"cost":{"input":0.15,"output":0.6}}
  }},
  "moonshotai": {"api":"https://api.moonshot.ai/v1", "models": {
    "kimi-k3.1-pro":{"cost":{"input":2,"output":10}}
  }},
  "moonshotai-cn": {"api":"https://api.moonshot.cn/v1", "models": {
    "kimi-k3.1-pro":{"cost":{"input":1.94,"output":10.16}}
  }}
}
"""#.utf8)

private func priceTarget(_ config: LLMProviderConfig) -> ProductModelPrice {
    ProductModelPrice(providerID: config.id, model: config.model)
}

private func pricePreferences() throws -> ProductPreferencesService {
    let db = try DatabaseQueue()
    try DatabaseBootstrap.prepareSpace(db)
    return ProductPreferencesService(databaseQueue: db)
}

@Suite("ModelPricing")
struct ModelPricingTests {
    @Test("Live public catalogs support the configured DeepSeek and Kimi IDs without API credentials",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_PUBLIC_MODEL_PRICING"] == "1"))
    func publicCatalog() async throws {
        let configs = [
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash"),
            LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro")
        ]
        let result = try await ModelPricingService().prices(for: configs.map(priceTarget), providers: configs)
        #expect(result.failedIDs.isEmpty)
        #expect(Set(result.prices.map(\.id)) == Set(configs.map(priceTarget).map(\.id)))
        #expect(result.prices.allSatisfy { $0.isValid && $0.source == .modelsDev })
    }

    @Test("Provider origin, region, service path and exact model ID determine the price")
    func providerIdentity() async throws {
        let configs = [
            LLMProviderConfig(name: "Renamed provider", endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "China", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro"),
            LLMProviderConfig(name: "Global", endpoint: "https://api.moonshot.ai/v1/chat/completions", model: "kimi-k3.1-pro"),
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://relay.example/v1/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "Subscription", endpoint: "https://api.moonshot.cn/coding/v1/chat/completions", model: "kimi-k3.1-pro"),
            LLMProviderConfig(name: "Unknown version", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro-unknown"),
            LLMProviderConfig(name: "Local", endpoint: "http://localhost:1234/v1/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "Different port", endpoint: "https://api.deepseek.com:8443/chat/completions", model: "deepseek-v4-pro")
        ]
        let calls = CatalogCalls()
        let service = ModelPricingService { url in
            await calls.record(url)
            return pricingFixture
        }
        let result = try await service.prices(for: configs.map(priceTarget), providers: configs)
        #expect(result.prices.count == 3)
        #expect(result.prices.first { $0.providerID == configs[0].id }?.inputPerMillion == 0.66)
        #expect(result.prices.first { $0.providerID == configs[1].id }?.inputPerMillion == 1.94)
        #expect(result.prices.first { $0.providerID == configs[2].id }?.inputPerMillion == 2)
        #expect(result.prices.first { $0.providerID == configs[1].id }?.sourceEndpoint == "https://api.moonshot.cn/v1")
        #expect(result.prices.allSatisfy { $0.currency == "USD" && $0.source == .modelsDev && $0.fetchedAt != nil })
        #expect(result.failedIDs.isEmpty)
        #expect(await calls.urls == [ProductModelPrice.Source.modelsDev.url])
    }

    @Test("OpenRouter rates convert per-token USD and reject incomplete, dynamic and invalid prices")
    func routerAndInvalidRates() async throws {
        let data = Data(#"""
        {"data":[
          {"id":"model","pricing":{"prompt":"0.000002","completion":"0.000008","request":"0"}},
          {"id":"free","pricing":{"prompt":"0","completion":"0"}},
          {"id":"dynamic","pricing":{"prompt":"-1","completion":"0.1"}},
          {"id":"partial","pricing":{"prompt":"0.1"}},
          {"id":"nan","pricing":{"prompt":"NaN","completion":"1"}},
          {"id":"boolean","pricing":{"prompt":true,"completion":1}},
          {"id":"request-fee","pricing":{"prompt":"0.1","completion":"0.1","request":"1"}}
        ]}
        """#.utf8)
        let configs = ["model", "free", "dynamic", "partial", "nan", "boolean", "request-fee"].map {
            LLMProviderConfig(name: "Router", endpoint: "https://openrouter.ai/api/v1/chat/completions", model: $0)
        }
        let calls = CatalogCalls()
        let service = ModelPricingService { url in await calls.record(url); return data }
        let result = try await service.prices(for: configs.map(priceTarget), providers: configs)
        #expect(result.prices.count == 2)
        let price = try #require(result.prices.first { $0.model == "model" })
        #expect(price.inputPerMillion == 2 && price.outputPerMillion == 8)
        #expect(price.estimate(input: 1_000_000, output: 1_000_000) == 10)
        #expect(result.prices.first { $0.model == "free" }?.estimate(input: 100, output: 100) == 0)
        #expect(await calls.urls == [ProductModelPrice.Source.openRouter.url])
    }

    @Test("Catalog failures preserve partial successes and local endpoints require no network")
    func partialFailureAndLocal() async throws {
        let direct = LLMProviderConfig(name: "Direct", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash")
        let router = LLMProviderConfig(name: "Router", endpoint: "https://openrouter.ai/api/v1/chat/completions", model: "model")
        let local = LLMProviderConfig(name: "LM Studio", endpoint: "http://127.0.0.1:1234/v1/chat/completions", model: "local")
        let calls = CatalogCalls()
        let service = ModelPricingService { url in
            await calls.record(url)
            if url.host == "models.dev" { return pricingFixture }
            throw URLError(.timedOut)
        }
        let result = try await service.prices(for: [direct, router, local].map(priceTarget), providers: [direct, router, local])
        #expect(result.prices.map(\.model) == [direct.model])
        #expect(result.failedIDs == [priceTarget(router).id])
        let before = await calls.urls.count
        let unknown = try await service.prices(for: [priceTarget(local)], providers: [local])
        #expect(unknown.prices.isEmpty && unknown.failedIDs.isEmpty)
        #expect(await calls.urls.count == before)
    }

    @Test("Old saved rates decode as manual; fetched rates survive restart and cannot overwrite a competing edit")
    func persistenceAndIsolation() async throws {
        let id = UUID()
        let legacy = Data("{\"providerID\":\"\(id.uuidString)\",\"model\":\"fixture\",\"currency\":\"CNY\",\"inputPerMillion\":0,\"outputPerMillion\":0}".utf8)
        let old = try JSONDecoder().decode(ProductModelPrice.self, from: legacy)
        #expect(old.source == nil && old.fetchedAt == nil && old.estimate(input: 1, output: 1) == 0)
        let first = try pricePreferences(), second = try pricePreferences()
        let fetched = ProductModelPrice(providerID: id, model: "fixture", currency: "USD", inputPerMillion: 2, outputPerMillion: 8,
            source: .modelsDev, fetchedAt: Date(timeIntervalSince1970: 1_000))
        try await first.saveModelPrices([fetched], replacing: [])
        let snapshot = try #require(try await first.load([ProductModelPrice].self, key: "model-prices"))
        #expect(snapshot == [fetched])
        try await first.saveModelPrices([old], replacing: snapshot)
        await #expect(throws: ModelPriceConflict.self) { try await first.saveModelPrices([fetched], replacing: snapshot) }
        #expect(try await first.load([ProductModelPrice].self, key: "model-prices") == [old])
        #expect(try await second.load([ProductModelPrice].self, key: "model-prices") == nil)
    }
}

@Suite("ModelPricing native layout", .serialized)
struct ModelPricingRenderingTests {
    @MainActor @Test("Cost cards render with fetched prices and unlisted models in all three languages",
        .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PRICING_SNAPSHOT_DIR"] != nil))
    func costCardRendering() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_PRICING_SNAPSHOT_DIR"])
        let configs = [
            LLMProviderConfig(name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-image-2.6-sunburst"),
            LLMProviderConfig(name: "OpenAI", endpoint: "https://api.openai.com/v1/responses", model: "gpt-6.2-astra"),
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash", alias: "deepseek-flash"),
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro", alias: "deepseek-v4-pro"),
            LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro", alias: "kimi-k3.1-pro"),
            LLMProviderConfig(name: "LM Studio", endpoint: "http://localhost:1234/v1/chat/completions", model: "qwen/qwen3.6-35b-a3b")
        ]
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let service = ProductPreferencesService(databaseQueue: db)
        let pricing = ModelPricingService { _ in pricingFixture }
        let rates = try await pricing.prices(for: configs.map(priceTarget), providers: configs)
        try await service.saveModelPrices(rates.prices, replacing: [])
        let usage = UsageService(databaseQueue: db), now = Date()
        try await usage.importRecords(configs.enumerated().map { index, config in
            ProviderUsageRecord(id: "pricing-preview-\(index)", sessionID: nil, providerID: config.id.uuidString,
                providerName: config.name, requestedModel: config.model, source: "chat", startedAt: now,
                finishedAt: now.addingTimeInterval(1), status: "succeeded",
                usage: .init(input: 10_000, output: 2_000, reportedModel: config.model))
        })
        let groups = try await usage.getStats().modelGroups
        let balance: @Sendable (LLMProviderConfig) -> ProviderBalance = { provider in
            ProviderBalance(isAvailable: true, items: [
                .init(label: .total, amount: provider.name == "Kimi" ? "32.5074" : "100.123456", currency: "CNY")
            ])
        }
        let balances = try configs.filter { CloudProvider.supportsBalanceQuery(endpoint: $0.endpoint) }.flatMap { config in
            try ProductCostBalance.snapshots(provider: config, balance: balance(config), observedAt: now)
        }
        _ = try await usage.recountCosts(balances: balances, replacing: nil, at: now.addingTimeInterval(-1))
        let oldLanguage = LanguageManager.shared.currentLanguage
        let oldLarge = InterfaceTypographyPreferences.shared.isLarge
        defer {
            LanguageManager.shared.currentLanguage = oldLanguage
            InterfaceTypographyPreferences.shared.isLarge = oldLarge
        }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                for (width, expanded) in [(480.0, false), (680.0, false), (1180.0, false), (680.0, true), (1180.0, true)] {
                    InterfaceTypographyPreferences.shared.isLarge = width <= 680
                    let host = NSHostingView(rootView: ScrollView {
                        ProductCostView(service: service, models: groups, providers: configs, pricing: pricing, initiallyExpanded: expanded,
                            usageService: usage, balanceFetcher: balance)
                            .padding(16)
                    }.font(MeetTypography.control)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 920),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("pricing-\(language.rawValue)-\(Int(width))-\(dark ? "dark" : "light")\(expanded ? "" : "-overview").png"))
                }
            }
        }
    }
}

@MainActor
@Suite("ModelPricing UI")
struct ModelPricingModelTests {
    @Test("Unpriced historical rows stay deleted across refresh and restart without deleting usage or another space's rows")
    func deleteUnpricedHistoricalModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-price-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("work.sqlite").path
        let db = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareSpace(db)
        let service = ProductPreferencesService(databaseQueue: db), usage = UsageService(databaseQueue: db)
        let config = LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro")
        let old = ProductModelPrice(providerID: config.id, model: "moonshot-v1-8k")
        let targets = [priceTarget(config), old]
        let request = UUID(), now = Date()
        try await usage.begin(id: request, providerID: config.id, model: old.model, source: "chat", sessionID: nil, at: now)
        try await usage.finish(id: request, input: nil, output: nil, status: "failed")
        let pricing = ModelPricingService { _ in pricingFixture }
        let model = ProductCostModel(service: service, pricing: pricing)
        await model.loadAndFill(providers: [config], targets: targets)
        #expect(model.drafts.first { $0.id == old.id }?.saved == nil)
        #expect(model.canDelete(id: old.id))
        let current = try #require(model.drafts.firstIndex { $0.model == config.model })
        model.drafts[current].input = "9"
        model.drafts[current].output = "18"

        await model.delete(id: old.id)
        #expect(model.errorKey == nil && model.hasDeletedModels)
        #expect(!model.drafts.contains { $0.id == old.id })
        #expect(model.drafts.first { $0.model == config.model }?.input == "9")
        #expect(model.canSave)
        #expect(try await service.loadModelPrices().dismissedIDs == [old.id])
        await model.loadAndFill(providers: [config], targets: targets, refresh: true)
        #expect(!model.drafts.contains { $0.id == old.id })
        #expect(model.drafts.first { $0.model == config.model }?.input == "9")
        await model.save()
        #expect(try await service.loadModelPrices().dismissedIDs == [old.id])

        let reopenedDB = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareSpace(reopenedDB)
        let reopened = ProductCostModel(service: ProductPreferencesService(databaseQueue: reopenedDB), pricing: pricing)
        await reopened.loadAndFill(providers: [config], targets: targets)
        #expect(!reopened.drafts.contains { $0.id == old.id })
        #expect(reopened.prices.first { $0.model == config.model }?.inputPerMillion == 9)
        #expect(try await usage.getRecords().map(\.id) == [request.uuidString])
        let personal = ProductCostModel(service: try pricePreferences(), pricing: pricing)
        await personal.loadAndFill(providers: [config], targets: targets)
        #expect(personal.drafts.contains { $0.id == old.id })

        await reopened.restoreDeleted(providers: [config], targets: targets)
        #expect(reopened.drafts.contains { $0.id == old.id && $0.saved == nil && $0.isEmpty })
        #expect(!reopened.hasDeletedModels)
    }

    @Test("Saved-rate deletion is atomic, stays deleted after lookup and can explicitly restore catalog rates")
    func deleteSavedModelRate() async throws {
        let db = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(db)
        let service = ProductPreferencesService(databaseQueue: db)
        let config = LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash")
        let old = ProductModelPrice(providerID: config.id, model: "deepseek-v4-pro")
        let targets = [priceTarget(config), old]
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in pricingFixture })
        await model.loadAndFill(providers: [config], targets: targets)
        let originalPrices = model.prices
        #expect(originalPrices.contains { $0.id == old.id })
        try await db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_model_price_dismissal BEFORE INSERT ON product_preferences
                WHEN NEW.key = 'model-price-dismissed-ids'
                BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END
                """)
        }
        await model.delete(id: old.id)
        #expect(model.errorKey == "error.database")
        #expect(model.prices == originalPrices && model.drafts.contains { $0.id == old.id })
        let unchanged = try await service.loadModelPrices()
        #expect(unchanged.prices == originalPrices && unchanged.dismissedIDs.isEmpty)
        try await db.write { db in try db.execute(sql: "DROP TRIGGER reject_model_price_dismissal") }

        await model.delete(id: old.id)
        #expect(model.errorKey == nil && !model.prices.contains { $0.id == old.id })
        await model.loadAndFill(providers: [config], targets: targets, refresh: true)
        #expect(!model.drafts.contains { $0.id == old.id })
        #expect(!model.prices.contains { $0.id == old.id })
        await model.restoreDeleted(providers: [config], targets: targets)
        #expect(model.prices.first { $0.id == old.id }?.inputPerMillion == 0.66)
        #expect(!model.hasDeletedModels && model.errorKey == nil)
    }

    @Test("A lookup in another view cannot recreate a deleted row even when the rate list was unchanged")
    func deletedRowRejectsLateLookup() async throws {
        let service = try pricePreferences(), gate = GatedPriceCatalog()
        let config = LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro")
        let old = ProductModelPrice(providerID: config.id, model: "moonshot-v1-8k")
        let targets = [priceTarget(config), old]
        let manual = ProductModelPrice(providerID: config.id, model: config.model, currency: "CNY", inputPerMillion: 2, outputPerMillion: 10)
        try await service.saveModelPrices([manual], replacing: [])
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in pricingFixture })
        await model.loadAndFill(providers: [config], targets: targets)
        let laterCatalog = Data(#"{"moonshotai-cn":{"api":"https://api.moonshot.cn/v1","models":{"moonshot-v1-8k":{"cost":{"input":1,"output":2}}}}}"#.utf8)
        let other = ProductCostModel(service: service, pricing: ModelPricingService { _ in
            _ = await gate.data()
            return laterCatalog
        })
        let lookup = Task { await other.loadAndFill(providers: [config], targets: targets, refresh: true) }
        await gate.waitUntilStarted()
        await model.delete(id: old.id)
        #expect(model.prices == [manual])
        await gate.finish()
        await lookup.value
        #expect(other.errorKey == "product.price.conflict")
        let saved = try await service.loadModelPrices()
        #expect(saved.prices == [manual] && saved.dismissedIDs == [old.id])
        await other.loadAndFill(providers: [config], targets: targets, refresh: true)
        #expect(!other.drafts.contains { $0.id == old.id })
    }

    @Test("New manual prices default to CNY while saved USD quotes retain their units")
    func defaultCNYKeepsSavedCurrency() {
        let target = ProductModelPrice(providerID: UUID(), model: "fixture")
        var draft = ProductModelPriceDraft(target: target, saved: nil)
        #expect(target.currency == "CNY" && draft.currency == "CNY")
        #expect(!draft.isEdited && draft.value == nil)
        draft.input = "1.5"; draft.output = "3"
        #expect(draft.value?.currency == "CNY")
        let quoted = ProductModelPrice(providerID: target.providerID, model: target.model, currency: "USD",
            inputPerMillion: 0.15, outputPerMillion: 0.6, source: .modelsDev)
        let saved = ProductModelPriceDraft(target: target, saved: quoted)
        #expect(saved.currency == "USD" && saved.value == quoted && !saved.isEdited)
    }

    @Test("Changing an endpoint invalidates fresh regional quotes and never applies them to a relay")
    func changedEndpoint() async throws {
        let service = try pricePreferences()
        var config = LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro")
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in pricingFixture })
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        let original = try #require(model.prices.first)
        #expect(original.inputPerMillion == 1.94)
        config.endpoint = "https://api.moonshot.ai/v1/chat/completions"
        #expect(!original.applies(to: config))
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        #expect(model.prices.first?.inputPerMillion == 2)
        config.endpoint = "https://relay.example/v1/chat/completions"
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        #expect(model.prices.isEmpty)
        #expect(model.drafts.first?.input == "")
        #expect(try await service.load([ProductModelPrice].self, key: "model-prices") == [])
    }

    @Test("Opening fills missing prices, retains manual currency, and leaves unlisted fields blank")
    func automaticFillAndManualPriority() async throws {
        let service = try pricePreferences()
        let configs = [
            LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "kimi-k3.1-pro"),
            LLMProviderConfig(name: "LM Studio", endpoint: "http://localhost:1234/v1/chat/completions", model: "local")
        ]
        let manual = ProductModelPrice(providerID: configs[0].id, model: configs[0].model, currency: "CNY", inputPerMillion: 5, outputPerMillion: 10)
        try await service.saveModelPrices([manual], replacing: [])
        let calls = CatalogCalls()
        let pricing = ModelPricingService { url in await calls.record(url); return pricingFixture }
        let model = ProductCostModel(service: service, pricing: pricing)
        await model.loadAndFill(providers: configs, targets: configs.map(priceTarget))
        #expect(model.prices.count == 2)
        #expect(model.prices.first { $0.id == manual.id } == manual)
        #expect(model.drafts.first { $0.model == "local" }?.input == "")
        #expect(!model.canSave)
        let reloaded = ProductCostModel(service: service, pricing: pricing)
        await reloaded.loadAndFill(providers: configs, targets: configs.map(priceTarget))
        #expect(reloaded.prices == model.prices)
        #expect(await calls.urls.count == 1)
        await model.loadAndFill(providers: configs, targets: configs.map(priceTarget), refresh: true)
        #expect(model.prices.first { $0.id == manual.id } == manual)
    }

    @Test("Typing during a fetch survives automatic persistence; saving never turns blank rows into free models")
    func editDuringFetch() async throws {
        let service = try pricePreferences(), gate = GatedPriceCatalog()
        let configs = [
            LLMProviderConfig(name: "Pro", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro"),
            LLMProviderConfig(name: "Flash", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash"),
            LLMProviderConfig(name: "Unlisted", endpoint: "https://api.deepseek.com/chat/completions", model: "unknown")
        ]
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in await gate.data() })
        let loading = Task { await model.loadAndFill(providers: configs, targets: configs.map(priceTarget)) }
        await gate.waitUntilStarted()
        let index = try #require(model.drafts.firstIndex { $0.model == "deepseek-v4-pro" })
        model.drafts[index].input = "9"
        model.drafts[index].output = "18"
        await gate.finish()
        await loading.value
        #expect(model.drafts[index].input == "9")
        #expect(model.prices.map(\.model) == ["deepseek-flash"])
        #expect(model.canSave)
        await model.save()
        let saved = try #require(try await service.load([ProductModelPrice].self, key: "model-prices"))
        #expect(saved.count == 2)
        #expect(saved.first { $0.model == "deepseek-v4-pro" }?.inputPerMillion == 9)
        #expect(saved.first { $0.model == "deepseek-v4-pro" }?.source == nil)
        #expect(saved.first { $0.model == "deepseek-flash" }?.source == .modelsDev)
        #expect(!model.canSave)
    }

    @Test("Leaving a page discards a late lookup; reopening retries an interrupted fetch")
    func invalidatedLookup() async throws {
        let service = try pricePreferences(), gate = GatedPriceCatalog()
        let config = LLMProviderConfig(name: "Pro", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro")
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in await gate.data() })
        let loading = Task { await model.loadAndFill(providers: [config], targets: [priceTarget(config)]) }
        await gate.waitUntilStarted()
        model.invalidate()
        loading.cancel()
        await gate.finish()
        await loading.value
        #expect(model.prices.isEmpty && !model.fetching)
        #expect(try await service.load([ProductModelPrice].self, key: "model-prices") == nil)
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        #expect(model.prices.first?.model == config.model)
    }

    @Test("Failed refresh retains old reference rates and reports a retryable failure")
    func failedRefresh() async throws {
        let service = try pricePreferences(), calls = CatalogCalls()
        let config = LLMProviderConfig(name: "Pro", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-pro")
        let old = ProductModelPrice(providerID: config.id, model: config.model, currency: "USD", inputPerMillion: 1, outputPerMillion: 2,
            source: .modelsDev, fetchedAt: Date(timeIntervalSince1970: 1_000))
        try await service.saveModelPrices([old], replacing: [])
        let model = ProductCostModel(service: service, pricing: ModelPricingService { url in
            await calls.record(url)
            throw URLError(.notConnectedToInternet)
        })
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        #expect(model.fetchFailed && model.prices == [old])
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)])
        #expect(await calls.urls.count == 1)
        await model.loadAndFill(providers: [config], targets: [priceTarget(config)], refresh: true)
        #expect(await calls.urls.count == 2)
        #expect(try await service.load([ProductModelPrice].self, key: "model-prices") == [old])
    }
}

private actor CatalogCalls {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private actor GatedPriceCatalog {
    private var pending: CheckedContinuation<Data, Never>?
    private var started = false
    private var released = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func data() async -> Data {
        if released { return pricingFixture }
        return await withCheckedContinuation { continuation in
            pending = continuation
            started = true
            let callbacks = watchers; watchers = []
            for watcher in callbacks { watcher.resume() }
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func finish() {
        released = true
        pending?.resume(returning: pricingFixture)
        pending = nil
    }
}

@Suite("Image cost accounting")
struct ImageCostAccountingTests {
    private func config(endpoint: String = "https://api.openai.com/v1/chat/completions",
                        model: String = "gpt-image-2.6-sunburst") -> LLMProviderConfig {
        .init(name: "Image provider", endpoint: endpoint, model: model)
    }

    @Test("Official image reference prices are dated, exact and never applied to a relay or an alias")
    func officialReferenceScope() async throws {
        let direct = config(), imageRoute = config(endpoint: "https://api.openai.com/v1/images/generations")
        let relay = config(endpoint: "https://relay.invalid/v1/chat/completions")
        let future = config(model: "gpt-image-2.6-sunburst-unknown")
        let calls = CatalogCalls()
        let service = ModelPricingService { url in await calls.record(url); return pricingFixture }
        let configs = [direct, imageRoute, relay, future]
        let result = try await service.prices(for: configs.map(priceTarget), providers: configs)
        #expect(Set(result.prices.map(\.providerID)) == [direct.id, imageRoute.id])
        let price = try #require(result.prices.first)
        #expect(price.source == .openAIReference && price.currency == "USD")
        #expect(price.imageRates == .init(textInputPerMillion: 5, imageInputPerMillion: 8, imageOutputPerMillion: 30,
                                        cachedTextInputPerMillion: 1.25, cachedImageInputPerMillion: 2))
        #expect(price.fetchedAt == Date(timeIntervalSince1970: 1_793_923_200))
        #expect(!price.applies(to: LLMProviderConfig(id: price.providerID, name: "moved", endpoint: relay.endpoint, model: price.model)))
        #expect(CloudProvider.billingManagementURL(endpoint: direct.endpoint)?.host == "platform.openai.com")
        #expect(CloudProvider.billingManagementURL(endpoint: relay.endpoint) == nil)
        #expect(CloudProvider.billingManagementURL(endpoint: "https://api.openai.com:8443/v1/chat/completions") == nil)
        #expect(!CloudProvider.supportsBalanceQuery(endpoint: direct.endpoint))
    }

    @Test("Modality pricing requires complete consistent usage and does not guess old image totals")
    func estimatesAndLegacy() throws {
        let provider = config()
        let price = try #require(ModelPricingService.openAIImageReference(priceTarget(provider), provider: provider))
        #expect(price.estimate(usage: .init(input: 1_000_000, output: 100_000,
            inputText: 200_000, inputImage: 800_000, outputImage: 100_000)) == 10.4)
        #expect(price.estimate(input: 1_000_000, output: 100_000) == nil)
        #expect(price.estimate(usage: .init(input: 50, output: 10)) == nil)
        #expect(price.estimate(usage: .init(input: 50, output: 10, inputText: 20, inputImage: 31, outputImage: 10)) == nil)
        #expect(price.estimate(usage: .init(input: 0, output: 0, inputText: 0, inputImage: 0, outputImage: 0)) == 0)
        let old = Data("{\"providerID\":\"\(provider.id.uuidString)\",\"model\":\"\(provider.model)\",\"currency\":\"USD\",\"inputPerMillion\":5,\"outputPerMillion\":30}".utf8)
        let legacy = try JSONDecoder().decode(ProductModelPrice.self, from: old)
        #expect(legacy.isValid && legacy.imageRates == nil && legacy.estimate(input: 50, output: 10) == nil)
    }

    @Test("Image details survive migration, receipts, backup and fixed-space cost queries")
    func persistenceAndCoverage() async throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        // Recreate the schema of a pre-image-breakdown store without deleting receipts.
        try await db.write { db in
            try db.execute(sql: "INSERT INTO provider_usage (id,model,source,startedAt,status,inputTokens,outputTokens) VALUES ('old-receipt','old-model','legacy',?, 'succeeded', 5, 2)", arguments: [Date(timeIntervalSince1970: 1)])
            for column in ["inputTextTokens", "inputImageTokens", "outputImageTokens"] {
                try db.execute(sql: "ALTER TABLE provider_usage DROP COLUMN \(column)")
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3_provider_usage_image_tokens'")
        }
        try DatabaseBootstrap.prepareSpace(db)
        let migrated = UsageService(databaseQueue: db)
        let old = try #require(try await migrated.exportRecords().first)
        #expect(old.id == "old-receipt" && old.usage.input == 5 && old.usage.inputText == nil)
        try await migrated.removeRestoredRecords([old.id])
        let provider = config(), usage = UsageService(databaseQueue: db)
        let price = try #require(ModelPricingService.openAIImageReference(priceTarget(provider), provider: provider))
        func record(_ id: String, text: Int?, image: Int?) -> ProviderUsageRecord {
            .init(id: id, sessionID: nil, providerID: provider.id.uuidString, providerName: "fixture", requestedModel: provider.model,
                  source: "chat", startedAt: Date(), finishedAt: Date(), status: "succeeded",
                  usage: .init(input: 100, output: 10, inputText: text, inputImage: image, outputImage: 10))
        }
        try await usage.importRecords([record("valid", text: 20, image: 80)])
        let initial = try await usage.costAccounting(prices: [price], providers: [provider])
        #expect(initial.amounts["USD"] == 0.00104 && initial.unknownGroups == 0)
        let stats = try await usage.getStats()
        #expect(stats.modelGroups.first?.completeImageRecords == 1)
        #expect(price.estimate(usage: try #require(stats.modelGroups.first?.imageUsage)) == 0.00104)
        let exported = try JSONEncoder().encode(try await usage.exportRecords())
        let second = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(second)
        let restored = UsageService(databaseQueue: second)
        try await restored.importRecords(JSONDecoder().decode([ProviderUsageRecord].self, from: exported))
        #expect(try await restored.exportRecords().first?.usage.inputImage == 80)
        #expect(try await restored.costAccounting(prices: [price], providers: [provider]).amounts == initial.amounts)
        let other = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(other)
        #expect(try await UsageService(databaseQueue: other).exportRecords().isEmpty)
        // These two invalid input splits cancel in aggregate; neither may count as complete.
        try await usage.importRecords([record("bad-over", text: 21, image: 80), record("bad-under", text: 19, image: 80)])
        let invalid = try await usage.costAccounting(prices: [price], providers: [provider])
        #expect(invalid.amounts.isEmpty && invalid.unknownGroups == 1)
        try await usage.importRecords([record("legacy", text: nil, image: nil)])
        #expect(try await usage.costAccounting(prices: [price], providers: [provider]).unknownGroups == 1)
    }

    @MainActor @Test("Manual image rates and drafts survive refresh without filling blanks as free rates")
    func manualRates() async throws {
        let provider = config(), service = try pricePreferences()
        let model = ProductCostModel(service: service, pricing: ModelPricingService { _ in pricingFixture })
        await model.loadAndFill(providers: [provider], targets: [priceTarget(provider)])
        let index = try #require(model.drafts.firstIndex { $0.model == provider.model })
        #expect(model.drafts[index].imageInput == "8.0")
        model.drafts[index].imageInput = "9"
        model.drafts[index].cachedImageInput = ""
        await model.save()
        let manual = try #require(model.prices.first)
        #expect(manual.source == nil && manual.imageRates?.imageInputPerMillion == 9)
        await model.loadAndFill(providers: [provider], targets: [priceTarget(provider)], refresh: true)
        #expect(model.prices == [manual])
        model.drafts[index].imageInput = ""
        #expect(!model.canSave)
        #expect(model.drafts[index].value == nil)
    }
}
