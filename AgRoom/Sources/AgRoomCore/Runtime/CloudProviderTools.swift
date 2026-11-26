import Foundation

// MARK: - Observed generation speed

public struct TokenGenerationRate: Sendable, Equatable {
    public let outputTokens: Int
    public let seconds: Double
    public let isEstimated: Bool
    public var tokensPerSecond: Double { Double(outputTokens) / seconds }
}

public struct StreamGenerationEvent: Sendable {
    public enum Phase: Sendable { case started, streaming, finished }
    public let requestID: UUID
    public let phase: Phase
    public let estimatedOutputTokens: Int
    public let reportedOutputTokens: Int?
    public let seconds: Double
    public let samples: Int

    var rate: TokenGenerationRate? {
        let tokens = reportedOutputTokens ?? estimatedOutputTokens
        // A single buffered packet has no measurable generation interval.
        guard samples > 1, seconds >= 0.1, seconds.isFinite, tokens > 0 else { return nil }
        return TokenGenerationRate(outputTokens: tokens, seconds: seconds, isEstimated: reportedOutputTokens == nil)
    }
}

public struct GenerationMetricsSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let current: TokenGenerationRate?
    public let average: TokenGenerationRate?
}

/// Owned by the engine's state lock. The published snapshot includes the running
/// aggregate, so an out-of-order MainActor delivery cannot lose an earlier request.
struct GenerationMetricsAccumulator {
    private var revision: UInt64 = 0
    private var tokens = 0
    private var seconds = 0.0
    private var estimated = false
    private var finishedRequests: Set<UUID> = []
    private var current: TokenGenerationRate?

    var snapshot: GenerationMetricsSnapshot {
        GenerationMetricsSnapshot(revision: revision, current: current,
            average: seconds > 0 ? TokenGenerationRate(outputTokens: tokens, seconds: seconds, isEstimated: estimated) : nil)
    }

    mutating func accept(_ event: StreamGenerationEvent) {
        revision &+= 1
        switch event.phase {
        case .started: current = nil
        case .streaming: current = event.rate
        case .finished:
            current = nil
            guard finishedRequests.insert(event.requestID).inserted, let rate = event.rate else { return }
            tokens += rate.outputTokens
            seconds += rate.seconds
            estimated = estimated || rate.isEstimated
        }
    }
}

/// One tracker per actual HTTP attempt. Only scalar counts and monotonic times
/// are retained; callbacks run outside the lock and UI updates are throttled.
final class StreamGenerationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID = UUID()
    private let onMetrics: @Sendable (StreamGenerationEvent) -> Void
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var lastPublished: ContinuousClock.Instant?
    private var ascii = 0
    private var wide = 0
    private var samples = 0
    private var finished = false

    init(onMetrics: @escaping @Sendable (StreamGenerationEvent) -> Void) {
        self.onMetrics = onMetrics
        onMetrics(StreamGenerationEvent(requestID: requestID, phase: .started,
            estimatedOutputTokens: 0, reportedOutputTokens: nil, seconds: 0, samples: 0))
    }

    func observe(_ text: String, at now: ContinuousClock.Instant = .now) {
        guard !text.isEmpty else { return }
        var addedASCII = 0, addedWide = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { addedASCII += 1 } else { addedWide += 1 }
        }
        let event: StreamGenerationEvent? = lock.withLock {
            guard !finished else { return nil }
            ascii += addedASCII; wide += addedWide; samples += 1
            if first == nil { first = now }
            last = now
            if let published = lastPublished, published.duration(to: now) < .milliseconds(500) { return nil }
            lastPublished = now
            return makeEvent(.streaming, outputTokens: nil)
        }
        if let event { onMetrics(event) }
    }

    func finish(outputTokens: Int?) {
        let event: StreamGenerationEvent? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return makeEvent(.finished, outputTokens: outputTokens)
        }
        if let event { onMetrics(event) }
    }

    private func makeEvent(_ phase: StreamGenerationEvent.Phase, outputTokens: Int?) -> StreamGenerationEvent {
        let elapsed = first.flatMap { start in last.map { start.duration(to: $0).components } }
        let seconds = elapsed.map { Double($0.seconds) + Double($0.attoseconds) / 1e18 } ?? 0
        // Match TokenEstimator without rounding every SSE fragment separately.
        return StreamGenerationEvent(requestID: requestID, phase: phase, estimatedOutputTokens: ascii / 4 + wide,
            reportedOutputTokens: outputTokens, seconds: seconds, samples: samples)
    }
}

// MARK: - Engine Message Types

/// Provider-owned continuation data. Never display as answer text or rewrite during compaction.
public struct EngineContinuation: Codable, Sendable, Equatable {
    public let reasoningContent: String?
    public let alternateReasoning: String?
    /// Ordered Anthropic content blocks, including opaque signatures and redacted thinking.
    public let anthropicBlocksJSON: String?

    /// Ordered Responses output, including encrypted reasoning and function call IDs.
    public let responsesItemsJSON: String?

    public init(reasoningContent: String? = nil, anthropicBlocksJSON: String? = nil, responsesItemsJSON: String? = nil,
                alternateReasoning: String? = nil) {
        self.reasoningContent = reasoningContent
        self.alternateReasoning = alternateReasoning
        self.anthropicBlocksJSON = anthropicBlocksJSON
        self.responsesItemsJSON = responsesItemsJSON
    }

    var containsThinkingBlocks: Bool {
        if let raw = responsesItemsJSON {
            guard let items = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return true }
            if items.contains(where: { ["reasoning", "compaction"].contains($0["type"] as? String ?? "") }) { return true }
        }
        guard let raw = anthropicBlocksJSON else { return false }
        guard let blocks = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return true }
        return blocks.contains { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
    }
}

/// 调度引擎会话消息（协议无关，由 CloudProvider 翻译为各家格式）
public struct EngineMessage: Sendable {
    public enum Role: Sendable {
        case system
        case user
        case assistant
        case toolResult
    }

    public let role: Role
    public var text: String
    /// assistant 消息携带的工具调用
    public var toolCalls: [ToolCallRaw]
    /// toolResult 消息对应的调用 id
    public var toolCallId: String?
    /// user 消息可携带的图片（多模态输入；仅当前轮用户消息使用，历史不带图省 token）
    public var images: [EngineImage]
    public var continuation: EngineContinuation?
    // Local history metadata only. Wire adapters and handoff snapshots use explicit fields.
    public internal(set) var chatMessageID: UUID?
    var historyTurn: ProviderTurnHistory?
    var historyEvidence: String?
    var displayedMailReferences: DisplayedMailReferences?
    /// Host-authored catalog receipt. Wire content alone cannot set this local provenance marker.
    var hostToolDiscovery: Bool?

