import Foundation

/// Advisory classification only. Unknown or malformed domains fall back to ordinary discovery.
public protocol IntentClassifying: Sendable {
    func classifyIntent(_ query: String, timeout: TimeInterval) async throws -> String?
}

enum AutomaticWorkflowDecision {
    static func resolve(route: LocalIntentRoute?, query: String, previous: ChatMode) -> ChatMode {
        let text = String(query.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ToolRoutingHints.browserInteraction(text), !isEngineeringRequest(text), !ToolRoutingHints.explicitExecution(text) {
            return .chat
        }
        if route?.domains.contains(.coding) == true { return .coding }
        // The small model sometimes labels software repair as execution. Keep a conservative
        // engineering fallback, without expanding tools, permissions or execution authority.
        let uncertain = route == nil || route?.domains == [.execution] || route?.domains == [.unknown]
        if uncertain, isEngineeringRequest(text) { return .coding }
        if previous == .coding, route == nil || route?.domains == [.conversation] || route?.domains == [.unknown],
           ["继续", "继续。", "继续吧", "接着做", "再试一次", "修好它", "continue", "continue.", "go on", "try again", "fix it"].contains(text) {
            return .coding
        }
        return .chat
    }

    private static func isEngineeringRequest(_ text: String) -> Bool {
        let chineseAction = ["修复", "修正", "编译", "构建", "单元测试", "重构", "实现", "改代码", "写代码", "编程"].contains { text.contains($0) }
        let chineseTarget = ["代码", "函数", "程序", "项目", "仓库", "组件", "编译", "构建"].contains { text.contains($0) }
        let englishAction = text.range(of: #"\b(fix|debug|refactor|implement|compile|build|test|patch)\b"#, options: .regularExpression) != nil
        let englishTarget = text.range(of: #"\b(code|function|software|app|project|repository|repo|compiler|crash|bug|tests?)\b|\.(swift|py|tsx?|jsx?|rs|go|cpp)\b"#, options: .regularExpression) != nil
        return (chineseAction || englishAction) && (chineseTarget || englishTarget)
    }
}

/// Public weights and non-private preferences only. Routing inputs/results have no global cache.
public struct LocalIntentRoutingSettings: Sendable, Equatable {
    public static let enabledKey = "agroom.intentRouting.enabled"
    public static let modelPathKey = "agroom.intentRouting.modelPath"
    public static let modelFileName = "LFM2.5-350M-Q8_0.gguf"
    public static var defaultModelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AgRoom/models/LFM2.5-350M")
            .appendingPathComponent(modelFileName)
    }
    public var isEnabled: Bool
    public var modelPath: String

    public init(isEnabled: Bool = true, modelPath: String = Self.defaultModelURL.path) {
        self.isEnabled = isEnabled
        self.modelPath = modelPath
    }

    public static func load() -> Self {
        let defaults = UserDefaults.standard
        return Self(isEnabled: defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey),
                    modelPath: defaults.string(forKey: modelPathKey) ?? defaultModelURL.path)
    }
}

enum LocalIntentDomain: String, CaseIterable, Decodable, Hashable, Sendable {
    case conversation, files, coding, execution, knowledge, memory, mail, web, browser
    case reminders, notes, apps, scheduling, agents, database, skills, management, unknown

    var description: String {
        switch self {
        case .conversation: "chat explanations greetings 闲聊 问候 概念解释"
        case .files: "file folder document OCR 文件 文件夹 文档"
        case .coding: "programming source code repository build compile fix test 编程 代码 构建 编译 修复"
        case .execution: "execute shell command Python script 执行 命令 脚本"
        case .knowledge: "saved knowledge retrieval RAG 知识库 检索 已保存资料"
        case .memory: "persistent memory user preference 记忆 偏好"
        case .mail: "mail email inbox attachment 邮件 邮箱 收件箱"
        case .web: "internet search news website 互联网 搜索 新闻"
        case .browser: "browser webpage click form 浏览器 网页操作 点击 表单"
        case .reminders: "reminder todo notification 提醒 待办 通知"
        case .notes: "note recording transcription 笔记 录音 转写"
        case .apps: "native mini app 原生 小应用"
        case .scheduling: "recurring scheduled task report 定时任务 定期报告"
        case .agents: "delegate assistant agent team 智体 委派 团队"
        case .database: "database SQL MySQL 数据库"
        case .skills: "skill reusable workflow 技能 工作流"
        case .management: "backup restore content management 备份 恢复 内容管理"
        case .unknown: "unclear unsupported missing reference 无法确定 缺少指代上下文"
        }
    }

