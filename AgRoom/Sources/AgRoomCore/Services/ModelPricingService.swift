import Foundation
import CoreFoundation

public struct ModelPricingLookupResult: Sendable {
    public var prices: [ProductModelPrice]
    public var failedIDs: Set<String>

    public init(prices: [ProductModelPrice] = [], failedIDs: Set<String> = []) {
        self.prices = prices
        self.failedIDs = failedIDs
    }
}

/// Reads public price catalogs. No credentials, prompts, usage or model selections
/// are sent to these services; matching happens locally against the full catalog.
public struct ModelPricingService: Sendable {
    private let fetch: @Sendable (URL) async throws -> Data
    static let maximumBytes = 16 * 1024 * 1024

    public init() {
        self.fetch = { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: PricingRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AgRoom/1.0", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LLMError.networkError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "Price catalog unavailable")
            }
            guard response.expectedContentLength <= Self.maximumBytes else { throw LLMError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw LLMError.responseTooLarge }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        }
    }

    /// Deterministic transport injection; production always uses the public URLs above.
    public init(fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.fetch = fetch
    }

    public func prices(for targets: [ProductModelPrice], providers: [LLMProviderConfig], at date: Date = Date()) async throws -> ModelPricingLookupResult {
        let configs = providers.reduce(into: [UUID: LLMProviderConfig]()) { $0[$1.id] = $1 }
        // Official image prices need modality rates not represented by the ordinary
        // catalogs. A dated, source-linked reference snapshot is a fallback only for
        // the exact public OpenAI origin/model; never for relays or unknown aliases.
        let references = targets.compactMap { target in
            configs[target.providerID].flatMap { Self.openAIImageReference(target, provider: $0) }
        }
        let referenceIDs = Set(references.map(\.id))
        var grouped: [ProductModelPrice.Source: [ProductModelPrice]] = [:]
        for target in targets where !target.model.isEmpty && !referenceIDs.contains(target.id) {
            guard let config = configs[target.providerID], let base = Self.endpointBase(config.endpoint) else { continue }
            let source: ProductModelPrice.Source = base == "https://openrouter.ai/api/v1" ? .openRouter : .modelsDev
            grouped[source, default: []].append(target)
        }
        let result = await withTaskGroup(of: ModelPricingLookupResult.self) { group in
            for (source, values) in grouped {
                group.addTask {
                    do {
                        let data = try await fetch(source.url)
                        guard data.count <= Self.maximumBytes else { throw LLMError.responseTooLarge }
                        let prices = try Self.parse(data: data, source: source, targets: values, providers: configs, at: date)
                        return ModelPricingLookupResult(prices: prices)
                    } catch {
                        return ModelPricingLookupResult(failedIDs: Set(values.map(\.id)))
                    }
                }
            }
            var result = ModelPricingLookupResult()
            for await value in group {
                result.prices += value.prices
                result.failedIDs.formUnion(value.failedIDs)
            }
            return result
        }
        try Task.checkCancellation()
        return ModelPricingLookupResult(prices: result.prices + references, failedIDs: result.failedIDs)
    }

    static func parse(data: Data, source: ProductModelPrice.Source, targets: [ProductModelPrice],
                      providers: [UUID: LLMProviderConfig], at date: Date) throws -> [ProductModelPrice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.responseParsingFailed(reason: "Invalid price catalog")
        }
        var routerModels: [String: [String: Any]] = [:]
        if source == .openRouter {
            guard let items = root["data"] as? [[String: Any]] else {
                throw LLMError.responseParsingFailed(reason: "Invalid model prices")
            }
            for item in items {
                if let id = item["id"] as? String { routerModels[id] = item }
            }
        }
        return targets.compactMap { target in
            guard let config = providers[target.providerID], let base = endpointBase(config.endpoint) else { return nil }
            let input: Double?, output: Double?
            // A flat text quote cannot stand in for an image modality tariff.
            guard !CloudProvider.isImageGenerationModel(target.model) else { return nil }
            switch source {
            case .openAIReference: return nil
            case .openRouter:
                guard base == "https://openrouter.ai/api/v1",
                      let pricing = routerModels[target.model]?["pricing"] as? [String: Any] else { return nil }
                // OpenRouter quotes USD per token; -1 denotes variable pricing.
                // Per-request fees cannot be represented by the ordinary token estimator.
                if let requestFee = pricing["request"], number(requestFee) != 0 { return nil }
                input = number(pricing["prompt"]).map { $0 * 1_000_000 }
                output = number(pricing["completion"]).map { $0 * 1_000_000 }
            case .modelsDev:
                guard let provider = catalogProvider(in: root, base: base),
                      let models = provider["models"] as? [String: Any],
                      let model = models[target.model] as? [String: Any],
                      let cost = model["cost"] as? [String: Any] else { return nil }
                // models.dev's v1 catalog quotes ordinary USD per million tokens.
                input = number(cost["input"])
                output = number(cost["output"])
            }
            guard let input, let output else { return nil }
            let price = ProductModelPrice(providerID: target.providerID, model: target.model, currency: "USD",
                inputPerMillion: input, outputPerMillion: output, source: source, fetchedAt: date, sourceEndpoint: base)
            return price.isValid ? price : nil
        }
    }

    /// Verified against the linked official pricing page on 2026-11-06.
    /// Keep the verification date fixed: displaying this snapshot must not pretend
    /// a live price refresh succeeded. Unknown versions remain unknown.
    static func openAIImageReference(_ target: ProductModelPrice, provider: LLMProviderConfig) -> ProductModelPrice? {
        guard endpointBase(provider.endpoint) == "https://api.openai.com/v1",
              ["gpt-image-2.6-sunburst", "gpt-image-2.6-flare", "gpt-image-2.5-sunburst", "gpt-image-2.5-flare"].contains(target.model) else { return nil }
        let rates = ProductImageTokenPrices(textInputPerMillion: 5, imageInputPerMillion: 8,
            imageOutputPerMillion: 30, cachedTextInputPerMillion: 1.25, cachedImageInputPerMillion: 2)
        return ProductModelPrice(providerID: target.providerID, model: target.model, currency: "USD",
            inputPerMillion: rates.textInputPerMillion, outputPerMillion: rates.imageOutputPerMillion,
            source: .openAIReference, fetchedAt: Date(timeIntervalSince1970: 1793923200),
            sourceEndpoint: "https://api.openai.com/v1", imageRates: rates)
    }

    static func catalogProvider(in root: [String: Any], base: String) -> [String: Any]? {
        // Native SDK providers omit `api`. These aliases cover documented official
        // API origins only; a relay with the same model ID must use its own prices.
        let native: [String: String] = [
            "https://api.openai.com/v1": "openai",
            "https://api.anthropic.com/v1": "anthropic",
            "https://api.deepseek.com/v1": "deepseek"
        ]
        if let id = native[base] { return root[id] as? [String: Any] }
        let matches = root.values.compactMap { $0 as? [String: Any] }.filter {
            guard let api = $0["api"] as? String else { return false }
            return canonicalBase(api) == base
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Preserve the service path as well as origin: regional endpoints and coding
    /// subscriptions may have different tariffs. Never match by display name.
    static func endpointBase(_ endpoint: String) -> String? {
        let normalized = CloudProvider.normalizedEndpoint(endpoint)
        guard var components = URLComponents(string: normalized) else { return nil }
        for suffix in ["/chat/completions", "/messages", "/responses", "/completions", "/images/generations", "/images/edits"] where components.path.hasSuffix(suffix) {
            components.path.removeLast(suffix.count)
            return canonicalBase(components.string ?? "")
        }
        return nil
    }

    private static func canonicalBase(_ value: String) -> String? {
        guard var url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        url.scheme = "https"; url.host = host
        if url.port == 443 { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        return url.string
    }

    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

private final class PricingRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(allowed ? request : nil)
    }
}