    public init(role: Role, text: String, toolCalls: [ToolCallRaw] = [], toolCallId: String? = nil, images: [EngineImage] = [], continuation: EngineContinuation? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.images = images
        self.continuation = continuation
    }
}

/// 多模态图片输入（原始字节 + MIME 类型；序列化时按协议转 base64/data-URI）
public struct EngineImage: Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// 一次工具调用（参数以 JSON 字符串传递，避免 [String: Any] 的 Sendable 问题）
public struct ToolCallRaw: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// 工具定义（JSON Schema 以字符串传递）
public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema object，如 {"type":"object","properties":{...},"required":[...]}
    public let parametersSchemaJSON: String

    public init(name: String, description: String, parametersSchemaJSON: String) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }
}

/// 一轮对话回复：正文 + 推理文本 + 可能的工具调用请求 + 结束原因 + token 用量（均可选）。
/// 正文与推理文本必须分开保留：推理是模型的内部计划，不能当作最终回答。
public struct ChatReply: Sendable {
    public let text: String
    public let commentary: String?
    /// 推理 / 思考文本（reasoning_content / thinking 块）；与正文分开保留
    public let reasoning: String?
    /// text 是否由推理文本回填而来（正文原本为空）。带工具的执行请求据此识别
    /// 「只有推理、没有正文与工具调用」的未完成步骤，而不是把内部计划当真回答。
    public let textUsedReasoningBackfill: Bool
    public let toolCalls: [ToolCallRaw]
    /// 提示词 token 数（OpenAI prompt_tokens / Anthropic input_tokens）
    public let promptTokens: Int?
    /// 补全 token 数（OpenAI completion_tokens / Anthropic output_tokens）
    public let completionTokens: Int?
    public let usage: ProviderTokenUsage
    /// 结束原因（OpenAI finish_reason / Anthropic stop_reason）：length/max_tokens = 输出被截断
    public let finishReason: String?
    public let continuation: EngineContinuation?

    /// Inline image results are kept out of model text and tool arguments.
    public let generatedImages: [EngineImage]

    public var wantsToolCall: Bool { !toolCalls.isEmpty }
    /// 输出是否因 token 上限被截断
    public var isTruncated: Bool {
        ["length", "max_tokens"].contains(finishReason ?? "")
    }

    /// 只有推理、没有正文与工具调用（正文为空或由推理回填）
    public var isReasoningOnly: Bool {
        toolCalls.isEmpty
            && (text.isEmpty || textUsedReasoningBackfill)
            && (!(reasoning ?? "").isEmpty || continuation?.containsThinkingBlocks == true)
    }

    /// 协议不一致：结束原因声明了工具调用，但实际没有解析到任何工具调用
    public var hasToolCallFinishMismatch: Bool {
        ["tool_calls", "tool_use"].contains(finishReason ?? "") && toolCalls.isEmpty
    }

    public init(
        text: String,
        toolCalls: [ToolCallRaw],
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        finishReason: String? = nil,
        reasoning: String? = nil,
        textUsedReasoningBackfill: Bool = false,
        usage: ProviderTokenUsage? = nil,
        continuation: EngineContinuation? = nil,
        generatedImages: [EngineImage] = [],
        commentary: String? = nil
    ) {
        self.text = text
        self.reasoning = reasoning
        self.textUsedReasoningBackfill = textUsedReasoningBackfill
        self.toolCalls = toolCalls
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.usage = usage ?? .init(input: promptTokens, output: completionTokens)
        self.finishReason = finishReason
        self.continuation = continuation
        self.generatedImages = generatedImages
        self.commentary = commentary
    }
}

/// 检测模型把工具调用当正文输出的残缺标记。
/// 只在“本次请求带了工具、但提供方没有返回任何 tool_calls”时使用；
/// 跳过 Markdown 代码块，避免把正常的 XML 示例误判为未执行工具。
enum ToolCallMarkupDetector {
    static func containsUnparsedToolCall(_ text: String) -> Bool {
        let body = strippingFencedCodeBlocks(text)
        let hasToolCall = body.contains("<tool_call") || body.contains("</tool_call>")
        let hasFunction = body.contains("<function=") || body.contains("</function>")
        let hasParameter = body.contains("<parameter=") || body.contains("</parameter>")
        if hasToolCall && (hasFunction || hasParameter) { return true }
        return hasFunction && hasParameter
    }

