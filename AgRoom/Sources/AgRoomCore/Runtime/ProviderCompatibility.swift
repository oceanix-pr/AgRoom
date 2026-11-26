import Foundation

/// Wire decisions belong to the configured endpoint, not to a model's display name.
enum LLMWireProtocol: Sendable { case chatCompletions, responses, anthropicMessages }

extension CloudProvider {
    func wireProtocol(for config: LLMConfig) -> LLMWireProtocol {
        let url = URL(string: endpoint)
        let path = url?.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if path.hasSuffix("/responses") || path == "responses" { return .responses }
        if isAnthropic { return .anthropicMessages }
        // Gateways may expose a different subset of the API. Never rewrite their route
        // merely because they serve a similarly named model.
        let model = requestModel(config).lowercased()
        if url?.host?.lowercased() == "api.openai.com",
           path.hasSuffix("/chat/completions"),
           model.range(of: #"^(gpt-[5-9](?:[.\-]|$)|o[34](?:-|$))"#, options: .regularExpression) != nil {
            return .responses
        }
        return .chatCompletions
    }

    func requestModel(_ config: LLMConfig) -> String { config.modelName.isEmpty ? model : config.modelName }

    func requestEndpoint(for config: LLMConfig) -> String {
        guard wireProtocol(for: config) == .responses,
              var parts = URLComponents(string: endpoint) else { return endpoint }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard parts.path.lowercased().hasSuffix("/chat/completions") else { return endpoint }
        parts.path = String(parts.path.dropLast("chat/completions".count)) + "responses"
        return parts.string ?? endpoint
    }

    func outputTokenParameter(for config: LLMConfig) -> String {
        switch wireProtocol(for: config) {
        case .responses: return "max_output_tokens"
        case .anthropicMessages: return "max_tokens"
        case .chatCompletions:
            if let override = config.requestMaxTokenParameter,
               ["max_tokens", "max_completion_tokens"].contains(override) { return override }
            if let supported = config.modelCapabilities?.supportedParameters,
               supported.contains("max_completion_tokens"), !supported.contains("max_tokens") {
                return "max_completion_tokens"
            }
            if URL(string: endpoint)?.host?.lowercased() == "api.openai.com",
               requestModel(config).lowercased().range(of: #"^(o[1-9](?:-|$)|gpt-[5-9](?:[.\-]|$))"#, options: .regularExpression) != nil {
                return "max_completion_tokens"
            }
            return "max_tokens"
        }
    }

    func reasoningProfile(_ config: LLMConfig) -> ModelReasoningProfile {
        ModelReasoningProfile(endpoint: endpoint, model: requestModel(config), capabilities: config.modelCapabilities,
                              useQwenChatTemplate: config.useQwenChatTemplate)
    }

    func openAIReasoningLevel(_ config: LLMConfig) -> String? {
        let effort = config.reasoningEffort ?? (config.reasoningBudget == nil ? .standard : .deep)
        guard effort != .standard else { return nil }
        let profile = reasoningProfile(config)
        if profile.dialect == .gpt || profile.dialect == .kimi {
            let selected = profile.selection(effort)
            return selected == .standard ? nil : selected.rawValue
        }
        guard effort == .fast || effort == .deep else { return nil }
        if let level = config.reasoningLevel { return level }
        if let levels = config.modelCapabilities?.reasoningEfforts, !levels.isEmpty {
            let preferred = effort == .fast ? ["none", "minimal", "low"] : ["high", "max", "xhigh", "medium"]
            return preferred.first(where: levels.contains) ?? levels.first
        }
        if effort == .deep { return "high" }
        let name = requestModel(config).lowercased()
        if name.hasPrefix("gpt-5.") || (name.hasPrefix("gpt-6") && !name.contains("astra") && !name.contains("sol")) { return "none" }
        return name == "gpt-5" || name.hasPrefix("gpt-5-") ? "minimal" : "low"
    }

