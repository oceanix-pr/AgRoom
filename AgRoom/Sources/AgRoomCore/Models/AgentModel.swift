import Foundation

// MARK: - Agent

/// 智体（子 Agent）模型：存在于单一空间内，可被调度 Agent 编排调用
public struct Agent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// 昵称（选填）：UI 与委派名册中的显示名；空则显示 name
    public var nickname: String
    public var icon: String
    public var description: String
    /// 智体的系统提示词（人设/职责），编辑页以「简介」呈现
    public var systemPrompt: String
    /// 性格设定（空 = 未设置）：影响语气与开场问候；可选值见 personalities
    public var personality: String
    /// 说话风格设定（空 = 未设置）：影响表达方式；可选值见 speakingStyles
    public var speakingStyle: String
    /// 独立提供商；nil 继承本轮主调度提供商。身份只引用全局配置，不保存凭据。
    public var providerID: UUID?
    /// 指定模型（空则用所选提供商默认模型）
    public var modelName: String
    /// 委派任务给该智体时，是否自动附带知识库相关条目（按智体开关，P2）
    public var knowledgeEnabled: Bool
    public var isEnabled: Bool
    /// 挂载的技能名列表（空 = 不限制，全部可用技能；非空 = 仅列出的技能对智体开放）
    public var skillNames: [String]
    public var createdAt: Date
    public var updatedAt: Date

    /// 可选性格（产品设定的固定枚举值，中文即规范值）
    public static let personalities = ["温柔", "幽默", "有耐心", "严谨", "热情", "冷静", "体贴", "直率", "机智", "可爱"]
    /// 可选说话风格
    public static let speakingStyles = ["专业", "活泼有趣", "正式礼貌", "轻松日常", "幽默风趣", "温暖鼓励", "条理分明", "文艺优雅"]

    public init(
        id: UUID = UUID(),
        name: String,
        nickname: String = "",
        icon: String = "🤖",
        description: String = "",
        systemPrompt: String = "",
        personality: String = "",
        speakingStyle: String = "",
        modelName: String = "",
        providerID: UUID? = nil,
        knowledgeEnabled: Bool = true,
        isEnabled: Bool = true,
        skillNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.icon = icon
        self.description = description
        self.systemPrompt = systemPrompt
        self.personality = personality
        self.speakingStyle = speakingStyle
        self.modelName = modelName
        self.providerID = providerID
        self.knowledgeEnabled = knowledgeEnabled
        self.isEnabled = isEnabled
        self.skillNames = skillNames
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 显示名：昵称优先，空则用名称（列表/名册展示）
    public var displayName: String { nickname.isEmpty ? name : nickname }

    // MARK: - Codable（旧数据兼容：新增字段缺省解码）

    enum CodingKeys: String, CodingKey {
        case id, name, nickname, icon, description, systemPrompt, personality, speakingStyle, modelName
        case knowledgeEnabled, isEnabled, skillNames, createdAt, updatedAt, providerID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        icon = try c.decode(String.self, forKey: .icon)
        description = try c.decode(String.self, forKey: .description)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        speakingStyle = try c.decodeIfPresent(String.self, forKey: .speakingStyle) ?? ""
        modelName = try c.decode(String.self, forKey: .modelName)
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        knowledgeEnabled = try c.decode(Bool.self, forKey: .knowledgeEnabled)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        skillNames = try c.decodeIfPresent([String].self, forKey: .skillNames) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// 人设提示词片段：性格 + 说话风格 + 招呼语规则。
    /// 未设置任何性格/风格时返回空串（不注入，行为与旧版一致）。
    /// 招呼语要求：每次回答以一句含名字、表达"来帮您"之意的问候开场，
    /// 措辞每次不同且贴合性格（由模型即兴变化，而非固定模板）
    public var personaPromptFragment: String {
        guard !personality.isEmpty || !speakingStyle.isEmpty else { return "" }
        var lines = ["\n\n## Persona"]
        if !personality.isEmpty {
            lines.append("Your personality: \(personality). Let it shape your tone, word choice and warmth.")
        }
        if !speakingStyle.isEmpty {
            lines.append("Your speaking style: \(speakingStyle). Keep it consistent throughout the response.")
        }
        lines.append(
            """
            SIGNATURE GREETING (mandatory on EVERY response): begin with ONE short Chinese greeting line \
            that includes your name "\(displayName)" and conveys "来帮您" (here to help you). \
            Vary the wording every time — never repeat an earlier greeting verbatim — \
            and phrase it to match your personality, e.g. 严谨 → "我是\(displayName)，来帮您处理。"; \
            可爱 → "\(displayName)来帮您啦～"; 幽默 → "\(displayName)这就来帮您搞定！". \
            After the greeting, answer the task directly.
            """
        )
        return lines.joined(separator: "\n")
    }

    /// 作为调度 Agent 工具时的工具名（ASCII 安全）
    public var toolName: String {
        let slug = name
            .lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        return "agent_\(String(slug.prefix(40)))"
    }
}
