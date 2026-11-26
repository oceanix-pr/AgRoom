import Foundation

// MARK: - Dispatcher Persona

/// 调度 Agent 人设预设：影响回答风格/语气/详细程度，以 [Persona] 段注入系统提示词
public enum DispatcherPersona: String, CaseIterable, Sendable {
    /// 标准（无额外人设指令，保持默认调度行为）
    case standard
    /// 简洁高效
    case concise
    /// 详细讲解
    case detailed
    /// 专业顾问
    case professional
    /// 创意伙伴
    case creative
    /// 自定义（用户自由描述，文本存 personaCustomText）
    case custom

    /// 人设指令片段（standard/custom 返回 nil：custom 由用户文本提供）
    public var promptFragment: String? {
        switch self {
        case .standard, .custom:
            return nil
        case .concise:
            return "Be concise and efficient: keep answers short and to the point, prefer lists over prose, "
                + "lead with the direct answer, add only essential detail, and avoid filler or unnecessary caveats."
        case .detailed:
            return "Be a thorough explainer: structure answers with headings or numbered steps, explain the "
                + "reasoning behind conclusions, include concrete examples, and point out common pitfalls."
        case .professional:
            return "Act as a professional consultant: use a formal, structured tone; start with a summary or "
                + "conclusion, support claims with evidence from tools or stored knowledge, and clearly separate facts from assumptions."
        case .creative:
            return "Act as a creative partner: brainstorm multiple diverse options before converging, use vivid "
                + "language, suggest unconventional angles, and build on the user's ideas."
        }
    }
}

// MARK: - Dispatcher Settings

/// 调度引擎可调参数：设置页通过 UserDefaults 写入，引擎组装/消息窗口裁剪时读取。
/// 未设置或越界时回退默认值（temperature=0.7 / maxTokens=2048 / maxSteps=20 / 历史 10 条）
public enum DispatcherSettings {
    public static let temperatureKey = "agroom.dispatcher.temperature"
    public static let maxTokensKey = "agroom.dispatcher.maxTokens"
    public static let maxStepsKey = "agroom.dispatcher.maxSteps"
    public static let historyWindowKey = "agroom.dispatcher.historyWindow"

    /// 昵称（用户可改；空/空白 = 各展示点回退本地化默认名）。
    /// 同时作为模型自报名注入系统提示词（见 dispatcherPromptName）；不参与任何工具协议语义
    public static let nicknameKey = "agroom.dispatcher.nickname"

    /// 当前昵称（原始存储；展示时由 UI 层 trim 并回退默认名）
    public static var nickname: String {
        get { UserDefaults.standard.string(forKey: nicknameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nicknameKey) }
    }

