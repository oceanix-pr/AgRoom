import Foundation

public struct ProductTaskBudget: Codable, Equatable, Sendable {
    public var enabled = false
    public var maxTokens = 200_000
    public var maxToolCalls = 100
    public var minutes = 15
    public init() {}

    public var normalized: ProductTaskBudget {
        var value = self
        value.maxTokens = min(max(1_000, maxTokens), 5_000_000)
        value.maxToolCalls = min(max(1, maxToolCalls), 1_000)
        value.minutes = min(max(1, minutes), 240)
        return value
    }

    public func checkpoint(now: Date = Date()) -> ExecutionBudgetCheckpoint? {
        guard enabled else { return nil }
        let limits = normalized
        return ExecutionBudgetCheckpoint(maxTokens: limits.maxTokens, maxToolCalls: limits.maxToolCalls,
            spentTokens: 0, toolCalls: 0, deadline: now.addingTimeInterval(Double(limits.minutes) * 60))
    }
}

public struct ProductModelPrice: Codable, Equatable, Identifiable, Sendable {
    public static let defaultCurrency = "CNY"

    public enum Source: String, Codable, Sendable {
        case modelsDev, openRouter, openAIReference

        public var url: URL {
            switch self {
            case .modelsDev: URL(string: "https://models.dev/api.json")!
            case .openRouter: URL(string: "https://openrouter.ai/api/v1/models")!
            case .openAIReference: URL(string: "https://developers.openai.com/api/docs/pricing")!
            }
        }

        public var name: String {
            switch self {
            case .modelsDev: "Models.dev"
            case .openRouter: "OpenRouter"
            case .openAIReference: "OpenAI"
            }
        }
    }

    public var providerID: UUID
    public var model: String
    public var currency: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    /// Absent on legacy flat rates; image costs require an explicit modality tariff.
    public var imageRates: ProductImageTokenPrices?
    /// Absent on manually configured and legacy rates. Catalog prices are reference
    /// rates, not account-specific billing or historical price snapshots.
    public var source: Source?
    public var fetchedAt: Date?
    public var sourceEndpoint: String?
    public var id: String { providerID.uuidString + ":" + model }

    public init(providerID: UUID, model: String, currency: String = ProductModelPrice.defaultCurrency, inputPerMillion: Double = 0, outputPerMillion: Double = 0,
                source: Source? = nil, fetchedAt: Date? = nil, sourceEndpoint: String? = nil, imageRates: ProductImageTokenPrices? = nil) {
        self.providerID = providerID; self.model = model; self.currency = currency
        self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion
        self.imageRates = imageRates
        self.source = source; self.fetchedAt = fetchedAt
        self.sourceEndpoint = sourceEndpoint
    }

    public var isValid: Bool {
        ["USD", "CNY", "EUR"].contains(currency) && !model.isEmpty
            && inputPerMillion.isFinite && outputPerMillion.isFinite
            && (imageRates?.isValid ?? true)
            && (0...1_000_000).contains(inputPerMillion) && (0...1_000_000).contains(outputPerMillion)
    }

    /// A freshly cached regional or direct-API quote cannot follow a configuration
    /// that has since been moved to a different service or subscription endpoint.
    public func applies(to provider: LLMProviderConfig) -> Bool {
        guard providerID == provider.id else { return false }
        guard source != nil, let sourceEndpoint else { return true }
        return sourceEndpoint == ModelPricingService.endpointBase(provider.endpoint)
    }

    /// Images require a complete, consistent modality breakdown; old totals cannot
    /// be assigned to a cheaper modality. Cache discounts remain uninferred.
    public func estimate(usage: ProviderTokenUsage) -> Double? {
        guard imageRates != nil || CloudProvider.isImageGenerationModel(model) else {
            return estimate(input: usage.input, output: usage.output)
        }
        guard isValid, let rates = imageRates, usage.hasCompleteImageTokenCounts,
              let text = usage.inputText, let image = usage.inputImage, let output = usage.outputImage else { return nil }
        return (Double(text) * rates.textInputPerMillion + Double(image) * rates.imageInputPerMillion
            + Double(output) * rates.imageOutputPerMillion) / 1_000_000
    }

    /// At configured ordinary rates; unknown usage stays unknown. No cache discount,
    /// tax or currency conversion is guessed.
    public func estimate(input: Int?, output: Int?) -> Double? {
        guard imageRates == nil, !CloudProvider.isImageGenerationModel(model),
              isValid, let input, let output, input >= 0, output >= 0 else { return nil }
        return (Double(input) * inputPerMillion + Double(output) * outputPerMillion) / 1_000_000
    }
}

/// Ordinary (uncached) rates by modality. Cached reference rates are displayed,
/// but a discount is never inferred from an aggregate cache count.
public struct ProductImageTokenPrices: Codable, Equatable, Sendable {
    public var textInputPerMillion: Double
    public var imageInputPerMillion: Double
    public var imageOutputPerMillion: Double
    public var cachedTextInputPerMillion: Double?
    public var cachedImageInputPerMillion: Double?

    public init(textInputPerMillion: Double, imageInputPerMillion: Double, imageOutputPerMillion: Double,
                cachedTextInputPerMillion: Double? = nil, cachedImageInputPerMillion: Double? = nil) {
        self.textInputPerMillion = textInputPerMillion; self.imageInputPerMillion = imageInputPerMillion
        self.imageOutputPerMillion = imageOutputPerMillion
        self.cachedTextInputPerMillion = cachedTextInputPerMillion; self.cachedImageInputPerMillion = cachedImageInputPerMillion
    }
    public var isValid: Bool {
        [textInputPerMillion, imageInputPerMillion, imageOutputPerMillion,
         cachedTextInputPerMillion, cachedImageInputPerMillion].compactMap { $0 }
            .allSatisfy { $0.isFinite && (0...1_000_000).contains($0) }
    }
}
