import Foundation

// MARK: - LLM Config

/// 思考力度：快速=不思考（提供方支持时关闭），标准=提供方默认，深入=高强度思考
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case fast
    case standard
    case deep
    case off, low, medium, high, xhigh, max
}

/// 单次请求的生成参数
public struct LLMConfig: Codable, Equatable, Sendable {
    public var modelName: String
    public var maxTokens: Int
    /// Automatic replies may use the rest of the context after the input is known.
    /// Keep the workflow's usual reply allowance for history planning and thinking defaults.
    /// Fixed caps and older run snapshots reserve their full maxTokens.
    var automaticOutputReserve: Int?
    var reservedOutputTokens: Int { max(1, min(automaticOutputReserve ?? maxTokens, maxTokens)) }
    public var temperature: Double
    public var systemPrompt: String?
    /// 思考力度（nil/standard = 不干预，提供方默认）
    public var reasoningEffort: ReasoningEffort?
    /// Optional fields preserve old run snapshots. Automatic temperature omits the API parameter.
    public var temperatureIsAutomatic: Bool? = nil
    public var reasoningLevel: String? = nil
    public var reasoningBudget: Int? = nil
    public var useQwenChatTemplate: Bool? = nil
    public var modelCapabilities: ModelCapabilities? = nil
    public var promptCachePolicy: PromptCachePolicy? = nil
    public var nativeCompactionThreshold: Int? = nil
    // Per-attempt compatibility corrections; absent in older persisted snapshots.
    var requestMaxTokenParameter: String? = nil
    var requestOmitsStreamOptions: Bool? = nil
    /// Keep schemas bound to signed continuation while preventing new calls in terminal replies.
    var requestToolChoiceNone: Bool? = nil

    public init(
        modelName: String = "",
        maxTokens: Int = 2048,
        temperature: Double = 0.7,
        systemPrompt: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.reasoningEffort = reasoningEffort
    }

    public static let `default` = LLMConfig()
}

// MARK: - Provider Config

