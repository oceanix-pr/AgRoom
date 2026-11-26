import Foundation

/// Public, non-space model metadata. Missing values remain unknown, never unlimited.
public struct ModelCapabilities: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case provider, openRouter, modelsDev, providerAndCatalog }
    public var contextTokens: Int?
    public var outputTokens: Int?
    public var supportsTemperature: Bool?
    public var temperatureMinimum: Double?
    public var temperatureMaximum: Double?
    public var supportsReasoning: Bool?
    public var reasoningEfforts: [String]?
    public var supportedParameters: [String]?
    public var supportsReasoningBudget: Bool?
    public var supportsChatTemplate: Bool?
    public var inputModalities: [String]?
    public var conservativeRouting: Bool
    public var source: Source
    public var fetchedAt: Date

    public init(contextTokens: Int? = nil, outputTokens: Int? = nil,
                supportsTemperature: Bool? = nil, temperatureMinimum: Double? = nil,
                temperatureMaximum: Double? = nil, supportsReasoning: Bool? = nil,
                reasoningEfforts: [String]? = nil, supportsReasoningBudget: Bool? = nil, supportedParameters: [String]? = nil,
                conservativeRouting: Bool = false, source: Source = .provider, fetchedAt: Date = Date()) {
        self.contextTokens = contextTokens; self.outputTokens = outputTokens
        self.supportsTemperature = supportsTemperature
        self.temperatureMinimum = temperatureMinimum; self.temperatureMaximum = temperatureMaximum
        self.supportsReasoning = supportsReasoning; self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningBudget = supportsReasoningBudget
        self.supportedParameters = supportedParameters
        self.conservativeRouting = conservativeRouting; self.source = source; self.fetchedAt = fetchedAt
    }

    public var hasLimits: Bool {
        contextTokens != nil || outputTokens != nil || supportsTemperature != nil || supportsReasoning != nil
            || supportedParameters != nil || reasoningEfforts != nil || supportsReasoningBudget != nil
            || supportsChatTemplate != nil || inputModalities != nil
    }
    public var temperatureRange: ClosedRange<Double> {
        let lower = temperatureMinimum ?? 0, upper = temperatureMaximum ?? 2
        return min(lower, upper)...max(lower, upper)
    }

    func fillingUnknown(with reference: ModelCapabilities) -> ModelCapabilities {
        guard hasLimits else { return reference }
        var result = self
        result.contextTokens = contextTokens ?? reference.contextTokens
        result.outputTokens = outputTokens ?? reference.outputTokens
        result.supportsTemperature = supportsTemperature ?? reference.supportsTemperature
        result.temperatureMinimum = temperatureMinimum ?? reference.temperatureMinimum
        result.temperatureMaximum = temperatureMaximum ?? reference.temperatureMaximum
        result.supportsReasoning = supportsReasoning ?? reference.supportsReasoning
        result.reasoningEfforts = reasoningEfforts ?? reference.reasoningEfforts
        result.supportsReasoningBudget = supportsReasoningBudget ?? reference.supportsReasoningBudget
        result.supportedParameters = supportedParameters ?? reference.supportedParameters
        result.inputModalities = inputModalities ?? reference.inputModalities
        if result != self { result.source = .providerAndCatalog }
        return result
    }

    func constrained(_ config: LLMConfig, inputTokens: Int) throws -> LLMConfig {
        var result = config
        result.maxTokens = min(ModelParameterPreferences.outputTokenRange.upperBound, max(1, result.maxTokens))
        if let outputTokens { result.maxTokens = min(result.maxTokens, outputTokens) }
        if let contextTokens {
            let remaining = contextTokens - max(0, inputTokens) - 256
            guard remaining > 0 else { throw LLMError.contextBudgetExceeded }
            result.maxTokens = min(result.maxTokens, remaining)
        }
        if supportsTemperature == false { result.temperatureIsAutomatic = true }
        result.temperature = min(temperatureRange.upperBound, max(temperatureRange.lowerBound, result.temperature))
        if supportsReasoning == false { result.reasoningEffort = nil; result.reasoningBudget = nil }
        if let efforts = reasoningEfforts, !efforts.isEmpty, let effort = result.reasoningEffort, effort == .fast || effort == .deep {
            let preferred = effort == .fast ? ["none", "minimal", "low"] : ["high", "max", "xhigh", "medium"]
            result.reasoningLevel = preferred.first { efforts.contains($0) } ?? efforts.first
        }
        if let budget = result.reasoningBudget {
            result.reasoningBudget = supportsReasoningBudget == false || result.maxTokens <= 1_024
                ? nil : min(max(1_024, budget), result.maxTokens - 1)
        }
        return result
    }
}