    func matches(tool name: String) -> Bool {
        switch self {
        case .conversation, .unknown: false
        case .files: name.hasPrefix("files_") || ["ocr_recognize", "transcribe_audio", "workspace_folder_draft"].contains(name)
        case .coding: name.hasPrefix("repo_") || name.hasPrefix("project_") || name.hasPrefix("coding_") || name.hasPrefix("files_")
        case .execution: ["shell_run", "python_execute", "skill_run_script"].contains(name)
        case .knowledge: name.hasPrefix("knowledge_")
        case .memory: name.hasPrefix("memory_")
        case .mail: name.hasPrefix("mail_")
        case .web: name.hasPrefix("web_") || name.hasPrefix("docs_")
        case .browser: name.hasPrefix("browser_")
        case .reminders: name.hasPrefix("reminders_") || name == "notify_user"
        case .notes: name.hasPrefix("notes_") || name.hasPrefix("note_") || name == "transcribe_audio"
        case .apps: name.hasPrefix("apps_")
        case .scheduling: name.hasPrefix("schedule_")
        case .agents: name.hasPrefix("agent_") || name == "team_run"
        case .database: name.hasPrefix("sql_") || name.hasPrefix("mysql_")
        case .skills: name.hasPrefix("skill_")
        case .management: ["backup_", "agents_", "sessions_", "knowledge_", "memory_", "skill_"].contains { name.hasPrefix($0) }
        }
    }
}

/// Advisory schema hints from the current request. These never register tools or grant execution.
enum ToolRoutingHints {
    static let browserEntries: Set<String> = ["browser_list", "browser_open", "browser_read"]
    static let executionTools: Set<String> = ["shell_run", "python_execute", "skill_run_script"]