/// LLM 提供者配置（全局共享；API Key 不入本结构，仅存 Keychain）
public struct LLMProviderConfig: Codable, Identifiable, Equatable, Sendable {
    public static let maxAliasLength = 20
    public let id: UUID
    public var name: String
    /// A display-only label; model requests always use `model`.
    public var alias: String {
        didSet { alias = Self.normalizedAlias(alias) }
    }
    public var endpoint: String
    public var model: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        model: String,
        isEnabled: Bool = true,
        alias: String = ""
    ) {
        self.id = id
        self.name = name
        self.alias = Self.normalizedAlias(alias)
        self.endpoint = endpoint
        self.model = model
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }

    public var chatDisplayName: String {
        alias.isEmpty ? (model.isEmpty ? name : name + " · " + model) : alias
    }

    public static func normalizedAlias(_ value: String) -> String {
        let singleLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(singleLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxAliasLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case id, name, alias, endpoint, model, isEnabled, createdAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        alias = Self.normalizedAlias(try values.decodeIfPresent(String.self, forKey: .alias) ?? "")
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    /// 是否为 Anthropic 原生协议
    public var isAnthropic: Bool {
        let url = URL(string: endpoint)
        let host = url?.host?.lowercased() ?? ""
        let path = url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() ?? ""
        if path == "responses" || path.hasSuffix("/responses") || path.hasSuffix("/chat/completions") { return false }
        return host == "anthropic.com" || host.hasSuffix(".anthropic.com")
            || path == "messages" || path.hasSuffix("/messages")
    }
}

// MARK: - Provider Balance

/// 提供方账户余额（实时查询，不落盘）
///
/// 金额保留提供方返回的原始字符串，避免浮点精度损失，展示时按 `currency` 加符号。
/// `ItemLabel` 是跨厂商统一语义：DeepSeek 的 `granted/topped_up` 与 Kimi 的
/// `voucher/cash` 分别归入 `.granted` 与 `.toppedUp`。
public struct ProviderBalance: Sendable, Equatable {

    /// 余额明细项语义（跨厂商统一）
    public enum ItemLabel: Sendable, Equatable {
        /// 总可用余额
        case total
        /// 赠金 / 代金券余额
        case granted
        /// 充值 / 现金余额
        case toppedUp
    }

    public struct Item: Sendable, Equatable {
        public let label: ItemLabel
        public let amount: String
        /// 币种（CNY / USD）
        public let currency: String

        public init(label: ItemLabel, amount: String, currency: String) {
            self.label = label
            self.amount = amount
            self.currency = currency
        }
    }

    /// 余额是否足以继续调用 API
    public let isAvailable: Bool
    public let items: [Item]

    public init(isAvailable: Bool, items: [Item]) {
        self.isAvailable = isAvailable
        self.items = items
    }

    /// 总可用余额项（用于主展示）
    public var total: Item? {
        items.first { $0.label == .total }
    }
}

// MARK: - LLM Error

public enum LLMError: LocalizedError {
    case providerUnavailable
    case invalidAPIKey
    case rateLimited
    case configurationError(reason: String)
    /// Tool definitions are checked before HTTP; field identifies the incompatible schema location.
    case invalidToolSchema(toolName: String, field: String)
    case unsupportedParameter(parameter: String)
    case networkError(statusCode: Int, message: String)
    /// 模型不支持图片输入（400 "This model does not support image"）
    case imageUnsupported
    case responseTooLarge
    case contextBudgetExceeded
    case responseParsingFailed(reason: String)
    /// 流式连接静默超时（看门狗）：连续 N 秒未收到任何数据，判定连接已死。
    /// URLSession 超时放宽到 1 小时后，靠它兜底在分钟级发现断连
    case streamStalled(seconds: Int)
    /// 流式响应在协议完成标记到达前结束（异常 EOF）：连接被中途关闭或网关截断。
    /// 携带已累积的正文字符数——增量可能已外发给 UI，上层据此避免盲目重试导致内容重复
    case streamIncomplete(partialCharacters: Int)
    /// 该提供方未开放余额查询接口（当前支持 DeepSeek、Kimi）
    case balanceUnsupported
    /// 提供方没有返回标准 tool_calls，正文只剩工具调用标记（常见于本地模型
    /// 的 XML 模板与 OpenAI 兼容流解析不匹配）。必须失败关闭，不能当最终回答。
    case unparsedToolCall
    /// 带工具的执行请求里，模型只产出了推理内容（正文为空且由推理回填），
    /// 也没有发起任何工具调用：这是「准备做但没做」的内部计划，
    /// 不能当作最终回答结束，必须显式标记未完成。
    case reasoningOnlyResponse
    /// 协议不一致：结束原因声明了工具调用（finish_reason = tool_calls），
    /// 但实际没有解析到任何工具调用。
    case toolCallFinishMismatch

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "The model response exceeded local resource limits. Reduce the requested output and retry."
        case .contextBudgetExceeded: return "The request exceeds the local context budget. Reduce project context or enabled tools and continue in a new conversation. File changes are preserved."
        case .providerUnavailable:
            return "No LLM provider available. Please configure one in Settings."
        case .invalidAPIKey:
            return "Invalid API key. Please check your key in Settings."
        case .rateLimited:
            return "Rate limited by the provider. Please try again later."
        case .configurationError(let reason):
            return "Configuration error: \(reason)"
        case .invalidToolSchema(let toolName, let field):
            return "Tool '\(toolName)' has an invalid or incompatible parameter schema at \(field). Update the app or disable the external tool and retry."
        case .unsupportedParameter(let parameter):
            return "The model endpoint does not support parameter \(parameter). Check the provider protocol or choose a compatible model."
        case .networkError(let statusCode, let message):
            return Self.friendlyNetworkError(statusCode: statusCode, message: message)
        case .imageUnsupported:
            return "当前模型不支持图像输入：请移除图片后重试，或在「设置 → 模型服务」切换到支持视觉的模型（如 GPT-4o、Qwen-VL、Claude）。"
        case .responseParsingFailed(let reason):
            return "Failed to parse response: \(reason)"
        case .streamStalled(let seconds):
            return "连接已静默 \(seconds) 秒且无任何数据到达，判定为断连。请检查网络后重试；若频繁出现，请检查服务方状态。"
        case .streamIncomplete(let partialCharacters):
            let partial = partialCharacters > 0
                ? "已收到约 \(partialCharacters) 个字符的部分内容，可能不完整。"
                : ""
            return "响应流在完成前中断，模型未返回完整的结束标记。\(partial)请重试。"
        case .balanceUnsupported:
            return "该提供方未开放余额查询接口（当前支持 DeepSeek、Kimi）。"
        case .unparsedToolCall:
            return "模型返回了未解析的工具调用：提供方没有返回标准的 tool_calls，正文里只剩工具调用标记。"
                + "请重试；若反复出现，请检查模型/提供方的工具调用模板，或切换到支持 OpenAI 工具调用的模型。"
        case .reasoningOnlyResponse:
            return "任务未完成：模型只输出了推理内容（内部计划），既没有最终回答也没有发起工具调用。"
                + "请重试，或切换到工具调用支持更稳定的模型。"
        case .toolCallFinishMismatch:
            return "协议异常：模型声称要调用工具（finish_reason = tool_calls），但没有返回任何工具调用。"
                + "本轮未执行任何操作，请重试。"
        }
    }

    /// 常见提供方错误的友好中文提示（错误码 + 建议），
    /// 未覆盖的错误保留原始格式（状态码 + 提供方消息）
    private static func friendlyNetworkError(statusCode: Int, message: String) -> String {
        let lower = message.lowercased()
        switch statusCode {
        case 400:
            if CloudProvider.isOutputLimitMessage(message) {
                return "Output token budget exceeds the model limit. Lower the reply budget in Settings → Model Services and retry."
            }
            if lower.contains("image") && (lower.contains("not support") || lower.contains("unsupported")) {
                return "当前模型不支持图像输入：请移除图片后重试，或在「设置 → 模型服务」切换到支持视觉的模型（如 GPT-4o、Qwen-VL、Claude）。"
            }
            return "Request failed (\(statusCode)): \(message)"
        case 401, 403:
            return "请求失败（密钥无效或已过期）：请前往「设置 → 模型服务」检查 API Key 是否正确。\n原始错误：\(message)"
        case 402:
            if lower.contains("balance") || lower.contains("余额") || lower.contains("arrears") || lower.contains("欠费") {
                return "请求失败（余额不足）：模型服务账户余额已耗尽，请前往提供方控制台充值后重试。\n原始错误：\(message)"
            }
            return "请求失败 (402)：\(message)"
        case 429:
            if lower.contains("quota") {
                return "请求失败（配额用尽）：当前 API Key 的调用配额已用完，请检查提供方后台的配额限制。\n原始错误：\(message)"
            }
            return "请求失败（请求过于频繁）：提供方已限流，请稍等片刻再重试。\n原始错误：\(message)"
        case 500...599:
            return "请求失败（服务端错误 \(statusCode)）：提供方服务暂时异常，请稍后重试。\n原始错误：\(message)"
        default:
            return "Request failed (\(statusCode)): \(message)"
        }
    }
}