/// A nil output preference follows the model's known limit. Other nil values use workflow or provider defaults.
public struct ModelParameterPreferences: Codable, Equatable, Sendable {
    public static let outputTokenRange = 256...1_048_576
    public static let defaultContextTokenBudget = 256_000
    public static let contextTokenBudgetRange = 4_096...1_048_576

    public var maxTokens: Int?
    public var temperature: Double?
    public var reasoningEffort: ReasoningEffort?
    public var reasoningBudget: Int?
    public var maxSteps: Int?
    public var subagentSteps: Int?
    public var historyWindow: Int?
    /// Local input ceiling, including system, history, tools and continuation data.
    public var contextTokenBudget: Int?
    public var promptCachePolicy: PromptCachePolicy?
    public var nativeCompactionEnabled: Bool?
    /// nil uses the serving engine's metadata. A manual choice is scoped to the exact endpoint/model.
    public var useQwenChatTemplate: Bool?

    public init(maxTokens: Int? = nil, temperature: Double? = nil, reasoningEffort: ReasoningEffort? = nil,
                reasoningBudget: Int? = nil, maxSteps: Int? = nil, subagentSteps: Int? = nil, historyWindow: Int? = nil,
                contextTokenBudget: Int? = nil, promptCachePolicy: PromptCachePolicy? = nil,
                nativeCompactionEnabled: Bool? = nil) {
        self.maxTokens = maxTokens; self.temperature = temperature; self.reasoningEffort = reasoningEffort
        self.reasoningBudget = reasoningBudget; self.maxSteps = maxSteps
        self.subagentSteps = subagentSteps; self.historyWindow = historyWindow
        self.contextTokenBudget = contextTokenBudget
        self.promptCachePolicy = promptCachePolicy
        self.nativeCompactionEnabled = nativeCompactionEnabled
    }

    public var isValid: Bool {
        (maxTokens.map { Self.outputTokenRange.contains($0) } ?? true)
        && (temperature.map { $0.isFinite && (0...2).contains($0) } ?? true)
        && (reasoningBudget.map { (1_024...1_048_575).contains($0) } ?? true)
        && (maxSteps.map { (2...200).contains($0) } ?? true)
        && (subagentSteps.map { (2...100).contains($0) } ?? true)
        && (historyWindow.map { (2...500).contains($0) } ?? true)
        && (contextTokenBudget.map { Self.contextTokenBudgetRange.contains($0) } ?? true)
    }

    /// Explicit task ceilings may be smaller than the editable preference range.
    /// Reserve the selected output budget and protocol margin within known model limits.
    static func constrainedContextBudget(_ requested: Int, config: LLMConfig) -> Int {
        let local = min(contextTokenBudgetRange.upperBound, max(1, requested))
        guard let context = config.modelCapabilities?.contextTokens else { return local }
        return min(local, max(1, context - config.reservedOutputTokens - 256))
    }

