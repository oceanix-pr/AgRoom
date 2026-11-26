import Foundation

// MARK: - Agent Generator（智体人设 AI 生成）

/// 智体人设生成器：一句话需求 → 智体六字段草稿（名称/昵称/简介/性格/说话风格/图标）。
/// 复用 SkillGenerator 的 JSON 容错链（剥围栏/思考标签/花括号截取/瑕疵修复），
/// 输出字段经枚举校验收敛——personality/speakingStyle 必须命中固定枚举，幻觉空间极小。
/// 生成结果填充表单供用户审阅修改，不直接落盘
public struct AgentGenerator: Sendable {

    /// 生成的智体草稿：字段语义与 Agent 模型一一对应，icon 由 UI 目录校验
    public struct AgentDraft: Sendable, Equatable {
        public let name: String
        public let nickname: String
        public let systemPrompt: String
        /// 空串 = 未命中枚举，UI 回退"未设置"
        public let personality: String
        /// 空串 = 未命中枚举，UI 回退"未设置"
        public let speakingStyle: String
        public let icon: String
    }

    public enum GeneratorError: Error, Equatable, LocalizedError {
        case emptyOutput
        case invalidJSON

        public var errorDescription: String? {
            switch self {
            case .emptyOutput:
                return "The model returned an empty response. Try again or switch models."
            case .invalidJSON:
                return "The model output could not be parsed as an agent definition"
            }
        }
    }

    let provider: CloudProvider

    /// 生成配置：六字段 JSON 很小，8192 足够（思考型模型留推理裕量）
    static let config = LLMConfig(maxTokens: 8192, temperature: 0.7)

    public init(provider: CloudProvider) {
        self.provider = provider
    }

    /// 生成智体草稿。onDelta：SSE 流式增量（调用方据此实时展示）
    public func generate(
        requirement: String,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentDraft {
        let system = """
        You design sub-agents (delegated assistants) for a macOS AI hub.
        Given the user's requirement, output ONE JSON object with exactly these fields:
        - "name": lowercase letters, numbers and hyphens only, max 64 chars, concise agent id
        - "nickname": short display name, 2-8 chars, ANY language (Chinese preferred when the requirement is in Chinese)
        - "system_prompt": the agent's persona and responsibilities, 80-300 words, second person ("你是…"),
          concrete about what it does, its expertise, and how it should answer
        - "personality": MUST be exactly one of: \(Agent.personalities.joined(separator: ", "))
        - "speaking_style": MUST be exactly one of: \(Agent.speakingStyles.joined(separator: ", "))
        - "icon": ONE emoji that best represents the agent
        Output ONLY the JSON object. No markdown fences, no commentary.
        """
        let userText = "Requirement:\n\(requirement)"

        let reply = try await provider.chatStream(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            tools: [],
            config: Self.config,
            onDelta: onDelta ?? { _ in }
        )
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeneratorError.emptyOutput }
        do {
            return try Self.decode(text)
        } catch {
            // 修正重试：把不可解析的输出原样回喂，要求仅输出修正后的完整 JSON
            HubLogger.shared.warning(
                "Agent generation decode failed: stage=initial, responseCharacters=\(text.count), \(HubLogger.safeErrorSummary(error))"
            )
            let repairMessages = [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText),
                EngineMessage(role: .assistant, text: text),
                EngineMessage(role: .user, text: "Your previous output could not be parsed as JSON. Output ONLY the corrected, complete JSON object now. No markdown fences, no commentary.")
            ]
            let repaired = try await provider.chatStream(
                messages: repairMessages,
                tools: [],
                config: Self.config,
                onDelta: onDelta ?? { _ in }
            )
            let repairedText = repaired.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repairedText.isEmpty else { throw GeneratorError.emptyOutput }
            do {
                return try Self.decode(repairedText)
            } catch {
                HubLogger.shared.error(
                    "Agent generation decode failed: stage=repair, responseCharacters=\(repairedText.count), \(HubLogger.safeErrorSummary(error))"
                )
                throw GeneratorError.invalidJSON
            }
        }
    }

    // MARK: - 解码（复用 SkillGenerator 的容错工具）

    /// 容错链：剥思考标签/围栏 → 双重编码解包 → 多候选平衡花括号截取 → 枚举校验收敛
    static func decode(_ raw: String) throws -> AgentDraft {
        var text = SkillGenerator.stripReasoningBlocks(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 双重编码：整体是一个 JSON 字符串字面量 → 解一层再走常规链
        if text.hasPrefix("\""), let data = text.data(using: .utf8),
           let inner = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidates = SkillGenerator.extractTopLevelJSONCandidates(from: text)
        for candidate in candidates {
            if let draft = Self.parseCandidate(candidate) {
                return draft
            }
        }
        throw GeneratorError.invalidJSON
    }

    /// 单候选解析 + 枚举收敛：personality/speakingStyle 不在枚举内置空（UI 显示"未设置"），
    /// icon 取首字符附近的单个 emoji（防御长字符串），name 兜底 slug 化
    private static func parseCandidate(_ jsonText: String) -> AgentDraft? {
        guard let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Self.draft(from: object)
    }

    /// 字典 → 草稿（供测试直接调用）；字段别名兼容（systemPrompt/system_prompt 等）
    static func draft(from object: [String: Any]) -> AgentDraft? {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let name = Skill.slugify(string("name", "agent_name") ?? "generated-agent")
        guard let systemPrompt = string("system_prompt", "systemPrompt", "prompt") else { return nil }
        let rawPersonality = string("personality") ?? ""
        let rawStyle = string("speaking_style", "speakingStyle", "style") ?? ""
        // 枚举收敛：不命中置空（幻觉兜底）
        let personality = Agent.personalities.first { rawPersonality.contains($0) } ?? ""
        let speakingStyle = Agent.speakingStyles.first { rawStyle.contains($0) } ?? ""
        // icon：取首个非空白字符（emoji 单字符或 ZWJ 序列由 UI 目录二次校验）
        let icon = (string("icon", "emoji") ?? "🤖").trimmingCharacters(in: .whitespaces)
        return AgentDraft(
            name: name.isEmpty ? "generated-agent" : String(name.prefix(64)),
            nickname: String((string("nickname", "display_name") ?? "").prefix(16)),
            systemPrompt: String(systemPrompt.prefix(2000)),
            personality: personality,
            speakingStyle: speakingStyle,
            icon: String(icon.prefix(4))
        )
    }
}
