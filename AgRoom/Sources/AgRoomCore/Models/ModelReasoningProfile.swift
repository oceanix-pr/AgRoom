import Foundation

/// The same model can expose different controls on a hosted API and a local server.
public struct ModelReasoningProfile: Sendable {
    enum Dialect: Sendable { case deepSeek, kimi, gpt, dashScope, chatTemplate, other }
    let dialect: Dialect
    public let offersChatTemplateSetting: Bool
    public let choices: [ReasoningEffort]
    public private(set) var defaultLevel: String?
    public let inputModalities: [String]?

    public init(endpoint: String, model: String, capabilities: ModelCapabilities? = nil,
                useQwenChatTemplate: Bool? = nil) {
        let url = URL(string: endpoint)
        let host = url?.host?.lowercased() ?? ""
        let official = url?.scheme?.lowercased() == "https" && (url?.port == nil || url?.port == 443)
        let name = model.lowercased()
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let qwen = last.hasPrefix("qwen3.6-") || last.hasPrefix("qwen3.6:")
        let chat = !(url?.path.lowercased().hasSuffix("/messages") ?? false)
            && !(url?.path.lowercased().hasSuffix("/responses") ?? false)
        let dashScope = official && ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com",
                                    "dashscope-us.aliyuncs.com"].contains(host)
        offersChatTemplateSetting = chat && qwen && !dashScope && host != "openrouter.ai"
        let declared = capabilities?.reasoningEfforts ?? []
        var supported: [ReasoningEffort]
        if official, host == "api.deepseek.com", chat,
           ["deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"].contains(name) {
            dialect = .deepSeek
            defaultLevel = "high"
            supported = [.off, .low, .high, .max]
        } else if official, ["api.moonshot.cn", "api.moonshot.ai"].contains(host), chat,
                  ["kimi-k3", "kimi-k3.1-pro", "kimi-k3.1-pro-highspeed"].contains(name) {
            dialect = .kimi
            defaultLevel = "max"
            supported = [.low, .high, .max]
        } else if official, host == "api.openai.com",
                  name.range(of: #"^gpt-6\.2-(?:sol|astra)(?:-\d{4}-\d{2}-\d{2})?$"#, options: .regularExpression) != nil {
            dialect = .gpt
            defaultLevel = nil
            supported = [.low, .medium, .high, .xhigh, .max]
        } else if chat, dashScope, qwen {
            dialect = .dashScope
            defaultLevel = "on"
            supported = [.off, .deep]
        } else if offersChatTemplateSetting, useQwenChatTemplate ?? (capabilities?.supportsChatTemplate == true) {
            dialect = .chatTemplate
            defaultLevel = "on"
            supported = [.off, .deep]
        } else {
            dialect = .other
            defaultLevel = nil
            supported = offersChatTemplateSetting && capabilities?.supportedParameters?.contains("reasoning_effort") != true ? [] : [.fast, .deep]
        }
        if [.gpt, .kimi, .deepSeek].contains(dialect), !declared.isEmpty {
            // DeepSeek advertises thinking levels separately from its off switch.
            supported = supported.filter { $0 == .off || declared.contains($0.rawValue) }
        }
        choices = capabilities?.supportsReasoning == false ? [.standard] : [.standard] + supported
        if capabilities?.supportsReasoning == false { defaultLevel = nil }
        if let declared = capabilities?.inputModalities, !declared.isEmpty {
            inputModalities = declared
        } else if dialect == .deepSeek {
            inputModalities = name == "deepseek-v4-pro" ? ["text"] : ["text", "image"]
        } else { inputModalities = nil }
    }

    public func selection(_ stored: ReasoningEffort?) -> ReasoningEffort {
        let effort = stored ?? .standard
        if choices.contains(effort) { return effort }
        if effort == .fast { return choices.contains(.off) ? .off : (choices.contains(.low) ? .low : .standard) }
        if effort == .deep { return choices.contains(.high) ? .high : .standard }
        return .standard
    }

    public func usesProviderTemperature(at effort: ReasoningEffort?) -> Bool {
        dialect == .kimi || dialect == .gpt || (dialect == .deepSeek && selection(effort) != .off)
    }
    public var usesThinkingOutputBudget: Bool { dialect == .kimi }
    public var isThinkingSwitch: Bool { dialect == .dashScope || dialect == .chatTemplate }

    func effectiveLevel(_ config: LLMConfig) -> String {
        if config.modelCapabilities?.supportsReasoning == false { return "off" }
        let effort = selection(config.reasoningEffort ?? (config.reasoningBudget == nil ? .standard : .deep))
        if effort == .standard { return defaultLevel ?? "standard" }
        if isThinkingSwitch && effort == .deep { return "on" }
        if dialect == .other, let level = config.reasoningLevel { return level }
        return effort.rawValue
    }
}