    public func resolved(mode: ChatMode, capabilities: ModelCapabilities?, provider: LLMProviderConfig? = nil) -> ResolvedModelParameters {
        let profile = ModelReasoningProfile(endpoint: provider?.endpoint ?? "", model: provider?.model ?? "",
            capabilities: capabilities, useQwenChatTemplate: useQwenChatTemplate)
        let workflowOutput = mode == .coding || profile.usesThinkingOutputBudget ? 16_384 : 8_192
        let fallbackOutput = capabilities?.contextTokens.map { min(workflowOutput, max(256, $0 / 4)) } ?? workflowOutput
        let automaticMaximum = CloudProvider.isImageGenerationModel(provider?.model ?? "") ? nil : capabilities?.outputTokens
        var config = LLMConfig(maxTokens: maxTokens ?? automaticMaximum ?? fallbackOutput,
                               temperature: temperature ?? (mode == .coding ? 0.2 : 0.7),
                               reasoningEffort: reasoningEffort)
        if maxTokens == nil, automaticMaximum != nil {
            config.automaticOutputReserve = fallbackOutput
        }
        config.temperatureIsAutomatic = temperature == nil
        config.useQwenChatTemplate = useQwenChatTemplate
        config.reasoningBudget = reasoningBudget
        config.modelCapabilities = capabilities
        config.promptCachePolicy = promptCachePolicy ?? (mode == .coding ? .automatic : .providerDefault)
        // Context accounting includes the actual system/tool/input content at the request boundary.
        if let output = capabilities?.outputTokens { config.maxTokens = min(config.maxTokens, output) }
        if let capabilities, let constrained = try? capabilities.constrained(config, inputTokens: 0) { config = constrained }
        let steps = maxSteps ?? (mode == .coding ? 60 : 20)
        let history = historyWindow ?? (mode == .coding ? 30 : 10)
        let inputBudget = Self.constrainedContextBudget(contextTokenBudget ?? Self.defaultContextTokenBudget, config: config)
        if (nativeCompactionEnabled ?? (mode == .coding)), inputBudget >= 4_000 {
            config.nativeCompactionThreshold = max(1_000, inputBudget / 2)
        }
        // DispatcherEngine subtracts the actual system, tools and current input before selecting history.
        return ResolvedModelParameters(config: config, maxSteps: steps, subagentSteps: subagentSteps ?? 8,
                                       historyWindow: history, historyTokenBudget: inputBudget, contextTokenBudget: inputBudget,
                                       workflowMode: mode)
    }
}

public struct ResolvedModelParameters: Codable, Equatable, Sendable {
    public var config: LLMConfig
    public var maxSteps: Int
    public var subagentSteps: Int
    public var historyWindow: Int
    public var historyTokenBudget: Int
    public var contextTokenBudget: Int
    public var providerID: UUID? = nil
    public var endpoint: String? = nil
    /// Internal, resolved per turn. Optional for snapshots written before automatic routing.
    public var workflowMode: ChatMode? = nil

    public init(config: LLMConfig, maxSteps: Int, subagentSteps: Int, historyWindow: Int, historyTokenBudget: Int,
                contextTokenBudget: Int = ModelParameterPreferences.defaultContextTokenBudget,
                providerID: UUID? = nil, endpoint: String? = nil, workflowMode: ChatMode? = nil) {
        self.config = config; self.maxSteps = maxSteps; self.subagentSteps = subagentSteps
        self.historyWindow = historyWindow; self.historyTokenBudget = historyTokenBudget
        self.contextTokenBudget = contextTokenBudget; self.providerID = providerID; self.endpoint = endpoint
        self.workflowMode = workflowMode
    }

    private enum CodingKeys: String, CodingKey {
        case config, maxSteps, subagentSteps, historyWindow, historyTokenBudget, contextTokenBudget, providerID, endpoint, workflowMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        config = try values.decode(LLMConfig.self, forKey: .config)
        maxSteps = try values.decode(Int.self, forKey: .maxSteps)
        subagentSteps = try values.decode(Int.self, forKey: .subagentSteps)
        historyWindow = try values.decode(Int.self, forKey: .historyWindow)
        historyTokenBudget = try values.decode(Int.self, forKey: .historyTokenBudget)
        // Old handoffs keep their original local ceiling instead of reading new preferences.
        contextTokenBudget = try values.decodeIfPresent(Int.self, forKey: .contextTokenBudget)
            ?? 60_000
        providerID = try values.decodeIfPresent(UUID.self, forKey: .providerID)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint)
        workflowMode = try values.decodeIfPresent(ChatMode.self, forKey: .workflowMode)
    }

    public func history(_ messages: [EngineMessage], tokenBudget: Int? = nil) -> [EngineMessage] {
        // Thinking signatures can bind the preceding messages. Let request validation fail
        // rather than rewriting that signed prefix to make it fit.
        if messages.contains(where: { $0.continuation?.containsThinkingBlocks == true }) { return messages }
        let budget = min(historyTokenBudget, max(0, tokenBudget ?? historyTokenBudget))
        var result: [EngineMessage] = [], used = 0
        for message in messages.suffix(historyWindow).reversed() {
            let cost = TokenEstimator.estimate(messages: [message])
            guard cost <= budget - used else { break }
            result.append(message); used += cost
        }
        return result.reversed()
    }
}