    static func vagueReference(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count <= 80 else { return false }
        return text.range(of: #"^(?:请|請|帮我|幫我)?(?:把)?(?:刚才|剛才|上面|前面)?(?:那个|那個|这个|這個)(?:处理|處理)(?:一下)?[。.!！]?$|^(?:please )?(?:handle|process|do) (?:that|this)(?: one)?[.!]?$"#, options: .regularExpression) != nil
    }

    static func requestsSavedMailDraft(_ query: String, mailContext: Bool) -> Bool {
        let text = String((query.lowercased().components(separatedBy: "\n\n[attached files]").first ?? "").prefix(4_000))
        guard mailContext || ["邮件", "郵件", "邮箱", "信箱", "封", "email", "reply"].contains(where: text.contains) else { return false }
        return text.components(separatedBy: CharacterSet(charactersIn: "，,。.!！;；\n")).contains { clause in
            guard clause.range(of: #"(?:不要|不必|不需要|不用|别|別).{0,10}(?:存|保存)|\b(?:don['’]t|do not|never) save\b"#, options: .regularExpression) == nil else { return false }
            return clause.range(of: #"(?:存成|存为|存為|存入|存到|只存|保存)\s*(?:为|為|一份)?\s*(?:邮件|郵件)?草稿|\bsave (?:it |this |the reply )?(?:as )?(?:a )?draft\b"#, options: .regularExpression) != nil
        }
    }

    static func prohibitsMailDelivery(_ query: String) -> Bool {
        let text = String((query.lowercased().components(separatedBy: "\n\n[attached files]").first ?? "").prefix(4_000))
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。.!！;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let prohibitions = ["先别发", "先別發", "先不发", "先不發", "先不用发", "先不用發", "先不要发", "先不要發", "先别寄", "先別寄", "别发邮件", "別發郵件",
                            "不要发送", "不要發送", "不要寄出", "不要发邮件", "不要寄信", "do not send", "don't send", "don’t send", "do not email", "never send"]
        let draftOnly = ["只存草稿", "只保存草稿", "只写草稿", "只寫草稿", "僅存草稿", "只擬草稿", "draft only", "only save a draft"]
        if clauses.contains(where: { clause in
            let directive = clause.replacingOccurrences(of: #"^(?:请|請|麻烦|麻煩|please\s+)"#, with: "", options: .regularExpression)
            return prohibitions.contains(where: directive.hasPrefix) || draftOnly.contains(where: directive.hasPrefix)
                || directive.range(of: #"\b(?:but |and )(?:do not|don['’]t) send\b"#, options: .regularExpression) != nil
        }) { return true }
        let wantsDraft = text.range(of: #"(?:存成|存为|存為|保存为|保存為|保存|写一份|寫一份|擬個|拟个)\s*(?:邮件|郵件)?草稿|\b(?:draft (?:me )?(?:an? |the )?(?:reply|email)|save (?:it |this |the reply )?(?:as )?(?:a )?draft)\b"#, options: .regularExpression) != nil
        let wantsSend = text.range(of: #"发送|發送|寄出|发出|發出|发给|發給|再发|再發|\b(?:send|deliver)\b"#, options: .regularExpression) != nil
        return wantsDraft && !wantsSend
    }

    /// Explicit retrieval language. A bare domain word (e.g. a question about what email is)
    /// can rank a schema but is not a requirement to access private data.
    static func readSource(_ query: String) -> ToolSourceReceipt.Source? {
        let text = String(query.components(separatedBy: "\n\n[Attached files]").first?.prefix(4_000) ?? "").lowercased()
        let mail = text.range(of: #"(?:(?:查|搜|找|读取|讀取|查看).{0,14}(?:收件箱|收件匣|邮箱|信箱|邮件|郵件)|(?:邮箱里|信箱裡|邮件里|郵件裡|邮件中|郵件中|收件箱里|收件匣裡)|\b(?:in|from|search|check|find|read) (?:my |the |last |latest )*(?:inbox|emails?|mailbox)\b)"#, options: .regularExpression) != nil
        let knowledge = text.range(of: #"(?:(?:查|搜|找|检索|檢索).{0,12}(?:知识库|知識庫)|知识库里|知識庫裡|知识库中|知識庫中|\b(?:in|from|search|check) (?:my |the )?knowledge base\b)"#, options: .regularExpression) != nil
        let image = text.range(of: #"提取.{0,8}(?:图|圖).{0,4}文|识别图片|辨識圖片|(?:对|對|用|做|运行|執行).{0,10}\bocr\b|\b(?:extract (?:the )?(?:image text|text from)|(?:run|use) ocr)\b"#, options: .regularExpression) != nil
        let sources: [ToolSourceReceipt.Source] = (mail ? [.mail] : []) + (knowledge ? [.knowledge] : []) + (image ? [.image] : [])
        return sources.count == 1 ? sources.first : nil
    }

    static func browserInteraction(_ query: String) -> Bool {
        let text = String(query.prefix(4_000)).lowercased()
        let context = text.range(of: #"https?://|\b(browser|website|webpage|portal|oa)\b"#, options: .regularExpression) != nil
            || ["浏览器", "瀏覽器", "网页", "網頁", "网站", "網站"].contains { text.contains($0) }
        let action = ["打开", "打開", "点击", "點擊", "填写", "填寫", "填表", "登录", "登陆", "登入", "提交", "预订", "預訂", "预约", "預約", "订一个", "訂一個", "下单", "下單", "操作", "选择", "選擇"].contains { text.contains($0) }
            || text.range(of: #"\b(open|visit|navigate|click|fill|login|log in|sign in|book|reserve|submit|select|interact)\b"#, options: .regularExpression) != nil
        return context && action
    }

    static func explicitExecution(_ query: String) -> Bool {
        let text = String(query.prefix(4_000)).lowercased()
        return ["脚本", "腳本", "命令行", "执行代码", "執行程式"].contains { text.contains($0) }
            || text.range(of: #"\b(shell|python|bash|zsh|powershell|script|command)\b"#, options: .regularExpression) != nil
    }

    static func relativeDate(_ query: String) -> Bool {
        let text = String(query.prefix(4_000)).lowercased()
        return ["今天", "今日", "明天", "后天", "後天", "昨天", "前天", "今晚", "明晚", "本周", "这周", "這週", "下周", "下週", "上周", "上週", "本月", "下月", "上月", "今年", "明年", "去年"].contains { text.contains($0) }
            || text.range(of: #"\b(today|tomorrow|yesterday|tonight|now|(?:next|last|this) (?:week|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#, options: .regularExpression) != nil
    }

    static func currentDateQuestion(_ query: String) -> Bool {
        let text = String(query.prefix(4_000)).lowercased()
        return ["几号", "幾號", "几月", "幾月", "星期几", "星期幾", "几点", "幾點", "当前日期", "目前日期", "现在时间", "現在時間"].contains { text.contains($0) }
            || text.range(of: #"\b(current (?:date|time)|what (?:date|day|time))\b"#, options: .regularExpression) != nil
    }
}

struct LocalIntentRoute: Sendable, Equatable {
    let domains: Set<LocalIntentDomain>

    static func fallback(query: String, hasAudio: Bool = false) -> Self? {
        ToolCatalog.hasAction(in: query) || hasAudio || ToolRoutingHints.browserInteraction(query) || ToolRoutingHints.vagueReference(query)
            ? Self(domains: [.unknown]) : nil
    }

    static let coreTools: Set<String> = ["ask_user"]
    private static let starters: Set<String> = [
        "files_list", "files_read", "files_read_range", "repo_search", "project_inspect",
        "knowledge_search", "mail_search", "mail_read", "mail_list", "web_search", "web_fetch",
        "browser_list", "browser_open", "browser_read", "reminders_list", "reminders_create",
        "notes_search", "notes_list", "apps_schema", "apps_prepare"
    ]

    /// Caps direct schema cost while keeping every other registered tool discoverable.
    func directToolNames(definitions: [ToolDefinition], query: String, companions: Set<String> = [],
                         schemaBudget: Int = 4_096) -> Set<String> {
        if companions.isEmpty, ToolRoutingHints.vagueReference(query) {
            guard let ask = definitions.first(where: { $0.name == "ask_user" }),
                  TokenEstimator.estimate(messages: [], tools: [ask, ToolSearchTool.schema, ToolInvokeTool().definition]) <= schemaBudget else { return [] }
            return ["ask_user"]
        }
        let browser = ToolRoutingHints.browserInteraction(query)
        let recommendsExecution = !browser || ToolRoutingHints.explicitExecution(query)
        let dateQuestion = ToolRoutingHints.currentDateQuestion(query)
        let request = String(query.prefix(4_000)).lowercased()
        let words = KnowledgeRanker.tokenize(request)
        let matching = definitions.compactMap { tool -> (String, Int)? in
            guard recommendsExecution || !ToolRoutingHints.executionTools.contains(tool.name) else { return nil }
            let alias = ToolCatalog.aliasScore(name: tool.name, query: request)
            guard alias > 0 || domains.contains(where: { $0.matches(tool: tool.name) }) else { return nil }
            let text = (tool.name + " " + tool.description).lowercased()
            let score = words.reduce(Self.starters.contains(tool.name) ? 20 : 0) {
                $0 + (text.contains($1) ? min(12, $1.count) : 0)
            }
            return (tool.name, alias * 10 + score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let chatOnly = domains.isSubset(of: [.conversation, .unknown]) && matching.isEmpty && !browser && !dateQuestion
        let time = !domains.isDisjoint(with: [.mail, .web, .browser, .reminders, .scheduling])
            || (!chatOnly && ToolRoutingHints.relativeDate(query)) || dateQuestion
        let priority = (chatOnly ? [] : Self.coreTools).union(browser ? ToolRoutingHints.browserEntries : [])
            .union(time ? ["get_current_time"] : []).union(companions)
        let byName = Dictionary(definitions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var names = Set<String>()
        var remaining = schemaBudget - TokenEstimator.estimate(messages: [], tools: [ToolSearchTool.schema, ToolInvokeTool().definition])
        var domainCount = 0
        for name in priority.sorted() + matching.map(\.0) where !names.contains(name) {
            guard let definition = byName[name], priority.contains(name) || domainCount < 12 else { continue }
            let cost = TokenEstimator.estimate(messages: [], tools: [definition])
            guard cost <= remaining else { continue }
            remaining -= cost
            names.insert(name)
            if !priority.contains(name) { domainCount += 1 }
        }
        return names
    }

    func selectedSkills(from candidates: [Skill], preferred: Set<String>, query: String) -> [Skill] {
        // The model never selects IDs or activates skills. Rank only current-space metadata.
        let query = query.lowercased()
        let candidates = candidates.filter { $0.isEnabled && !$0.name.isEmpty }
        let pinned = candidates.filter {
            preferred.contains($0.name) || query.contains($0.name.lowercased())
                || (!$0.alias.isEmpty && query.contains($0.alias.lowercased()))
        }
        guard !domains.isSubset(of: [.conversation, .unknown]) else { return pinned }
        let words = KnowledgeRanker.tokenize(query)
        let domainWords = KnowledgeRanker.tokenize(domains.map(\.description).joined(separator: " "))
        func score(_ skill: Skill) -> Int {
            let text = (skill.name + " " + skill.alias + " " + skill.description).lowercased()
            return words.reduce(0) { $0 + (text.contains($1) ? 4 * min(12, $1.count) : 0) }
                + domainWords.reduce(0) { $0 + (text.contains($1) ? min(12, $1.count) : 0) }
        }
        let pinnedNames = Set(pinned.map(\.name))
        let ranked = candidates.filter { !pinnedNames.contains($0.name) && score($0) > 0 }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
        let selected = pinnedNames.union(ranked.prefix(max(0, 3 - pinned.count)).map(\.name))
        return candidates.filter { selected.contains($0.name) }
    }
}

/// One read-only process per classification. No conversation, prompt or KV state crosses runs/spaces.
struct LocalIntentRouter: IntentClassifying {
    enum Failure: Error { case invalidOutput, inferenceFailed }
    let modelURL: URL
    let executableURL: URL

    func classifyIntent(_ query: String, timeout: TimeInterval) async throws -> String? {
        try await classify(query: query, timeout: timeout)?.domains.first?.rawValue
    }

    static func available(settings: LocalIntentRoutingSettings = .load()) -> Self? {
        guard settings.isEnabled else { return nil }
        let model = URL(fileURLWithPath: settings.modelPath).standardizedFileURL.resolvingSymlinksInPath()
        guard model.pathExtension.lowercased() == "gguf", FileManager.default.isReadableFile(atPath: model.path),
              let handle = try? FileHandle(forReadingFrom: model) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("GGUF".utf8),
              let executable = bundledExecutableURL() else { return nil }
        return Self(modelURL: model, executableURL: executable)
    }

    static func bundledExecutableURL() -> URL? {
        // The helpers share the same pinned, signed llama.cpp libraries.
        LocalKnowledgeEmbedder.bundledExecutableURL()?
            .deletingLastPathComponent().appendingPathComponent("llama-intent")
            .flatMapExistingExecutable()
    }

    func classify(query: String, timeout: TimeInterval = 8) async throws -> LocalIntentRoute? {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.count <= 4_000, timeout > 0 else { return nil }
        let prompt = Self.prompt(query: query)
        guard prompt.utf8.count <= 32_768 else { return nil }
        let result = await ChildProcessRunner.run(.init(executable: executableURL,
            arguments: [modelURL.path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
            standardInputData: Data(prompt.utf8), timeout: min(8, timeout), outputLimit: 16_384,
            label: "local-intent-routing"))
        try Task.checkCancellation()
        if result.outcome.isCancelled { throw CancellationError() }
        guard result.succeeded else { throw Failure.inferenceFailed }
        return try Self.decode(result.stdout)
    }

    static func prompt(query: String) -> String {
        func escaped(_ request: String) -> String {
            // Keep natural-language requests readable without allowing injected ChatML boundaries.
            request.replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
        }
        let domains = LocalIntentDomain.allCases.map { "\($0.rawValue): \($0.description)" }.joined(separator: "\n")
        let system = "Classify the primary intent of the final user request. Return only a JSON object with one key domain. "
            + "Do not answer or perform the task. Choose unknown when references lack context. "
            + "Choose conversation for ordinary chat without tool needs. Choose coding for fixing software bugs or compile/build errors. "
            + "Choose execution only for explicit shell/Python execution.\nAllowed domains:\n" + domains
        let examples: [(String, LocalIntentDomain)] = [
            ("谢谢你的帮助", .conversation), ("查看收件箱", .mail),
            ("查找知识库中的旅游资料", .knowledge), ("给这个函数写单元测试", .coding),
            ("修正应用程序的构建失败", .coding), ("列出下载目录的子文件夹", .files),
            ("添加一个周五到期的待办事项", .reminders), ("查网络上关于火星的资料", .web),
            ("用已有技能做一个教程", .skills), ("把那个弄一下", .unknown)
        ]
        let demonstrations = examples.map { request, domain in
            "<|im_start|>user\n" + escaped(request) + "<|im_end|>\n<|im_start|>assistant\n"
                + "{\"domain\":\"\(domain.rawValue)\"}<|im_end|>\n"
        }.joined()
        return "<|startoftext|><|im_start|>system\n" + system + "<|im_end|>\n" + demonstrations
            + "<|im_start|>user\n" + escaped(query) + "<|im_end|>\n<|im_start|>assistant\n"
    }

    static func decode(_ output: String) throws -> LocalIntentRoute? {
        struct Payload: Decodable { let domain: LocalIntentDomain }
        guard output.utf8.count <= 4_096, let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["domain"],
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.invalidOutput
        }
        guard payload.domain != .unknown else { return nil }
        return LocalIntentRoute(domains: [payload.domain])
    }
}

private extension URL {
    func flatMapExistingExecutable() -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? self : nil
    }
}