    /// 注入系统提示词的自身称呼：昵称 trim 后非空才返回，否则 nil（提示词保持默认 Dispatcher Agent）。
    /// 面向模型故不本地化；守护进程的 UserDefaults 域不同，需经 DaemonRunSettings.dispatcherName 显式携带
    public static var dispatcherPromptName: String? {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 采样温度（0 = 确定性，越高越发散）
    public static var temperature: Double {
        guard let value = UserDefaults.standard.object(forKey: temperatureKey) as? Double,
              (0...2).contains(value) else { return 0.7 }
        return value
    }

    /// 单次模型请求补全上限（max_tokens；上限 1M 覆盖长输出模型）
    public static var maxTokens: Int {
        guard let value = UserDefaults.standard.object(forKey: maxTokensKey) as? Int,
              (256...1048576).contains(value) else { return 2048 }
        return value
    }

    /// 单轮对话工具步数预算
    public static var maxSteps: Int {
        guard let value = UserDefaults.standard.object(forKey: maxStepsKey) as? Int,
              (2...200).contains(value) else { return 20 }
        return value
    }

    /// 智体（子代理）单次委派的步数预算
    public static let subagentMaxStepsKey = "agroom.dispatcher.subagentMaxSteps"
    public static var subagentMaxSteps: Int {
        guard let value = UserDefaults.standard.object(forKey: subagentMaxStepsKey) as? Int,
              (2...100).contains(value) else { return 8 }
        return value
    }

    /// 多智体协作（team_run）开关。默认关闭：P0 是只读 Beta，
    /// 只有用户显式开启后才向模型公布 team_run，避免无意识增加 token 成本。
    public static let teamTasksEnabledKey = "agroom.dispatcher.teamTasksEnabled"
    public static var teamTasksEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: teamTasksEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: teamTasksEnabledKey) }
    }

    /// 团队写文件开关（默认关闭）：即使开启，每次写入仍需任务板逐次审批，
    /// 且只允许写当前会话工作区内的 UTF-8 文本文件。
    public static let teamWritesEnabledKey = "agroom.dispatcher.teamWritesEnabled"
    public static var teamWritesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: teamWritesEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: teamWritesEnabledKey) }
    }

    /// 定时任务总开关（默认关闭）：关闭时不扫描到期任务，也不允许手动运行。
    public static let scheduledTasksEnabledKey = "agroom.dispatcher.scheduledTasksEnabled"
    public static var scheduledTasksEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: scheduledTasksEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: scheduledTasksEnabledKey) }
    }

    /// 发送给引擎的历史消息窗口（条数）
    public static var historyWindow: Int {
        guard let value = UserDefaults.standard.object(forKey: historyWindowKey) as? Int,
              (2...500).contains(value) else { return 10 }
        return value
    }

    // MARK: 会话模式参数（聊天沿用上面全局键；编码模式独立键 + 独立默认值）

    public static let codingMaxTokensKey = "agroom.dispatcher.coding.maxTokens"
    public static let codingTemperatureKey = "agroom.dispatcher.coding.temperature"
    public static let codingMaxStepsKey = "agroom.dispatcher.coding.maxSteps"
    public static let codingHistoryWindowKey = "agroom.dispatcher.coding.historyWindow"

    /// 编码模式默认参数：更长输出、更低温度、更多步数、更大历史窗口。
    /// 编码需要一次写完整个文件、按步骤改多个文件，聊天默认值（2048/20）会直接截断或提前收尾
    public enum CodingDefaults {
        public static let maxTokens = 16_384
        public static let temperature = 0.2
        public static let maxSteps = 60
        public static let historyWindow = 30
        public static let historyTokenBudget = 60_000
    }

    /// 会话模式对应的单次补全上限
    public static func maxTokens(for mode: ChatMode) -> Int {
        guard mode == .coding else { return Self.maxTokens }
        guard let value = UserDefaults.standard.object(forKey: codingMaxTokensKey) as? Int,
              (256...1048576).contains(value) else { return CodingDefaults.maxTokens }
        return value
    }

    /// 会话模式对应的采样温度
    public static func temperature(for mode: ChatMode) -> Double {
        guard mode == .coding else { return Self.temperature }
        guard let value = UserDefaults.standard.object(forKey: codingTemperatureKey) as? Double,
              (0...2).contains(value) else { return CodingDefaults.temperature }
        return value
    }

    /// 会话模式对应的工具步数预算
    public static func maxSteps(for mode: ChatMode) -> Int {
        guard mode == .coding else { return Self.maxSteps }
        guard let value = UserDefaults.standard.object(forKey: codingMaxStepsKey) as? Int,
              (2...200).contains(value) else { return CodingDefaults.maxSteps }
        return value
    }

    /// 会话模式对应的历史消息窗口（条数）
    public static func historyWindow(for mode: ChatMode) -> Int {
        guard mode == .coding else { return Self.historyWindow }
        guard let value = UserDefaults.standard.object(forKey: codingHistoryWindowKey) as? Int,
              (2...500).contains(value) else { return CodingDefaults.historyWindow }
        return value
    }

    /// 历史窗口的 token 兜底预算（粗估）：编码任务上下文更长，聊天保持保守值
    public static func historyTokenBudget(for mode: ChatMode) -> Int {
        mode == .coding ? CodingDefaults.historyTokenBudget : 24_000
    }

    // MARK: 思考力度（对话栏下拉）

    public static let reasoningEffortKey = "agroom.chat.reasoningEffort"

    /// 当前思考力度（未设置或值非法时回退 standard）
    public static var reasoningEffort: ReasoningEffort {
        guard let raw = UserDefaults.standard.string(forKey: reasoningEffortKey),
              let value = ReasoningEffort(rawValue: raw) else { return .standard }
        return value
    }

    // MARK: Persona（人设）

    public static let personaKey = "agroom.dispatcher.persona"
    public static let personaCustomTextKey = "agroom.dispatcher.personaCustomText"

    /// 当前人设（未设置或值非法时回退 standard）
    public static var persona: DispatcherPersona {
        guard let raw = UserDefaults.standard.string(forKey: personaKey),
              let value = DispatcherPersona(rawValue: raw) else { return .standard }
        return value
    }

    /// 自定义人设描述文本
    public static var personaCustomText: String {
        UserDefaults.standard.string(forKey: personaCustomTextKey) ?? ""
    }

    /// 最终注入系统提示词的人设指令：预设取片段；custom 取用户文本；standard 无指令
    public static var personaInstruction: String? {
        switch persona {
        case .standard:
            return nil
        case .custom:
            let text = personaCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "Follow this persona: \(text)"
        default:
            return persona.promptFragment
        }
    }

    // MARK: 默认权限模式

    public static let defaultPermissionModeKey = "agroom.dispatcher.defaultPermissionMode"

    /// 新建会话的默认权限模式（未设置/值非法时回退工作区内修改）。
    /// 只影响新会话；已有会话的 permissionMode 不会被设置变化改写。
    public static var defaultPermissionMode: PermissionMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultPermissionModeKey),
              let mode = PermissionMode(rawValue: raw) else {
            return .workspaceWrite
        }
        return mode
    }

    // MARK: 自动生成记忆

    public static let autoMemoryEnabledKey = "agroom.dispatcher.autoMemory"

    /// 是否在对话累积到一定轮数后后台自动提炼长期记忆（默认开启）
    public static var autoMemoryEnabled: Bool {
        guard let value = UserDefaults.standard.object(forKey: autoMemoryEnabledKey) as? Bool else {
            return true
        }
        return value
    }
}