    private static func strippingFencedCodeBlocks(_ text: String) -> String {
        var output: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { output.append(String(line)) }
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Cloud Provider Tool Calling

extension CloudProvider {

    /// Output budget adaptation requires a numeric range/limit error, never an unsupported field.
    /// 兜底：报错范围解析失败、或配置已在上界内仍被拒（如思考模式收紧实际上限）时，
    /// 钳到保守值（4096，任何提供方下限之上）再给一次机会
    static func adaptedMaxTokensConfig(error: LLMError, config: LLMConfig) -> LLMConfig? {
        guard case let .networkError(statusCode, message) = error,
              statusCode == 400 || statusCode == 422,
              Self.isOutputLimitMessage(message) else { return nil }
        if let cap = parseMaxTokensCap(from: message), config.maxTokens > cap {
            var adapted = config
            adapted.maxTokens = cap
            return adapted
        }
        if config.maxTokens > Self.conservativeMaxTokens {
            var adapted = config
            adapted.maxTokens = Self.conservativeMaxTokens
            return adapted
        }
        return nil
    }

    /// 保守 Token 上限：提供方报告范围与实际限制不符时的兜底钳制值
    static let conservativeMaxTokens = 4096

    /// 400 响应体是否为「模型不支持图片」错误
    static func isImageUnsupportedMessage(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("image")
            && (lower.contains("not support") || lower.contains("unsupported"))
    }

    /// 从错误信息提取 max_tokens 上限：匹配 "…max_tokens is [1, 393216]" 中的上界数字
    private static func parseMaxTokensCap(from message: String) -> Int? {
        guard let range = message.range(
            of: #"(?<=\[)\s*\d+\s*,\s*(\d+)\s*(?=\])"#,
            options: .regularExpression
        ) else { return nil }
        let bounds = message[range]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 2, bounds[0] >= 1, bounds[1] > 1 else { return nil }
        return bounds[1]
    }

    /// 图片不支持：provider 层不做单次降级（会掩盖错误、导致引擎每轮重复 400），
    /// 改抛 LLMError.imageUnsupported，由 DispatcherEngine 永久剥离图片后重试

    /// 带工具的单轮对话（非流式）：支持 OpenAI 兼容 function calling 与 Anthropic tool use。
    /// Uses the shared bounded adapter for rejected parameter names, values and sampling.
    public func chat(messages: [EngineMessage], tools: [ToolDefinition], config: LLMConfig) async throws -> ChatReply {
        let config = try await prepareConfiguration(config, messages: messages, tools: tools)
        return try await withRequestAdaptation(config: config) { adapted in
            try await performChat(messages: messages, tools: tools, config: adapted)
        }
    }

    private func performChat(messages: [EngineMessage], tools: [ToolDefinition], config: LLMConfig, omitTemperature: Bool = false) async throws -> ChatReply {
        let providerKey = endpoint
        let ticket: ProviderGateTicket
        do {
            ticket = try await ProviderConcurrencyGate.shared.acquire(providerKey)
        } catch ProviderGateError.cancelled {
            throw CancellationError()
        } catch {
            throw LLMError.configurationError(reason: error.localizedDescription)
        }
        defer { Task { await ProviderConcurrencyGate.shared.release(ticket) } }
        let request = try buildChatRequest(messages: messages, tools: tools, config: config, stream: false, omitTemperature: omitTemperature)
        let progress = ProviderUsageProgress()
        return try await withUsage(model: config.modelName, progress: progress) {
            let (data, response) = try await boundedData(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.networkError(statusCode: -1, message: "Invalid response")
            }
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 401:
                throw LLMError.invalidAPIKey
            case 404:
                throw Self.endpointPathError
            case 429:
                throw LLMError.rateLimited
            case 400:
                let body = String(data: data, encoding: .utf8) ?? ""
                if Self.isImageUnsupportedMessage(body) {
                    throw LLMError.imageUnsupported
                }
                throw LLMError.networkError(statusCode: httpResponse.statusCode, message: String(body.prefix(4096)))
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.networkError(statusCode: httpResponse.statusCode, message: String(body.prefix(4096)))
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.responseParsingFailed(reason: "Invalid JSON response")
            }
            let counts = Self.usageCounts(json["usage"] as? [String: Any], anthropic: isAnthropic)
            progress.observe(json, anthropic: isAnthropic)
            progress.update(input: counts.input, output: counts.output)
            let reply: ChatReply
            switch wireProtocol(for: config) {
            case .responses: reply = try parseResponsesReply(json)
            case .anthropicMessages: reply = try parseAnthropicReply(json)
            case .chatCompletions: reply = try parseOpenAIReply(json)
            }
            try LLMResponseLimits.validate(reply)
            return (reply, reply.promptTokens, reply.completionTokens)
        }
    }

    // MARK: - Streaming Chat

    /// 带工具的流式对话：文本增量经 onDelta 实时回调（调用方自行切主线程），
    /// 流结束后返回与 chat() 等价的完整 ChatReply（含累积完成的工具调用与 token 用量）。
    /// OpenAI 兼容协议：请求 stream_options.include_usage 以在末尾 chunk 获取用量；
    /// Anthropic 协议：usage 来自 message_start / message_delta 事件。
    /// Parameter adaptation is limited to rejected HTTP requests; partial output is never replayed.
    public func chatStream(
        messages: [EngineMessage],
        tools: [ToolDefinition],
        config: LLMConfig,
        onGenerationMetrics: (@Sendable (StreamGenerationEvent) -> Void)? = nil,
        onUsage: (@Sendable (ProviderTokenUsage) -> Void)? = nil,
        onConfiguration: (@Sendable (LLMConfig) -> Void)? = nil,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChatReply {
        let config = try await prepareConfiguration(config, messages: messages, tools: tools)
        return try await withRequestAdaptation(config: config) { adapted in
            onConfiguration?(adapted)
            return try await performChatStream(messages: messages, tools: tools, config: adapted, onGenerationMetrics: onGenerationMetrics, onUsage: onUsage, onDelta: onDelta, onReasoningDelta: onReasoningDelta)
        }
    }

    private func performChatStream(
        messages: [EngineMessage],
        tools: [ToolDefinition],
        config: LLMConfig,
        omitTemperature: Bool = false,
        onGenerationMetrics: (@Sendable (StreamGenerationEvent) -> Void)? = nil,
        onUsage: (@Sendable (ProviderTokenUsage) -> Void)? = nil,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChatReply {
        let providerKey = endpoint
        let ticket: ProviderGateTicket
        do {
            ticket = try await ProviderConcurrencyGate.shared.acquire(providerKey)
        } catch ProviderGateError.cancelled {
            throw CancellationError()
        } catch {
            throw LLMError.configurationError(reason: error.localizedDescription)
        }
        defer { Task { await ProviderConcurrencyGate.shared.release(ticket) } }
        let request = try buildChatRequest(messages: messages, tools: tools, config: config, stream: true, omitTemperature: omitTemperature)
        let progress = ProviderUsageProgress()
        // Deliver the final merged report for each HTTP attempt, including interrupted streams.
        defer { onUsage?(progress.snapshot) }
        let generation = onGenerationMetrics.map { StreamGenerationTracker(onMetrics: $0) }
        defer { generation?.finish(outputTokens: progress.snapshot.output) }
        return try await withUsage(model: config.modelName, progress: progress) {
            let (bytes, response) = try await responseBytes(for: request)
            defer { bytes.task.cancel() }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.networkError(statusCode: -1, message: "Invalid response")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                switch httpResponse.statusCode {
                case 401:
                    throw LLMError.invalidAPIKey
                case 404:
                    throw Self.endpointPathError
                case 429:
                    throw LLMError.rateLimited
                case 400:
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                        if errorData.count > 4096 { break }
                    }
                    let bodyText = String(data: errorData, encoding: .utf8) ?? ""
                    if Self.isImageUnsupportedMessage(bodyText) {
                        throw LLMError.imageUnsupported
                    }
                    throw LLMError.networkError(
                        statusCode: httpResponse.statusCode,
                        message: String(bodyText.prefix(4096))
                    )
                default:
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                        if errorData.count > 4096 { break }
                    }
                    let bodyText = String(data: errorData, encoding: .utf8) ?? ""
                    throw LLMError.networkError(
                        statusCode: httpResponse.statusCode,
                        message: String(bodyText.prefix(4096))
                    )
                }
            }

            let reply: ChatReply
            if wireProtocol(for: config) == .responses {
                reply = try await withStallWatchdog { monitor in
                    try await self.parseResponsesStream(bytes, requiresExplicitPhase: self.reasoningProfile(config).dialect == .gpt,
                        onDelta: onDelta, onReasoningDelta: onReasoningDelta, monitor: monitor, usageProgress: progress, generation: generation)
                }
            } else if isAnthropic {
                reply = try await withStallWatchdog { monitor in
                    try await self.parseAnthropicStream(bytes, onDelta: onDelta, onReasoningDelta: onReasoningDelta, monitor: monitor, usageProgress: progress, generation: generation)
                }
            } else {
                reply = try await withStallWatchdog { monitor in
                    try await self.parseOpenAIStream(
                        bytes,
                        onDelta: onDelta,
                        onReasoningDelta: onReasoningDelta,
                        monitor: monitor,
                        toolsWereRequested: !tools.isEmpty,
                        usageProgress: progress,
                        generation: generation
                    )
                }
            }
            try LLMResponseLimits.validate(reply)
            return (reply, reply.promptTokens, reply.completionTokens)
        }
    }