    func shouldSendTemperature(_ config: LLMConfig, omit: Bool = false) -> Bool {
        guard !omit, config.temperatureIsAutomatic != true, config.modelCapabilities?.supportsTemperature != false else { return false }
        let profile = reasoningProfile(config)
        if profile.usesProviderTemperature(at: config.reasoningEffort) { return false }
        let host = URL(string: endpoint)?.host?.lowercased()
        if host == "api.openai.com",
           !Self.allowsTemperature(model: requestModel(config)) {
            return openAIReasoningLevel(config) == "none"
        }
        return config.modelCapabilities?.supportsTemperature ?? Self.allowsTemperature(model: requestModel(config))
    }

    /// Only rejected HTTP requests are adapted. An SSE error/EOF is never replayed.
    /// Each correction is attempted once and each actual HTTP attempt gets its own receipt.
    func withRequestAdaptation<Value: Sendable>(config initial: LLMConfig,
        operation: (LLMConfig) async throws -> Value) async throws -> Value {
        var config = initial
        var corrected = Set<String>()
        while true {
            try Task.checkCancellation()
            do { return try await operation(config) }
            catch let error as LLMError {
                guard case .networkError(let status, let message) = error, status == 400 || status == 422 else { throw error }
                let lower = message.lowercased()
                if Self.isUnsupportedParameterMessage(message),
                   wireProtocol(for: config) == .chatCompletions,
                   !corrected.contains("tokenParameter") {
                    let current = outputTokenParameter(for: config)
                    let other = current == "max_tokens" ? "max_completion_tokens" : "max_tokens"
                    let rejected = Self.rejectedParameter(in: message)
                    if rejected == current || (rejected == nil && lower.contains(current) && lower.contains(other)) {
                        config.requestMaxTokenParameter = other
                        corrected.insert("tokenParameter")
                        continue
                    }
                }
                if !corrected.contains("tokenLimit"), let adapted = Self.adaptedMaxTokensConfig(error: error, config: config) {
                    config = adapted; corrected.insert("tokenLimit"); continue
                }
                if !corrected.contains("temperature"), config.temperatureIsAutomatic != true, Self.isTemperatureRejected(error) {
                    config.temperatureIsAutomatic = true; corrected.insert("temperature"); continue
                }
                if !corrected.contains("streamOptions"), config.requestOmitsStreamOptions != true,
                   wireProtocol(for: config) == .chatCompletions,
                   Self.isUnsupportedParameterMessage(message), lower.contains("stream_options") {
                    config.requestOmitsStreamOptions = true; corrected.insert("streamOptions"); continue
                }
                if Self.isUnsupportedParameterMessage(message) {
                    throw LLMError.unsupportedParameter(parameter: Self.rejectedParameter(in: message) ?? "request")
                }
                throw error
            }
        }
    }

    static func sseEvent(_ line: String) -> String? {
        guard line.hasPrefix("event:") else { return nil }
        return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    }

    static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    public static func isUnsupportedParameterMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unsupported_parameter") || lower.contains("unsupported parameter")
            || lower.contains("not supported") || lower.contains("unrecognized request argument")
            || lower.contains("unknown parameter")
    }

    public static func rejectedParameter(in message: String) -> String? {
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let param = error["param"] as? String {
            return String(param.prefix(80))
        }
        let pattern = #"(?i)(?:parameter|argument|value)[:\s]+['\"]?([a-z_][a-z_0-9]*(?:\.[a-z_][a-z_0-9]*)*)['\"]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[range].prefix(80))
    }

    public static func isOutputLimitMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["max_tokens", "max_completion_tokens", "max_output_tokens"].contains(where: lower.contains)
            && !isUnsupportedParameterMessage(message)
            && ["range", "maximum", "at most", "less than", "too large", "exceed", "must be <=", "must be ≤"].contains(where: lower.contains)
    }

    public static func isModelCapacityMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no available capacity") || lower.contains("server_is_overloaded")
            || lower.contains("model is overloaded")
    }
}