    // MARK: - Stall Watchdog（流式断连看门狗）

    /// 流式连接静默判定阈值：连续 N 秒无任何 SSE 数据到达即判死。
    /// 正常流式（含思考型模型的 reasoning 增量）数据是持续到达的；
    /// 静默超过该阈值几乎必然是断连（NAT 超时/网络切换/服务端挂起）
    static let streamStallThreshold: TimeInterval = 600

    /// 看门狗巡检间隔（30s 一拍；阈值到达即触发，精度不受间隔影响过大）
    private static let stallWatchdogTick: UInt64 = 30_000_000_000

    /// 流式活动监视：解析任务每收到一行 SSE 调 touch()，看门狗周期巡检静默时长。
    /// NSLock 保护（行级高频小临界区）
    final class StreamActivityMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()

        func touch() {
            lock.withLock { lastActivity = Date() }
        }

        func idleSeconds() -> TimeInterval {
            lock.withLock { Date().timeIntervalSince(lastActivity) }
        }
    }

    /// 流式断连看门狗：解析任务与巡检任务在任务组中竞速。
    /// 解析正常结束 → 取消巡检并返回结果；巡检先发现静默超阈值 →
    /// 抛 streamStalled，任务组作用域退出时自动取消并收尾解析任务
    /// （对 async 流迭代发取消 → 迭代抛 CancellationError → 解析子任务终止，无悬挂）
    func withStallWatchdog(_ parse: @escaping @Sendable (StreamActivityMonitor) async throws -> ChatReply) async throws -> ChatReply {
        let monitor = StreamActivityMonitor()
        return try await withThrowingTaskGroup(of: ChatReply.self) { group in
            group.addTask {
                try await parse(monitor)
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: Self.stallWatchdogTick)
                    if monitor.idleSeconds() > Self.streamStallThreshold {
                        throw LLMError.streamStalled(seconds: Int(Self.streamStallThreshold))
                    }
                }
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else {
                throw LLMError.responseParsingFailed(reason: "stream ended without reply")
            }
            return reply
        }
    }

    /// OpenAI 兼容 SSE：按事件组装多行 data，累积 delta 并核对网关的完整 message 快照。
    private func parseOpenAIStream(
        _ bytes: URLSession.AsyncBytes,
        onDelta: @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil,
        monitor: StreamActivityMonitor,
        toolsWereRequested: Bool,
        usageProgress: ProviderUsageProgress,
        generation: StreamGenerationTracker? = nil
    ) async throws -> ChatReply {
        struct ToolAccumulator {
            var id: String?
            var name: String?
            var arguments = ""
        }
        var text = ""
        // 推理模型的思考增量（DeepSeek/GLM/Qwen 等走 reasoning_content，OpenRouter 系走 reasoning）。
        // 只走专用 onReasoningDelta 通道外发（如技能生成面板），不混入 onDelta 正文——
        // 聊天引擎共用此流，正文必须保持干净；正文为空时仍兜底为文本——
        // 补全预算耗尽在推理上时 content 可能为空
        var reasoningText = ""
        var reasoningContent: String?
        var alternateReasoning: String?
        var finishReason: String?
        var accumulators: [Int: ToolAccumulator] = [:]
        // 完成标记：OpenAI 兼容协议以 `data: [DONE]` 或非空 finish_reason 表示正常结束。
        // 两者皆无即连接在协议完成前被关闭（异常 EOF），不得当作成功返回
        var sawDone = false
        var payload = ""
        var payloadBytes = 0
        var hasData = false

        // 增量可能停在组合字符或 emoji 序列中间，按 UTF-8 前缀去重而非完整 Character 数。
        func snapshotSuffix(_ value: String, after prefix: String) -> String? {
            guard value.utf8.starts(with: prefix.utf8) else { return nil }
            return String(decoding: value.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }

        func consume(_ payload: String) throws -> Bool {
            try Task.checkCancellation()
            guard !payload.isEmpty else { return false }
            if payload == "[DONE]" { return true }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // 丢弃损坏事件可能只留下 finish_reason，或错误执行同批中的其余调用。
                throw LLMError.responseParsingFailed(reason: "Invalid Chat Completions stream event")
            }
            // SSE error 事件：部分网关在流中返回 {"error": {...}}（限流/过载等），
            // 必须在解析正文前识别，否则会被下面的 choices 守卫静默跳过
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "stream returned an error event"
                throw LLMError.networkError(statusCode: -1, message: message)
            }
            usageProgress.observe(json, anthropic: false)
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
            // 一些网关的终态只有 finish_reason，没有 delta。
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                finishReason = reason
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let reasoningDelta = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
            if let value = delta["reasoning_content"] as? String {
                reasoningContent = (reasoningContent ?? "") + value
                try LLMResponseLimits.check(reasoningContent ?? "")
            } else if let value = delta["reasoning"] as? String {
                alternateReasoning = (alternateReasoning ?? "") + value
                try LLMResponseLimits.check(alternateReasoning ?? "")
            }
            if !reasoningDelta.isEmpty {
                reasoningText += reasoningDelta
                try LLMResponseLimits.check(reasoningText)
                generation?.observe(reasoningDelta)
                onReasoningDelta?(reasoningDelta)
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                text += content
                try LLMResponseLimits.check(text)
                generation?.observe(content)
                onDelta(content)
            }
            if let value = delta["tool_calls"], !(value is NSNull) {
                guard let fragments = value as? [[String: Any]] else {
                    throw LLMError.responseParsingFailed(reason: "Invalid streamed tool calls")
                }
                for fragment in fragments {
                    if let value = fragment["index"], !(value is Int) {
                        throw LLMError.responseParsingFailed(reason: "Invalid streamed tool call index")
                    }
                    let index = fragment["index"] as? Int ?? 0
                    guard (0..<LLMResponseLimits.toolCalls).contains(index) else { throw LLMError.responseTooLarge }
                    var item = accumulators[index] ?? ToolAccumulator()
                    if let id = fragment["id"] as? String, !id.isEmpty {
                        guard item.id == nil || item.id == id else {
                            throw LLMError.responseParsingFailed(reason: "Streamed tool call identity changed")
                        }
                        item.id = id
                    }
                    if let value = fragment["function"], !(value is NSNull) {
                        guard let function = value as? [String: Any] else {
                            throw LLMError.responseParsingFailed(reason: "Invalid streamed function")
                        }
                        for key in ["name", "arguments"] {
                            if let value = function[key], !(value is NSNull), !(value is String) {
                                throw LLMError.responseParsingFailed(reason: "Invalid streamed function field")
                            }
                        }
                        if let name = function["name"] as? String, !name.isEmpty {
                            item.name = (item.name ?? "") + name
                            try LLMResponseLimits.check(item.name ?? "")
                        }
                        if let arguments = function["arguments"] as? String {
                            item.arguments += arguments
                            try LLMResponseLimits.check(item.arguments, limit: LLMResponseLimits.argumentBytes)
                            generation?.observe(arguments)
                        }
                    }
                    accumulators[index] = item
                }
            }

            // 部分兼容网关会在 SSE 中发送非流式形态的完整 message。
            // 快照只能补全已观察到的前缀，不能替换身份、丢弃调用或重复累加参数。
            if let message = choice["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    guard let tail = snapshotSuffix(content, after: text) else {
                        throw LLMError.responseParsingFailed(reason: "Chat text changed in message snapshot")
                    }
                    text = content
                    try LLMResponseLimits.check(text)
                    if !tail.isEmpty { generation?.observe(tail); onDelta(tail) }
                }
                if let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String) {
                    guard let tail = snapshotSuffix(reasoning, after: reasoningText) else {
                        throw LLMError.responseParsingFailed(reason: "Chat reasoning changed in message snapshot")
                    }
                    reasoningText = reasoning
                    try LLMResponseLimits.check(reasoningText)
                    if !tail.isEmpty { generation?.observe(tail); onReasoningDelta?(tail) }
                }
                if let value = message["reasoning_content"] as? String {
                    guard value.utf8.starts(with: (reasoningContent ?? "").utf8) else {
                        throw LLMError.responseParsingFailed(reason: "Chat continuation changed in message snapshot")
                    }
                    reasoningContent = value
                } else if let value = message["reasoning"] as? String {
                    guard value.utf8.starts(with: (alternateReasoning ?? "").utf8) else {
                        throw LLMError.responseParsingFailed(reason: "Chat reasoning changed in message snapshot")
                    }
                    alternateReasoning = value
                }
                let snapshots: [[String: Any]]
                if let value = message["tool_calls"], !(value is NSNull) {
                    guard let calls = value as? [[String: Any]] else {
                        throw LLMError.responseParsingFailed(reason: "Invalid tool calls in message snapshot")
                    }
                    snapshots = calls
                } else { snapshots = [] }
                guard snapshots.count <= LLMResponseLimits.toolCalls else { throw LLMError.responseTooLarge }
                guard accumulators.keys.allSatisfy({ $0 < snapshots.count }) else {
                    throw LLMError.responseParsingFailed(reason: "Message snapshot dropped streamed tool calls")
                }
                var canonical: [Int: ToolAccumulator] = [:]
                for (index, call) in snapshots.enumerated() {
                    guard let id = call["id"] as? String, !id.isEmpty,
                          let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String, !name.isEmpty,
                          let arguments = function["arguments"] as? String else {
                        throw LLMError.responseParsingFailed(reason: "Incomplete tool call in message snapshot")
                    }
                    try LLMResponseLimits.check(arguments, limit: LLMResponseLimits.argumentBytes)
                    if let previous = accumulators[index] {
                        guard (previous.id == nil || previous.id == id),
                              name.utf8.starts(with: (previous.name ?? "").utf8),
                              arguments.utf8.starts(with: previous.arguments.utf8) else {
                            throw LLMError.responseParsingFailed(reason: "Message snapshot conflicts with streamed tool call")
                        }
                    }
                    canonical[index] = ToolAccumulator(id: id, name: name, arguments: arguments)
                }
                accumulators = canonical
            }
            return false
        }

        for try await line in BoundedLLMLines(bytes: bytes) {
            try Task.checkCancellation()
            monitor.touch()
            if line.isEmpty {
                if try consume(payload) { sawDone = true; break }
                payload = ""; payloadBytes = 0; hasData = false
            } else if let value = Self.sseData(line) {
                payloadBytes += value.utf8.count + (hasData ? 1 : 0)
                guard payloadBytes <= LLMResponseLimits.eventBytes else { throw LLMError.responseTooLarge }
                if hasData { payload += "\n" }
                payload += value
                hasData = true
            }
        }
        // 兼容末尾没有空行的事件；仍须收到协议完成标记才可执行调用。
        if !sawDone { sawDone = try consume(payload) }
        try Task.checkCancellation()
        // EOF 仍沿用未完成语义；调用身份校验不能把半条流当成完整回复。
        guard sawDone || finishReason != nil else {
            throw LLMError.streamIncomplete(partialCharacters: text.isEmpty ? reasoningText.count : text.count)
        }

        var callIDs: Set<String> = []
        let calls = try accumulators
            .sorted(by: { $0.key < $1.key })
            .map { _, item -> ToolCallRaw in
                guard let id = item.id, !id.isEmpty, let name = item.name, !name.isEmpty,
                      callIDs.insert(id).inserted else {
                    throw LLMError.responseParsingFailed(reason: "Incomplete or duplicate streamed tool call identity")
                }
                return ToolCallRaw(
                    id: id,
                    name: name,
                    argumentsJSON: item.arguments.isEmpty ? "{}" : item.arguments
                )
            }
        // 兜底：思考型模型耗尽补全预算时正文为空，用思考文本顶替（同时记录回填事实），
        // 避免上层（如技能生成的 think 阶段）拿到空文本只能报错。
        // 带工具的执行请求据 textUsedReasoningBackfill 识别「只有推理」的未完成步骤。
        var usedReasoningBackfill = false
        if text.isEmpty, !reasoningText.isEmpty {
            text = reasoningText
            usedReasoningBackfill = true
        }
        if toolsWereRequested, calls.isEmpty,
           ToolCallMarkupDetector.containsUnparsedToolCall(text)
            || ToolCallMarkupDetector.containsUnparsedToolCall(reasoningText) {
            throw LLMError.unparsedToolCall
        }
        return ChatReply(
            text: text,
            toolCalls: calls,
            promptTokens: usageProgress.snapshot.input,
            completionTokens: usageProgress.snapshot.output,
            finishReason: finishReason,
            reasoning: reasoningText.isEmpty ? nil : reasoningText,
            textUsedReasoningBackfill: usedReasoningBackfill,
            usage: usageProgress.snapshot,
            continuation: EngineContinuation(reasoningContent: reasoningContent, alternateReasoning: alternateReasoning)
        )
    }

    /// Anthropic SSE：text_delta 增量 + tool_use 块（input_json_delta 聚合）+ usage 事件
    private func parseAnthropicStream(
        _ bytes: URLSession.AsyncBytes,
        onDelta: @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil,
        monitor: StreamActivityMonitor,
        usageProgress: ProviderUsageProgress,
        generation: StreamGenerationTracker? = nil
    ) async throws -> ChatReply {
        struct ToolAccumulator {
            var id: String?
            var name: String?
            var json = ""
        }
        var text = ""
        // thinking 块增量：只走专用 onReasoningDelta 通道（不混入正文）；正文为空时仍兜底（预算耗尽在思考上时无 text 块）
        var thinkingText = ""
        var stopReason: String?
        var tools: [Int: ToolAccumulator] = [:]
        var blocks: [Int: [String: Any]] = [:]

        func buildReply() throws -> ChatReply {
            let calls = tools
                .sorted(by: { $0.key < $1.key })
                .compactMap { index, item -> ToolCallRaw? in
                    guard let name = item.name else { return nil }
                    let initialInput = blocks[index]?["input"] as? [String: Any] ?? [:]
                    let initialJSON = (try? JSONSerialization.data(withJSONObject: initialInput)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ToolCallRaw(
                        id: item.id ?? UUID().uuidString,
                        name: name,
                        argumentsJSON: item.json.isEmpty ? initialJSON : item.json
                    )
                }
            // thinking 块增量只走推理通道；正文为空时回填并记录回填事实
            let usedBackfill = text.isEmpty && !thinkingText.isEmpty
            let finalText = usedBackfill ? thinkingText : text
            let orderedBlocks = try blocks.keys.sorted().map { index -> [String: Any] in
                var block = blocks[index]!
                if let tool = tools[index], !tool.json.isEmpty {
                    // Truncated tool JSON is handled by the engine; never replay invalid JSON.
                    if let data = tool.json.data(using: .utf8),
                       let input = try? JSONSerialization.jsonObject(with: data) {
                        block["input"] = input
                    } else if !["max_tokens", "length"].contains(stopReason ?? "") {
                        throw LLMError.responseParsingFailed(reason: "Incomplete tool input")
                    }
                }
                return block
            }
            let blockData = try JSONSerialization.data(withJSONObject: orderedBlocks)
            guard blockData.count <= LLMResponseLimits.responseBytes else { throw LLMError.responseTooLarge }
            return ChatReply(
                text: finalText,
                toolCalls: calls,
                promptTokens: usageProgress.snapshot.input,
                completionTokens: usageProgress.snapshot.output,
                finishReason: stopReason,
                reasoning: thinkingText.isEmpty ? nil : thinkingText,
                textUsedReasoningBackfill: usedBackfill,
                usage: usageProgress.snapshot,
                continuation: EngineContinuation(anthropicBlocksJSON: String(decoding: blockData, as: UTF8.self))
            )
        }

        for try await line in BoundedLLMLines(bytes: bytes) {
            try Task.checkCancellation()
            monitor.touch()
            guard let payload = Self.sseData(line) else { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }
            usageProgress.observe(json, anthropic: true)
            switch type {
            case "error":
                // Anthropic 在流中通过 error 事件报告过载/服务端错误；抛出以便上层决定是否退避
                let errorObject = json["error"] as? [String: Any]
                let message = (errorObject?["message"] as? String) ?? "stream returned an error event"
                throw LLMError.networkError(statusCode: -1, message: message)
            case "message_start":
                break // Usage is merged before dispatching this event.
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any] {
                    let index = json["index"] as? Int ?? 0
                    guard (0..<256).contains(index), blocks[index] == nil else { throw LLMError.responseTooLarge }
                    blocks[index] = block
                }
                if let block = json["content_block"] as? [String: Any],
                   (block["type"] as? String) == "tool_use" {
                    let index = json["index"] as? Int ?? 0
                    guard tools.count < LLMResponseLimits.toolCalls else { throw LLMError.responseTooLarge }
                    guard let id = block["id"] as? String, !id.isEmpty,
                          let name = block["name"] as? String, !name.isEmpty else {
                        throw LLMError.responseParsingFailed(reason: "Tool block is missing its identity")
                    }
                    tools[index] = ToolAccumulator(id: id, name: name)
                }
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any] else { continue }
                let deltaType = delta["type"] as? String
                let index = json["index"] as? Int ?? 0
                if let field = ["text_delta": "text", "thinking_delta": "thinking", "signature_delta": "signature"][deltaType ?? ""],
                   let value = delta[field] as? String, blocks[index] != nil {
                    let updated = (blocks[index]?[field] as? String ?? "") + value
                    try LLMResponseLimits.check(updated)
                    blocks[index]?[field] = updated
                }
                if deltaType == "text_delta", let value = delta["text"] as? String, !value.isEmpty {
                    text += value
                    try LLMResponseLimits.check(text)
                    generation?.observe(value)
                    onDelta(value)
                } else if deltaType == "thinking_delta", let value = delta["thinking"] as? String, !value.isEmpty {
                    thinkingText += value
                    try LLMResponseLimits.check(thinkingText)
                    generation?.observe(value)
                    onReasoningDelta?(value)
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                    let index = json["index"] as? Int ?? 0
                    guard tools[index] != nil else { throw LLMError.responseParsingFailed(reason: "Tool input has no matching block") }
                    tools[index]?.json += partial
                    try LLMResponseLimits.check(tools[index]?.json ?? "", limit: LLMResponseLimits.argumentBytes)
                    generation?.observe(partial)
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let stop = delta["stop_reason"] as? String, !stop.isEmpty {
                        stopReason = stop
                    }
                }
            case "message_stop":
                return try buildReply()
            default:
                break
            }
        }
        // 循环自然结束（未收到 message_stop）：仅当已拿到明确 stop_reason 才视为正常完成。
        // 两者皆无即连接在协议完成标记前被关闭，抛领域错误而非把半段答复当成功
        guard stopReason != nil else {
            throw LLMError.streamIncomplete(partialCharacters: (text.isEmpty ? thinkingText : text).count)
        }
        return try buildReply()
    }

    // MARK: - Request Building

    func buildChatRequest(messages: [EngineMessage], tools: [ToolDefinition], config: LLMConfig, stream: Bool, omitTemperature: Bool = false) throws -> URLRequest {
        if wireProtocol(for: config) == .responses {
            return try buildResponsesRequest(messages: messages, tools: tools, config: config, stream: stream, omitTemperature: omitTemperature)
        }
        // 端点安全强制校验（携带凭据与用户内容）
        try EndpointSafety.validate(endpoint)
        guard let url = URL(string: endpoint) else {
            throw LLMError.configurationError(reason: "Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 空闲计时器（流式期间每个 chunk 重置；非流式则近似总时长）。
        // 与 session 配置同步放宽到 1 小时，见 CloudProvider session 配置注释
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let model = config.modelName.isEmpty ? self.model : config.modelName
        var body: [String: Any] = [
            "model": model,
            outputTokenParameter(for: config): config.maxTokens
        ]
        // 只接受 temperature = 1 的推理模型不发该参数（见 CloudProvider.allowsTemperature；
        // omitTemperature 为 temperature 被拒后的重试标记）
        if shouldSendTemperature(config, omit: omitTemperature) {
            body["temperature"] = config.temperature
        }

        // 思考力度：standard 不发参数（提供方默认）；fast/deep 按提供方协议映射
        let effort = config.reasoningEffort ?? (config.reasoningBudget == nil ? .standard : .deep)
        let profile = reasoningProfile(config)
        if effort != .standard {
            let host = URL(string: endpoint)?.host?.lowercased() ?? ""
            if isAnthropic {
                // Anthropic 默认不思考；深入才显式开启（预算 8K，需小于 max_tokens）
                if effort == .deep, config.reservedOutputTokens > 1024 {
                    let automaticBudget = max(1024, min(8192, config.reservedOutputTokens / 2))
                    body["thinking"] = ["type": "enabled", "budget_tokens": min(config.reasoningBudget ?? automaticBudget, config.maxTokens - 1)]
                    // Anthropic 在 thinking 模式下只接受 temperature = 1，必须省略
                    body.removeValue(forKey: "temperature")
                }
            } else if host.contains("bigmodel.cn") {
                // GLM：thinking.type 开关
                body["thinking"] = ["type": effort == .fast ? "disabled" : "enabled"]
            } else if profile.dialect == .chatTemplate {
                let selection = profile.selection(effort)
                if selection != .standard { body["chat_template_kwargs"] = ["enable_thinking": selection != .off] }
            } else if profile.dialect == .dashScope {
                let selection = profile.selection(effort)
                if selection != .standard { body["enable_thinking"] = selection != .off }
            } else if ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com"].contains(host) {
                // Qwen：enable_thinking 布尔开关
                body["enable_thinking"] = (effort == .deep)
            } else if host == "api.deepseek.com" {
                // 新版 DeepSeek 混合模型可显式切换思考模式；旧版 chat/reasoner 仍由模型名决定。
                let selected = profile.selection(effort)
                if profile.dialect == .deepSeek, selected != .standard {
                    body["thinking"] = ["type": selected == .off ? "disabled" : "enabled"]
                    if selected != .off { body["reasoning_effort"] = selected.rawValue }
                }
            } else if host == "openrouter.ai" {
                if let budget = config.reasoningBudget, config.modelCapabilities?.supportsReasoningBudget == true {
                    body["reasoning"] = ["max_tokens": budget]
                } else {
                    body["reasoning"] = ["effort": config.reasoningLevel ?? (effort == .fast ? "low" : "high")]
                }
            } else if !profile.offersChatTemplateSetting || profile.selection(effort) != .standard {
                // 通用 OpenAI 兼容：reasoning_effort（不支持的提供方通常忽略未知参数）
                body["reasoning_effort"] = openAIReasoningLevel(config)
            }
        }

        if profile.isThinkingSwitch, profile.selection(effort) != .off,
           let latestUser = messages.lastIndex(where: { $0.role == .user }),
           messages[..<latestUser].contains(where: { $0.continuation?.reasoningContent != nil || $0.continuation?.alternateReasoning != nil }) {
            if profile.dialect == .dashScope { body["preserve_thinking"] = true }
            else {
                var settings = body["chat_template_kwargs"] as? [String: Bool] ?? [:]
                settings["preserve_thinking"] = true
                body["chat_template_kwargs"] = settings
            }
        }
        if stream {
            body["stream"] = true
            if !isAnthropic, config.requestOmitsStreamOptions != true {
                // 请求末尾 chunk 附带 token 用量（主流 OpenAI 兼容网关均支持）
                body["stream_options"] = ["include_usage": true]
            }
        }

        if !tools.isEmpty {
            var toolSpecs: [[String: Any]] = []
            for tool in tools {
                let schema = try validatedToolSchema(tool)
                if isAnthropic {
                    toolSpecs.append([
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": schema
                    ])
                } else {
                    toolSpecs.append([
                        "type": "function",
                        "function": [
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": schema
                        ]
                    ])
                }
            }
            body["tools"] = toolSpecs
            if config.requestToolChoiceNone == true {
                if isAnthropic { body["tool_choice"] = ["type": "none"] }
                else { body["tool_choice"] = "none" }
            }
        }

        if isAnthropic {
            // system 为顶层字段；其余消息翻译为 Anthropic 格式
            let systemText = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            if !systemText.isEmpty {
                body["system"] = systemText
            }
            body["messages"] = try anthropicMessages(from: messages.filter { $0.role != .system })
        } else {
            body["messages"] = try openAIMessages(from: messages, useAlternateReasoning: profile.dialect == .chatTemplate)
        }

        if isAnthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        applyPromptCaching(to: &body, config: config)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func validatedToolSchema(_ tool: ToolDefinition) throws -> [String: Any] {
        guard var schema = (try? JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8))) as? [String: Any] else {
            throw LLMError.invalidToolSchema(toolName: tool.name, field: "parameters")
        }
        guard schema["type"] as? String == "object" else {
            throw LLMError.invalidToolSchema(toolName: tool.name, field: "parameters.type")
        }
        // OpenAI-compatible function parameters forbid these keywords at the root.
        // Reject the definition rather than silently weakening its constraints.
        if !isAnthropic {
            for keyword in ["oneOf", "anyOf", "allOf", "enum", "const", "not"] where schema[keyword] != nil {
                throw LLMError.invalidToolSchema(toolName: tool.name, field: "parameters.\(keyword)")
            }
        }
        // LM Studio 等兼容端点要求对象参数显式包含 properties（无参数时也一样）。
        // 补空对象不改变 required / additionalProperties 等原有 Schema 约束。
        if let properties = schema["properties"] {
            guard properties is [String: Any] else {
                throw LLMError.invalidToolSchema(toolName: tool.name, field: "parameters.properties")
            }
        } else {
            schema["properties"] = [String: Any]()
        }
        return schema
    }

    private func openAIMessages(from messages: [EngineMessage], useAlternateReasoning: Bool) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                result.append(["role": "system", "content": message.text])
            case .user:
                // 多模态：图片经 data-URI 内联（vision 兼容格式），无图保持纯文本
                if message.images.isEmpty {
                    result.append(["role": "user", "content": message.text])
                } else {
                    var content: [[String: Any]] = [["type": "text", "text": message.text]]
                    for image in message.images {
                        let base64 = image.data.base64EncodedString()
                        content.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mimeType);base64,\(base64)"]
                        ])
                    }
                    result.append(["role": "user", "content": content])
                }
            case .assistant:
                var item: [String: Any] = ["role": "assistant"]
                if let reasoning = message.continuation?.reasoningContent {
                    item["reasoning_content"] = reasoning
                } else if useAlternateReasoning, let reasoning = message.continuation?.alternateReasoning {
                    item["reasoning"] = reasoning
                }
                if !message.text.isEmpty {
                    item["content"] = message.text
                }
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.argumentsJSON]
                        ]
                    }
                }
                result.append(item)
            case .toolResult:
                result.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallId ?? "",
                    "content": message.text
                ])
            }
        }
        return result
    }

    private func anthropicMessages(from messages: [EngineMessage]) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                // 多模态：图片转 Anthropic image 内容块（base64 source），无图保持纯文本
                if message.images.isEmpty {
                    result.append(["role": "user", "content": message.text])
                } else {
                    var blocks: [[String: Any]] = [["type": "text", "text": message.text]]
                    for image in message.images {
                        blocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": image.mimeType,
                                "data": image.data.base64EncodedString()
                            ]
                        ])
                    }
                    result.append(["role": "user", "content": blocks])
                }
            case .assistant:
                if let raw = message.continuation?.anthropicBlocksJSON {
                    try LLMResponseLimits.check(raw, limit: LLMResponseLimits.responseBytes)
                    guard let blocks = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
                        throw LLMError.responseParsingFailed(reason: "Invalid saved Anthropic content blocks")
                    }
                    result.append(["role": "assistant", "content": blocks])
                    continue
                }
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty {
                    blocks.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [String: Any]()
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input
                    ])
                }
                result.append(["role": "assistant", "content": blocks])
            case .toolResult:
                let blocks: [[String: Any]] = [[
                    "type": "tool_result",
                    "tool_use_id": message.toolCallId ?? "",
                    "content": message.text
                ]]
                result.append(["role": "user", "content": blocks])
            }
        }
        return result
    }

    // MARK: - Response Parsing

    private func parseOpenAIReply(_ json: [String: Any]) throws -> ChatReply {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ChatReply(text: "", toolCalls: [])
        }
        let content = message["content"] as? String ?? ""
        // 兜底：推理模型耗尽补全预算时 content 为 null，思考内容在 reasoning_content / reasoning
        let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String) ?? ""
        let usedBackfill = content.isEmpty && !reasoning.isEmpty
        let text = usedBackfill ? reasoning : content
        var calls: [ToolCallRaw] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                calls.append(ToolCallRaw(
                    id: call["id"] as? String ?? UUID().uuidString,
                    name: name,
                    argumentsJSON: function["arguments"] as? String ?? "{}"
                ))
            }
        }
        let usage = json["usage"] as? [String: Any]
        return ChatReply(
            text: text,
            toolCalls: calls,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int,
            finishReason: choices.first?["finish_reason"] as? String,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            textUsedReasoningBackfill: usedBackfill,
            usage: {
                var result = ProviderTokenUsage.decode(usage, anthropic: isAnthropic)
                result.reportedModel = json["model"] as? String
                return result
            }(),
            continuation: EngineContinuation(reasoningContent: message["reasoning_content"] as? String,
                                             alternateReasoning: message["reasoning"] as? String)
        )
    }

    private func parseAnthropicReply(_ json: [String: Any]) throws -> ChatReply {
        guard let blocks = json["content"] as? [[String: Any]] else {
            return ChatReply(text: "", toolCalls: [])
        }
        var text = ""
        // thinking 块：正文为空时兜底（预算耗尽在思考上时无 text 块）
        var thinkingText = ""
        var calls: [ToolCallRaw] = []
        for block in blocks {
            let type = block["type"] as? String
            if type == "text", let value = block["text"] as? String {
                text += value
                    try LLMResponseLimits.check(text)
            } else if type == "thinking", let value = block["thinking"] as? String {
                thinkingText += value
                    try LLMResponseLimits.check(thinkingText)
            } else if type == "tool_use", let name = block["name"] as? String {
                guard let id = block["id"] as? String, !id.isEmpty else {
                    throw LLMError.responseParsingFailed(reason: "Tool block is missing its identity")
                }
                let input = block["input"] as? [String: Any] ?? [:]
                let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                calls.append(ToolCallRaw(
                    id: id,
                    name: name,
                    argumentsJSON: String(data: inputData, encoding: .utf8) ?? "{}"
                ))
            }
        }
        let usage = json["usage"] as? [String: Any]
        let usedBackfill = text.isEmpty && !thinkingText.isEmpty
        return ChatReply(
            text: usedBackfill ? thinkingText : text,
            toolCalls: calls,
            promptTokens: Self.usageCounts(usage, anthropic: true).input,
            completionTokens: usage?["output_tokens"] as? Int,
            finishReason: json["stop_reason"] as? String,
            reasoning: thinkingText.isEmpty ? nil : thinkingText,
            textUsedReasoningBackfill: usedBackfill,
            usage: {
                var result = ProviderTokenUsage.decode(usage, anthropic: isAnthropic)
                result.reportedModel = json["model"] as? String
                return result
            }(),
            continuation: EngineContinuation(anthropicBlocksJSON:
                String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self))
        )
    }
}
