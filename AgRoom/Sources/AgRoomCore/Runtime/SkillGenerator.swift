import Foundation

// MARK: - Skill Generator

/// AI 生成的技能包：SKILL.md 三要素 + 可选的 Python 脚本与 references 参考文档（存入技能文件夹）
public struct GeneratedSkillPackage: Sendable, Equatable {
    public struct ScriptFile: Sendable, Equatable {
        public let path: String
        public let content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    public let skill: Skill
    public let scripts: [ScriptFile]
    /// 参考文档（references/ 下）：领域知识、模板、数据表等渐进式披露第二层内容
    public let references: [ScriptFile]

    public init(skill: Skill, scripts: [ScriptFile] = [], references: [ScriptFile] = []) {
        self.skill = skill
        self.scripts = scripts
        self.references = references
    }
}

/// 用已配置的 LLM 生成符合 Anthropic Agent Skills 标准的技能。
/// 用户提供"技能要做什么"即可：模型产出 SKILL.md（name/description/content/allowed-tools），
/// 需要业务逻辑时同步编写 Python 脚本存入 scripts/，需要内置能力时在 allowed-tools 声明。
/// 需求含糊时模型可先提出一个澄清问题，拿到回答后再产出最终技能包。
public struct SkillGenerator: Sendable {

    /// 一次生成调用的结果：要么是澄清问题，要么是完整技能包
    public enum GenerationResult: Sendable, Equatable {
        /// 澄清：一次可携带 1-3 个待确认问题（用户逐项填写后一次提交）
        case needsClarification(questions: [String])
        case package(GeneratedSkillPackage)
    }

    public enum GeneratorError: Error, Equatable, LocalizedError {
        case emptyOutput
        case invalidJSON

        public var errorDescription: String? {
            switch self {
            case .emptyOutput:
                return "The model returned an empty response. Likely causes: a reasoning model exhausted the token budget on thinking, or the gateway split reasoning into a separate field. Try disabling thinking mode, raising maxTokens, or switching models, then retry."
            case .invalidJSON: return "The model output could not be parsed as a skill definition"
            }
        }
    }

    /// 提示词里的内置工具清单（模型据此声明 allowed-tools 并在正文引用）
    static let availableToolsBrief = """
    - get_current_time: current local date and time
    - memory_search / memory_save: user's long-term memory
    - knowledge_search: search the space knowledge base
    - web_fetch: fetch a web page's readable text
    - docs_collect / docs_read: collect scoped development documentation and read all chunks with source/coverage receipts
    - project_inspect / repo_search / repo_changes / repo_symbols: inspect the bound source project
    - files_list / files_read / files_read_range: read project files
    - files_edit / files_apply_changes / files_move: make controlled project changes
    - project_build: build or test the bound project (separate explicit host approval)
    - sql_query: query the space SQLite database
    - ocr_recognize: extract text from an image file
    - transcribe_audio: transcribe an audio file to text
    - files_write / files_mkdir: create new files or folders inside the conversation workspace; use absolute paths (file_write is a compatibility alias with the same boundary)
    - skill_run_script: run a .py script bundled in this skill folder (preferred way to run Python; the skill folder is the working directory, outputs go to scratch/)
    - python_execute: run an arbitrary Python snippet (needs user confirmation; avoid when logic can live in the skill's own scripts)
    """

    let provider: CloudProvider

    /// 生成/审查/重写阶段的专用配置：技能包 JSON（含脚本全文）动辄超过默认 2048 补全上限，
    /// 截断会导致 JSON 解析失败（"could not be parsed as a skill definition" 的主要成因）。
    /// 思考型模型会先消耗推理预算再输出正文，故给足 16384；
    /// 上限超出模型/网关限制时会 400，CloudProvider 已按错误报文自动钳制重试
    static let packageConfig = LLMConfig(maxTokens: 16384, temperature: 0.7)
    /// 深度思考阶段的配置（≤1500 词）。思考型模型会先输出推理再输出正文，
    /// 4096 会被推理耗尽导致 content 为空（"empty response" 报错的成因），预留双倍裕量
    static let thinkConfig = LLMConfig(maxTokens: 8192, temperature: 0.7)
    /// 修正重试阶段的配置（与 packageConfig 对齐，给足预算避免再截断）
    static let repairConfig = LLMConfig(maxTokens: 16384, temperature: 0.3)

    public init(provider: CloudProvider) {
        self.provider = provider
    }

    /// 深度思考阶段：让模型先流式输出分析文本（需求拆解 → 结构设计 → 脚本规划）。
    /// onDelta 实时回调文本增量（调用方自行切主线程），返回完整思考文本供生成阶段复用。
    /// 空思考不阻塞流程（思考型模型极端情况下可能产出空文本），返回空串由生成阶段按"无思考"降级
    public func think(
        requirement: String,
        knowledgeContext: String?,
        webContext: String? = nil,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let system = """
        You are a senior agent-skill architect. Before a skill package is generated, you think the design through.
        Analyze the user's requirement and produce your reasoning in plain text (no JSON, no markdown fences), in this order:
        1. Requirement breakdown: what the skill must accomplish, inputs, outputs, edge cases.
        2. Trigger design: when the assistant should use this skill (description draft).
        3. Workflow design: the step-by-step instructions the skill body should contain.
        4. Script plan: whether Python scripts are needed; for each, its path, responsibility, key functions, CLI contract (arguments/exit codes), and how outputs land under scratch/.
        5. Tool & knowledge needs: which built-in tools to declare; whether the space knowledge base should be consulted at runtime.
        6. Reference docs plan: which reference files (references/*.md etc.) would make this skill deeper — domain facts, templates, lookup tables, output format specs, checklists. For each: path, purpose, and what content goes in it. Keep SKILL.md body lean and point to these files; prefer 1-3 well-chosen references over many thin ones.
        Be concrete and decisive. Keep it under 1500 words.
        """
        var userText = "Requirement:\n\(requirement)"
        if let knowledgeContext, !knowledgeContext.isEmpty {
            userText += "\n\nKnowledge base excerpts (use as domain facts):\n\(knowledgeContext)"
        }
        if let webContext, !webContext.isEmpty {
            userText += "\n\nWeb research excerpts (from the internet, unverified — treat with care):\n\(webContext)"
        }
        let reply = try await provider.chatStream(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            tools: [],
            config: Self.thinkConfig,
            onDelta: onDelta
        )
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 根据自然语言需求生成技能包（SKILL.md 三要素 + allowed-tools + 可选脚本）。
    /// 需求含糊且已有回答（priorAnswer）时，模型不再提问、直接产出最终技能包。
    /// knowledgeContext：空间知识库摘录（可选，作为领域事实注入）；
    /// webContext：联网检索并经打分门过滤的资料（可选，标注未经核实）；
    /// thinking：think 阶段的思考文本（可选，指导生成更深入的技能包）；
    /// onDelta：生成过程流式增量回调（SSE，调用方据此实时展示）
    public func generateInteractive(
        requirement: String,
        priorAnswer: String?,
        knowledgeContext: String? = nil,
        webContext: String? = nil,
        thinking: String? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult {
        let clarificationRule: String
        if let priorAnswer {
            clarificationRule = """
            The user's answers to your earlier questions:
            \(priorAnswer)
            These items are now resolved — do NOT ask them again. If any other critical unknown remains that would change the output, you may ask again (output {"questions": [...]}); otherwise output the final JSON package now.
            """
        } else {
            clarificationRule = """
            Before producing the package, ask the user about ANY uncertainty that would change the skill's output — do not guess on things you can confirm. Output ONLY:
            {"questions": ["<one concise question>", "<another if needed>", "…"]}
            Ask 1 to 3 questions covering the most impactful uncertain decisions (e.g. input/output scope and edge cases, default placeholder values, target audience/domain, whether a Python script is required). Then STOP — output nothing else until the user answers.
            Only if there is truly no material ambiguity may you skip asking and output the full JSON package directly.
            """
        }
        let system = """
        You generate Agent Skills that follow the Anthropic Agent Skills standard (SKILL.md format).
        Given the user's requirement, output ONE JSON object with exactly these fields:
        - "name": lowercase letters, numbers and hyphens only, max 64 chars, concise skill id
        - "alias": short display name for the skill, 2-16 chars, ANY language (Chinese preferred when the requirement is in Chinese); summarize what the skill does for humans browsing the skill list
        - "description": max 1024 chars, explains what the skill does AND when to use it
        - "allowed_tools": comma-separated tool names this skill needs, ONLY from the available tools list below; omit the field if none is needed. Always include skill_run_script when scripts exist.
        - "content": concise markdown instructions for the assistant — what to do, step-by-step, when to use it. The ENTIRE SKILL.md body must stay within ~1000 tokens (≈2500 chars). Any detail — examples, templates, output-format specs, lookup tables, checklists, domain knowledge — MUST be put into "references" (not the body) and referenced from content by relative path. Never duplicate reference material into the body.
        - "scripts": optional array of {"path": "scripts/<file>.py", "content": "..."} — write these ONLY when Python is the right way to implement the requirement; stdlib only; each under 200 lines; put outputs under scratch/
        - "references": optional array of {"path": "references/<file>.md|.txt|.json|.csv", "content": "..."} — supporting documents that make the skill deeper: domain knowledge, templates, lookup tables, output format specs, checklists. The assistant reads them at runtime via the skill_file tool. If a skill benefits from ANY depth, put it here rather than in "content" so SKILL.md stays small (≤ ~1000 tokens): at least one reference is expected for most skills. Keep each reference focused (under 4000 chars).
        - "variables": optional array of placeholder names, e.g. ["department","meeting_date"] — use when the same skill serves different users/departments/etc. Write {{department}} style placeholders in "content" instead of hardcoding one-off values; list every placeholder name here. The agent fills them from conversation context at runtime.

        Available built-in tools:
        \(Self.availableToolsBrief)

        \(clarificationRule)

        Rules:
        - If Python logic is needed, implement it in "scripts" and instruct the assistant in "content" to run it via skill_run_script. Do NOT use python_execute for logic that belongs to the skill.
        - In "content", reference bundled resources with relative paths (references/…, scripts/…) and tell the assistant to read them with the skill_file tool when needed.
        - Parameterize one-off values as {{placeholders}} and declare them in "variables" rather than baking them into the instructions.
        - Output ONLY the JSON object. No markdown fences, no commentary.
        """
        var userText = requirement
        if let thinking, !thinking.isEmpty {
            userText = """
            Your design reasoning (follow it when producing the package):
            \(thinking)

            Requirement:
            \(requirement)
            """
        }
        if let knowledgeContext, !knowledgeContext.isEmpty {
            userText += "\n\nKnowledge base excerpts (domain facts; reflect them in the skill):\n\(knowledgeContext)"
        }
        if let webContext, !webContext.isEmpty {
            userText += "\n\nWeb research excerpts (from the internet, unverified — use them as hints, never copy them into references as established facts):\n\(webContext)"
        }
        return try await chatForJSON(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            config: Self.packageConfig,
            onDelta: onDelta
        )
    }

    // MARK: - Web Research（联网检索环节：检索词生成 + 相关性打分门）

    /// 打分门阈值：≥ 此分的结果才注入技能生成上下文。
    /// LLM 打分无绝对标度，prompt 中已锚定评分标准；若全灭由调用方降级（无 webContext 继续）
    public static let searchScoreThreshold = 90

    /// 检索词生成配置（轻量、低延迟）
    static let searchQueryConfig = LLMConfig(maxTokens: 2048, temperature: 0.3)
    /// 打分配置（确定性输出）
    static let searchScoreConfig = LLMConfig(maxTokens: 4096, temperature: 0)

    /// 经打分门过滤的单条联网检索结果
    public struct ScoredSearchResult: Sendable, Equatable {
        public let result: WebSearchResult
        public let score: Int
        public let reason: String

        public init(result: WebSearchResult, score: Int, reason: String) {
            self.result = result
            self.score = score
            self.reason = reason
        }
    }

    /// 检索词生成：从需求产出 2-3 组多样化检索词（母语 + 英文 + 领域术语）。
    /// 失败由调用方降级（跳过联网检索），不阻断生成主干
    public func generateSearchQueries(requirement: String) async throws -> [String] {
        let system = """
        You prepare web research for an agent-skill generation task. From the requirement, derive 2-3 diverse search-engine queries: one in the requirement's language, one in English, and optionally one with precise domain terminology. Queries must be self-contained keyword phrases (no filler words, no quotes).
        Output ONE JSON object exactly: {"queries": ["...", "...", "..."]}
        No markdown fences, no commentary.
        """
        let messages = [
            EngineMessage(role: .system, text: system),
            EngineMessage(role: .user, text: "Requirement:\n\(requirement)")
        ]
        let payload = try await chatForDictionary(messages: messages, config: Self.searchQueryConfig)
        let queries = (payload["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
        let cleaned = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
        return Array(cleaned.prefix(3))
    }

    /// 相关性打分门：对候选结果批量打分（单次调用）。
    /// 评分标准锚定在 prompt 中（90+ 直接可复用 / 70-89 相关但泛化 / <70 仅背景），
    /// temperature 0 保证确定性；每条结果必须给出 0-100 的整数分与一句理由。
    /// 缺失条目按 0 分处理，分数统一钳制到 0-100
    public func scoreSearchResults(
        requirement: String,
        results: [WebSearchResult]
    ) async throws -> [ScoredSearchResult] {
        guard !results.isEmpty else { return [] }
        let numbered = results.enumerated().map { index, item in
            "\(index + 1). Title: \(item.title)\n   URL: \(item.url)\n   Snippet: \(item.snippet)"
        }.joined(separator: "\n")
        let system = """
        You are a strict relevance judge for web-search results that will feed an agent-skill generation task.
        Score each candidate 0-100 against the requirement, using this anchored rubric:
        - 90-100: directly on-topic — contains domain facts, exact technical details, or specifications the skill can reuse verbatim.
        - 70-89: related but generic; useful only as background.
        - 40-69: loosely related, topic-adjacent.
        - 0-39: irrelevant or spam.
        Output ONE JSON object exactly: {"scores": [{"index": 1, "score": 95, "reason": "one short sentence"}, ...]}
        One entry per candidate, "index" is the candidate number. No markdown fences, no commentary.
        """
        let userText = "Requirement:\n\(requirement)\n\nCandidates:\n\(numbered)"
        let messages = [
            EngineMessage(role: .system, text: system),
            EngineMessage(role: .user, text: userText)
        ]
        let payload = try await chatForDictionary(messages: messages, config: Self.searchScoreConfig)
        var scores = [Int](repeating: 0, count: results.count)
        var reasons = [String](repeating: "", count: results.count)
        let entries = (payload["scores"] as? [Any]) ?? []
        for entry in entries {
            guard let dict = entry as? [String: Any],
                  let rawIndex = dict["index"] as? Int,
                  results.indices.contains(rawIndex - 1) else { continue }
            let rawScore = dict["score"] as? Int ?? (dict["score"] as? Double).map(Int.init) ?? 0
            scores[rawIndex - 1] = min(max(rawScore, 0), 100)
            reasons[rawIndex - 1] = (dict["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return zip(results, zip(scores, reasons)).map { result, pair in
            ScoredSearchResult(result: result, score: pair.0, reason: pair.1)
        }
    }

    /// 通用 JSON 字典调用：chatAccumulating + decodePayload + 一次修正重试。
    /// 与 chatForJSON 同一套容错策略，但不做技能包字段解析
    private func chatForDictionary(
        messages: [EngineMessage],
        config: LLMConfig
    ) async throws -> [String: Any] {
        let text = try await chatAccumulating(messages: messages, config: config)
        if let payload = try? Self.decodePayload(text) { return payload }
        let repairMessages = messages + [
            EngineMessage(role: .assistant, text: text),
            EngineMessage(role: .user, text: Self.repairPrompt)
        ]
        let repaired = try await chatAccumulating(messages: repairMessages, config: Self.repairConfig)
        guard let payload = try? Self.decodePayload(repaired) else {
            throw GeneratorError.invalidJSON
        }
        return payload
    }

    /// 自我审查（深度模式）：以 checklist 批判初稿并直接输出修订版技能包。
    /// 复用与生成阶段相同的 JSON 输出契约；onDelta：修订过程流式增量回调
    public func review(
        package: GeneratedSkillPackage,
        requirement: String,
        thinking: String?,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GeneratedSkillPackage {
        let system = """
        You are a strict reviewer of Agent Skills (Anthropic SKILL.md format).
        You are given the user's requirement and a DRAFT skill package. Critique it against this checklist:
        1. Executability: is every instruction in "content" concrete and actionable as-is? No vague steps?
        2. Script contract: does "content" reference each script's path and explain its arguments/outputs? Does each script have error handling and a clear exit-code contract? Are outputs written to scratch/?
        3. Edge cases: are failure paths and boundary conditions covered (empty input, missing file, bad encoding)?
        4. Trigger accuracy: does "description" state clearly WHEN to use and when NOT to use the skill?
        5. Tool declarations: is allowed_tools minimal and sufficient? skill_run_script present when scripts exist?
        6. Reference depth: does the skill bury domain facts, templates, or lookup tables inside "content" (or omit them entirely)? Move bulky material into "references" files; add missing reference docs that would deepen the skill; ensure "content" points to them with relative paths.
        7. Size: the ENTIRE SKILL.md body ("content") must stay within ~1000 tokens (≈2500 chars). If it exceeds this, trim the body and push the details into "references".
        Then output the REVISED package as ONE JSON object with exactly these fields:
        - "name", "alias", "description", "allowed_tools", "content", "scripts", "references" (same schema as the draft).
        Output ONLY the JSON object. No markdown fences, no commentary.
        """
        var userText = """
        Requirement:
        \(requirement)

        DRAFT package JSON:
        \(Self.encodePackage(package))
        """
        if let thinking, !thinking.isEmpty {
            userText += "\n\nDesign reasoning the draft was based on:\n\(thinking)"
        }
        let result = try await chatForJSON(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            config: Self.packageConfig,
            onDelta: onDelta
        )
        guard case .package(let revised) = result else {
            throw GeneratorError.invalidJSON
        }
        return revised
    }

    /// 修复未通过语法校验的脚本：把编译错误回喂模型，返回修复后的完整脚本内容
    public func fixScript(
        path: String,
        content: String,
        errorMessage: String
    ) async throws -> String {
        let system = """
        You fix a Python script that failed a py_compile syntax check.
        Return the FULL corrected script content only — no markdown fences, no commentary, no explanation.
        Keep the script's responsibility, CLI contract, and output conventions unchanged.
        """
        let userText = """
        Script path: \(path)

        Failing script:
        \(content)

        Compiler error:
        \(errorMessage)
        """
        let reply = try await provider.chat(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            tools: [],
            // 完整脚本全文常超默认 2048 补全上限（截断会产生半截脚本）
            config: Self.packageConfig
        )
        var text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```python", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw GeneratorError.emptyOutput }
        return text
    }

    /// 序列化技能包为 JSON（审查阶段回喂初稿用）
    static func encodePackage(_ package: GeneratedSkillPackage) -> String {
        struct ScriptPayload: Codable {
            let path: String
            let content: String
        }
        struct Payload: Codable {
            let name: String
            let alias: String
            let description: String
            let allowed_tools: String
            let content: String
            let scripts: [ScriptPayload]
            let references: [ScriptPayload]
        }
        let payload = Payload(
            name: package.skill.name,
            alias: package.skill.alias,
            description: package.skill.description,
            allowed_tools: package.skill.allowedTools,
            content: package.skill.content,
            scripts: package.scripts.map { ScriptPayload(path: $0.path, content: $0.content) },
            references: package.references.map { ScriptPayload(path: $0.path, content: $0.content) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// 重写已有技能：以现有 SKILL.md 与文件清单为上下文，按改进说明重新生成技能包。
    /// usageFeedback：真实使用记录摘要（可选，让重写基于实际运行反馈）
    /// 返回的 package.name 固定为现有技能名（就地覆盖，不产生新技能）；
    /// onDelta：重写过程流式增量回调
    public func rewrite(
        skillName: String,
        currentSKILLMD: String,
        fileList: [String],
        resourceContent: String = "",
        instruction: String,
        knowledgeContext: String?,
        usageFeedback: String? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GeneratedSkillPackage {
        let system = """
        You rewrite an existing Agent Skill (Anthropic SKILL.md format) in place.
        You are given the current SKILL.md, the skill folder's file list and resource contents, the user's improvement instruction, and optional design reasoning.
        Output ONE JSON object with exactly these fields:
        - "name": MUST be exactly "\(skillName)" (in-place rewrite)
        - "alias": short display name, 2-16 chars, ANY language (Chinese preferred when the instruction is in Chinese); refine the existing alias if the SKILL.md has one, otherwise summarize one
        - "description": max 1024 chars, refined
        - "allowed_tools": comma-separated tool names, ONLY from the available tools list below; always include skill_run_script when scripts exist
        - "content": the rewritten markdown instructions; concrete, actionable, step-by-step; the ENTIRE SKILL.md body must stay within ~1000 tokens (≈2500 chars) — push details (examples, templates, specs, lookup tables, checklists) into "references" instead, never duplicating them in the body
        - "scripts": optional array of {"path": "scripts/<file>.py", "content": "..."} — the FULL set of scripts the skill should have after rewriting (existing scripts are replaced); stdlib only; each under 200 lines; put outputs under scratch/
        - "references": optional array of {"path": "references/<file>.md|.txt|.json|.csv", "content": "..."} — the FULL set of reference docs after rewriting. Preserve the supplied reference contents unless the instruction says otherwise; add depth where useful; keep each under 4000 chars. Use references generously so SKILL.md stays small (≤ ~1000 tokens).
        - "variables": optional array of placeholder names that appear in "content" as {{name}}; preserve existing ones; the agent fills them from conversation context at runtime.

        Available built-in tools:
        \(Self.availableToolsBrief)

        Rules:
        - Preserve what already works unless the instruction says otherwise.
        - If Python logic is needed, implement it in "scripts" and instruct the assistant to run it via skill_run_script.
        - In "content", point to references/ files with relative paths (read at runtime via the skill_file tool).
        - Parameterize one-off values as {{placeholders}} and declare them in "variables" rather than baking them into the instructions.
        - Output ONLY the JSON object. No markdown fences, no commentary.
        """
        var userText = """
        Improvement instruction:
        \(instruction.isEmpty ? "(general refinement: make it deeper, clearer, more robust)" : instruction)

        Current SKILL.md:
        \(currentSKILLMD)

        Files in the skill folder:
        \(fileList.isEmpty ? "(none)" : fileList.joined(separator: "\n"))

        Existing resource contents:
        \(resourceContent)
        """
        if let knowledgeContext, !knowledgeContext.isEmpty {
            userText += "\n\nKnowledge base excerpts (domain facts; reflect them in the skill):\n\(knowledgeContext)"
        }
        if let usageFeedback, !usageFeedback.isEmpty {
            userText += "\n\nReal-world usage feedback (fix the reported failures; keep what works):\n\(usageFeedback)"
        }
        let result = try await chatForJSON(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: userText)
            ],
            config: Self.packageConfig,
            onDelta: onDelta
        )
        guard case .package(let package) = result else {
            throw GeneratorError.invalidJSON
        }
        var skill = package.skill
        skill.name = skillName
        return GeneratedSkillPackage(skill: skill, scripts: package.scripts, references: package.references)
    }

    // MARK: - 生成调用与容错解码

    /// 统一的 JSON 生成调用：请求 →（截断时自动续写拼接）→ 解码；
    /// 解码失败把原始输出回喂模型修正一次。
    /// 这是 "The model output could not be parsed as a skill definition" 的根治点：
    /// 大技能包 JSON 超过 max_tokens 截断、字符串内未转义引号等模型瑕疵不再直接判死
    private func chatForJSON(
        messages: [EngineMessage],
        config: LLMConfig,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult {
        let text = try await chatAccumulating(messages: messages, config: config, onDelta: onDelta)
        do {
            return try Self.decodeResult(text)
        } catch {
            // 修正重试：把不可解析的输出原样回喂，要求仅输出修正后的完整 JSON。
            HubLogger.shared.warning(
                "Skill generation decode failed: stage=initial, responseCharacters=\(text.count), \(HubLogger.safeErrorSummary(error))"
            )
            let repairMessages = messages + [
                EngineMessage(role: .assistant, text: text),
                EngineMessage(role: .user, text: Self.repairPrompt)
            ]
            let repaired = try await chatAccumulating(
                messages: repairMessages,
                config: Self.repairConfig,
                onDelta: onDelta
            )
            do {
                return try Self.decodeResult(repaired)
            } catch {
                HubLogger.shared.error(
                    "Skill generation decode failed: stage=repair, responseCharacters=\(repaired.count), \(HubLogger.safeErrorSummary(error))"
                )
                throw GeneratorError.invalidJSON
            }
        }
    }

    /// 流式（SSE）调用；finish_reason 显示截断（length/max_tokens）时带已有输出续写。
    /// 拼接做首尾重叠去重（模型续写常从断点附近复述起笔），最多续写 3 轮。
    /// onDelta 实时外发文本增量（含续写/修正轮），调用方据此展示生成过程
    private func chatAccumulating(
        messages: [EngineMessage],
        config: LLMConfig,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let forward: @Sendable (String) -> Void = onDelta ?? { _ in }
        // 思考增量同样外发（技能生成面板需展示推理细节；与正文共用同一回调）
        var reply = try await provider.chatStream(messages: messages, tools: [], config: config, onDelta: forward, onReasoningDelta: forward)
        var text = reply.text
        var rounds = 0
        while reply.isTruncated, rounds < 3 {
            let continuationMessages = messages + [
                EngineMessage(role: .assistant, text: text),
                EngineMessage(role: .user, text: Self.continuePrompt)
            ]
            let next = try await provider.chatStream(messages: continuationMessages, tools: [], config: config, onDelta: forward, onReasoningDelta: forward)
            let delta = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !delta.isEmpty else { break }
            text = Self.stitch(base: text, continuation: delta)
            reply = next
            rounds += 1
        }
        return text
    }

    /// 续写拼接：若续写开头与已有结尾重叠（模型复述衔接处）则去重后拼接
    static func stitch(base: String, continuation: String) -> String {
        let maxOverlap = min(base.count, continuation.count, 256)
        if maxOverlap > 0 {
            for length in stride(from: maxOverlap, through: 1, by: -1) {
                if base.suffix(length) == continuation.prefix(length) {
                    return base + continuation.dropFirst(length)
                }
            }
        }
        return base + continuation
    }

    static let continuePrompt = """
    The previous output was cut off because it reached the token limit. Continue EXACTLY where it stopped — start mid-word if that is where it stopped. Output ONLY the continuation: no preamble, no repetition of earlier text, no markdown fences.
    """

    static let repairPrompt = """
    Your previous output could not be parsed as JSON. Common causes: the output was cut off, double quotes or newlines inside string values were not escaped, or there was commentary around the JSON.
    Output ONLY the corrected, complete JSON object now. No markdown fences, no commentary.
    """

    /// 解析模型输出为技能（容错：剥离代码围栏，截取 JSON 对象段）
    static func decode(_ raw: String) throws -> Skill {
        guard case .package(let package) = try decodeResult(raw) else {
            throw GeneratorError.invalidJSON
        }
        return package.skill
    }

    /// 解析模型输出：澄清问题或完整技能包。
    /// 容错链：剥思考标签/围栏 → 双重编码解包 → 多候选平衡花括号截取 →
    /// 修复常见 LLM JSON 瑕疵（裸换行/制表符、尾逗号）→ JSON5 回退 → 截断抢救
    static func decodeResult(_ raw: String) throws -> GenerationResult {
        let payload = try Self.decodePayload(raw)
        return try Self.result(from: payload)
    }

    /// 解析为中间字典（Payload），失败抛 invalidJSON。
    /// 容错链：剥思考块/围栏 → 双重编码解包 → 多候选平衡花括号截取 →
    /// 修复常见 LLM JSON 瑕疵（裸换行/制表符、尾逗号）→ JSON5 回退 → 截断抢救
    private static func decodePayload(_ raw: String) throws -> [String: Any] {
        var text = Self.stripReasoningBlocks(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 双重编码：整体是一个 JSON 字符串字面量（内容才是技能包 JSON）→ 解一层再走常规链
        if text.hasPrefix("\""), let data = text.data(using: .utf8),
           let inner = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidates = Self.extractTopLevelJSONCandidates(from: text)
        // 依次尝试每个候选（思考正文里的示例对象先失败，最终技能包对象随后命中）
        for candidate in candidates {
            if let object = Self.parseCandidate(candidate) {
                return object
            }
        }
        // 截断抢救：最后一个候选（可能未闭合）闭合残缺结构后解析
        if let last = candidates.last, let object = Self.salvageTruncatedJSON(last) {
            return object
        }
        throw GeneratorError.invalidJSON
    }

    /// 单个候选的解析链：原样 → 瑕疵修复 → JSON5
    private static func parseCandidate(_ jsonText: String) -> [String: Any]? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        let repaired = Self.repairCommonJSONFlaws(jsonText)
        guard let repairedData = repaired.data(using: .utf8) else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: repairedData)) as? [String: Any] {
            return object
        }
        if let object = try? JSONSerialization.jsonObject(
            with: repairedData,
            options: [.fragmentsAllowed, .json5Allowed]
        ) as? [String: Any] {
            return object
        }
        return nil
    }

    /// 剥离推理模型混入 content 的思考块（think / thinking / reasoning 标签对）。
    /// 未闭合的开标签（截断发生在思考中）→ 丢弃标签起点之后的全部内容。
    /// 标签字面量用拼接构造，避免被工具链的思考标记语法吞掉
    static func stripReasoningBlocks(_ text: String) -> String {
        var result = text
        let thinkOpen = "<" + "think" + ">"
        let thinkClose = "</" + "think" + ">"
        let tagPairs = [
            (thinkOpen, thinkClose),
            ("<" + "thinking" + ">", "</" + "thinking" + ">"),
            ("<" + "reasoning" + ">", "</" + "reasoning" + ">")
        ]
        for (open, close) in tagPairs {
            while let openRange = result.range(of: open) {
                if let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    result.removeSubrange(openRange.lowerBound..<result.endIndex)
                    break
                }
            }
        }
        return result
    }

    /// 提取文本中所有顶层平衡 JSON 对象候选（按出现顺序）。
    /// 字符串感知：字符串字面量内的花括号不参与配对；括号深度防御性钳制。
    /// 未闭合的尾段（多为输出被截断）作为最后一个候选保留，供截断抢救
    static func extractTopLevelJSONCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                }
                if ch == "}" {
                    depth -= 1
                    if depth <= 0 {
                        if depth == 0, let objectStart = start {
                            candidates.append(String(text[objectStart...index]))
                        }
                        start = nil
                        depth = 0
                    }
                }
            }
            index = text.index(after: index)
        }
        // 未闭合尾段（输出被截断）：从首个未闭合 { 到文本末尾
        if let objectStart = start, depth > 0 {
            candidates.append(String(text[objectStart...]))
        }
        return candidates
    }

    /// 截断 JSON 抢救：闭合未闭合的字符串/括号后解析；仍失败则回退到
    /// 最后一处结构逗号，逐段丢弃被截断的悬挂成员后重试（最多 4 轮）。
    /// 仅接受含 name 且带 description/content 的结果，避免把思考正文里的
    /// 碎片对象误判为技能包
    static func salvageTruncatedJSON(_ json: String) -> [String: Any]? {
        var candidate = json
        for _ in 0..<4 {
            let closed = Self.closeOpenStructures(candidate)
            if let object = Self.parseCandidate(closed), Self.isUsablePayload(object) {
                return object
            }
            guard let comma = Self.lastStructuralCommaIndex(in: candidate) else { return nil }
            candidate = String(candidate[..<comma])
        }
        return nil
    }

    /// 抢救结果的可用性门槛：有 name 且 description/content 至少其一非空
    private static func isUsablePayload(_ object: [String: Any]) -> Bool {
        guard let name = object["name"] as? String, !name.isEmpty else { return false }
        let description = (object["description"] as? String) ?? ""
        let content = (object["content"] as? String) ?? ""
        return !description.isEmpty || !content.isEmpty
    }

    /// 闭合 JSON 文本中未闭合的字符串与括号（截断输出兜底）
    static func closeOpenStructures(_ json: String) -> String {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        for ch in json {
            if escaped {
                escaped = false
                continue
            }
            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": stack.append(ch)
            case "}", "]": if !stack.isEmpty { stack.removeLast() }
            default: break
            }
        }
        var result = json
        if inString { result.append("\"") }
        for opener in stack.reversed() {
            result.append(opener == "{" ? "}" : "]")
        }
        return result
    }

    /// 字符串感知地找最后一个（任何深度的）结构逗号位置，供截断抢救回退用
    static func lastStructuralCommaIndex(in json: String) -> String.Index? {
        var inString = false
        var escaped = false
        var lastComma: String.Index?
        var index = json.startIndex
        while index < json.endIndex {
            let ch = json[index]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString && ch == "," {
                lastComma = index
            }
            index = json.index(after: index)
        }
        return lastComma
    }

    /// 修复 LLM 输出 JSON 的常见瑕疵：
    /// - 字符串字面量内的裸换行/回车/制表符（JSON 规范非法，LLM 高频出错点）→ 转义
    /// - 对象/数组末尾的尾逗号 → 移除
    static func repairCommonJSONFlaws(_ json: String) -> String {
        var result = ""
        result.reserveCapacity(json.count)
        var inString = false
        var escaped = false
        for ch in json {
            if escaped {
                result.append(ch)
                escaped = false
                continue
            }
            if inString {
                switch ch {
                case "\\":
                    result.append(ch)
                    escaped = true
                case "\n":
                    result += "\\n"
                case "\r":
                    result += "\\r"
                case "\t":
                    result += "\\t"
                default:
                    result.append(ch)
                }
                continue
            }
            if ch == "\"" {
                inString = true
                result.append(ch)
                continue
            }
            result.append(ch)
        }
        // 尾逗号：`,}` / `,]`（允许中间空白）
        result = result.replacingOccurrences(
            of: ",[\\s]*([}\\]])",
            with: "$1",
            options: .regularExpression
        )
        return result
    }

    /// 中间字典 → 生成结果（澄清问题或技能包）。
    /// 容错：模型常见把技能包再包一层信封（{"skill": {...}} / {"package": ...} /
    /// {"data": ...} / {"result": ...}），顶层无 name/question 时先解一层
    private static func result(from object: [String: Any]) throws -> GenerationResult {
        var object = object
        if object["name"] as? String == nil,
           object["question"] as? String == nil,
           object["questions"] == nil {
            for key in ["skill", "package", "data", "result"] {
                if let nested = object[key] as? [String: Any] {
                    object = nested
                    break
                }
            }
        }
        struct Payload {
            let name: String?
            let alias: String?
            let question: String?
            let questions: [String]
            let description: String?
            let allowedTools: String?
            let content: String?
            let variables: [String]?
            let scripts: [[String: Any]]?
            let references: [[String: Any]]?
        }
        func string(_ key: String, _ aliases: [String] = []) -> String? {
            for k in [key] + aliases {
                if let value = object[k] as? String { return value }
            }
            return nil
        }
        let payload = Payload(
            name: string("name"),
            alias: string("alias"),
            question: string("question"),
            questions: (object["questions"] as? [Any])?.compactMap { $0 as? String } ?? [],
            description: string("description"),
            allowedTools: string("allowedTools", ["allowed_tools", "allowed-tools"]),
            content: string("content"),
            variables: object["variables"] as? [String],
            scripts: object["scripts"] as? [[String: Any]],
            references: object["references"] as? [[String: Any]]
        )

        // 澄清问题：优先取 questions 数组（1-3 条）；兼容旧的单条 question。仅当没给技能名时成立
        let clarificationQuestions: [String] = {
            let arr = payload.questions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !arr.isEmpty { return Array(arr.prefix(3)) }
            if let q = payload.question?.trimmingCharacters(in: .whitespacesAndNewlines),
               !q.isEmpty {
                return [q]
            }
            return []
        }()
        if !clarificationQuestions.isEmpty, (payload.name ?? "").isEmpty {
            return .needsClarification(questions: clarificationQuestions)
        }
        guard let rawName = payload.name, !rawName.isEmpty else {
            throw GeneratorError.invalidJSON
        }

        // 强制落到标准约束内：名称 slug 化，描述截断；变量只保留正文实际使用的占位符
        let slug = Skill.slugify(rawName)
        let content = payload.content ?? ""
        let declaredVariables = (payload.variables ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let usedVariables = declaredVariables.filter { content.contains("{{\($0)}}") }
        let skill = Skill(
            name: slug.isEmpty ? "generated-skill" : slug,
            alias: String((payload.alias ?? "").prefix(32)),
            description: String((payload.description ?? "").prefix(Skill.Constants.descriptionLimit)),
            content: content,
            allowedTools: (payload.allowedTools ?? "").trimmingCharacters(in: .whitespaces),
            variables: usedVariables
        )
        let scripts = (payload.scripts ?? []).compactMap { script -> GeneratedSkillPackage.ScriptFile? in
            guard let path = script["path"] as? String,
                  let content = script["content"] as? String else { return nil }
            return Self.sanitizeScript(path: path, content: content)
        }
        let references = (payload.references ?? []).compactMap { reference -> GeneratedSkillPackage.ScriptFile? in
            guard let path = reference["path"] as? String,
                  let content = reference["content"] as? String else { return nil }
            return Self.sanitizeReference(path: path, content: content)
        }
        return .package(GeneratedSkillPackage(skill: skill, scripts: scripts, references: references))
    }

    /// 脚本净化：仅接受 scripts/ 下的 .py 相对路径，内容非空且限量
    static func sanitizeScript(path: String, content: String) -> GeneratedSkillPackage.ScriptFile? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("scripts/"),
              trimmed.hasSuffix(".py"),
              trimmed.range(of: "^scripts/[A-Za-z0-9_./-]+\\.py$", options: .regularExpression) != nil,
              !trimmed.contains(".."),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return GeneratedSkillPackage.ScriptFile(path: trimmed, content: content)
    }

    /// 参考文档净化：仅接受 references/ 下的 .md/.txt/.json/.csv 相对路径，内容非空
    static func sanitizeReference(path: String, content: String) -> GeneratedSkillPackage.ScriptFile? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("references/"),
              ["md", "txt", "json", "csv"].contains((trimmed as NSString).pathExtension.lowercased()),
              trimmed.range(of: "^references/[A-Za-z0-9_./-]+\\.(md|txt|json|csv)$", options: .regularExpression) != nil,
              !trimmed.contains(".."),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return GeneratedSkillPackage.ScriptFile(path: trimmed, content: content)
    }

    // MARK: - 静态校验（落盘前）

    /// 合法工具名集合：内置工具 + 浏览器组 + 技能工具 + 动态智体（agent_ 前缀）
    static let knownToolNames: Set<String> = [
        "get_current_time", "memory_search", "memory_save", "knowledge_search",
        "web_fetch", "sql_query", "ocr_recognize", "transcribe_audio", "file_write", "files_write", "files_mkdir",
        "skill_load", "skill_search", "skill_file", "skill_create", "skill_run_script",
        "python_execute", "shell_run",
        "web_search", "docs_collect", "docs_read",
        "project_inspect", "repo_search", "repo_changes", "repo_symbols", "project_build",
        "files_list", "files_read", "files_read_range", "files_edit", "files_apply_changes",
        "files_create_directory", "files_move", "files_rename", "files_copy", "files_delete",
        "coding_task_read", "coding_task_update", "python_run", "ask_user", "tools_search", "tools_invoke",
        "browser_list", "browser_open", "browser_read", "browser_click",
        "browser_fill", "browser_screenshot", "browser_scroll", "browser_evaluate"
    ]

    // MARK: - SKILL.md 体量预算（落盘前兜底）

    /// SKILL.md 正文 token 预算：生成约束约 ~1000 tokens；此处按字符粗估（chars/3，中英混合的保守近似）
    public static let skillTokenBudget = 1000

    /// 正文溢出自动落袋的附录参考文件
    static let appendixReferencePath = "references/skill-appendix.md"

    /// content 估算超预算时按行界拆分：前段留给正文、其余作为溢出返回；未超返回 nil。
    /// 预算折算为字符上限（tokens×3），并预留约 150 字给随后自动追加的 reference 指针段。
    static func splitContentOverBudget(_ content: String, budgetTokens: Int) -> (kept: String, overflow: String)? {
        let maxChars = budgetTokens * 3 - 150
        guard content.count > maxChars else { return nil }
        var keptLines: [String] = []
        var keptChars = 0
        var overflowLines: [String] = []
        var passed = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let inc = line.count + 1
            if !passed, keptChars + inc > maxChars, !keptLines.isEmpty {
                passed = true
            }
            if passed {
                overflowLines.append(String(line))
            } else {
                keptChars += inc
                keptLines.append(String(line))
            }
        }
        if keptLines.isEmpty {
            // 首行即超（罕见）：按字符硬切兜底
            let idx = content.index(content.startIndex, offsetBy: maxChars)
            return (String(content[..<idx]), String(content[idx...]))
        }
        return (keptLines.joined(separator: "\n"), overflowLines.joined(separator: "\n"))
    }

    /// 落盘前静态校验 + 自动修正：
    /// 1. allowed-tools 中的未知工具名 → 移除（保留合法部分），否则 skill_load 后工具面会被收敛到不存在的名字
    /// 2. 携带脚本的技能自动补 skill_run_script 声明（漏声明会导致正文指引运行脚本时无工具可用）
    /// 3. references 文件未在 content 中被提及 → 自动补一段指针清单（否则文件永远不会被 skill_file 读到）
    /// 返回（修正后的包，警告清单供过程日志展示）
    public static func validatePackage(_ package: GeneratedSkillPackage, availableToolNames: Set<String>? = nil) -> (package: GeneratedSkillPackage, warnings: [String]) {
        var skill = package.skill
        var warnings: [String] = []

        // 1) allowed-tools 校验：agent_ 前缀（动态智体工具）放行
        if !skill.allowedTools.isEmpty {
            let declaration = SkillToolDeclaration(rawValue: skill.allowedTools)
            let declared = (declaration.names ?? []).sorted()
            let supported = availableToolNames ?? knownToolNames
            var valid = declared.filter { supported.contains($0) || (availableToolNames == nil && $0.hasPrefix("agent_")) }
            let dropped = declared.filter { !valid.contains($0) }
            if !dropped.isEmpty {
                warnings.append("Dropped unknown allowed-tools entries: \(dropped.joined(separator: ", "))")
            }
            if !package.scripts.isEmpty && !valid.contains("skill_run_script"), supported.contains("skill_run_script"),
               case .valid = declaration {
                valid.append("skill_run_script")
                warnings.append("Added skill_run_script to allowed-tools (scripts are bundled)")
            }
            if valid.isEmpty {
                warnings.append("allowed-tools has no valid available tools; preserving an explicit empty restriction")
            }
            skill.allowedTools = valid.isEmpty ? "[]" : valid.joined(separator: ", ")
        } else if !package.scripts.isEmpty {
            // 声明为空但带脚本：直接补最小声明
            skill.allowedTools = "skill_run_script"
            warnings.append("Added skill_run_script to allowed-tools (scripts are bundled)")
        }

        // 2) SKILL.md 体量预算：正文估算超 ~1000 tokens → 尾部溢出迁入 references 附录，
        //    正文保留精简指引；溢出非实际内容（纯空白）则不落袋
        var references = package.references
        if let split = Self.splitContentOverBudget(skill.content, budgetTokens: Self.skillTokenBudget) {
            let overflowText = split.overflow.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overflowText.isEmpty {
                if let idx = references.firstIndex(where: { $0.path == Self.appendixReferencePath }) {
                    references[idx] = GeneratedSkillPackage.ScriptFile(
                        path: Self.appendixReferencePath,
                        content: references[idx].content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + overflowText
                    )
                } else {
                    references.append(GeneratedSkillPackage.ScriptFile(path: Self.appendixReferencePath, content: overflowText))
                }
                warnings.append("SKILL.md exceeded ~\(Self.skillTokenBudget) tokens; overflow moved to \(Self.appendixReferencePath)")
                skill.content = split.kept.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
        }

        // 3) references 指针检查：未在 content 中提及的参考文档补指针段
        let unmentioned = references
            .map(\.path)
            .filter { !skill.content.contains($0) }
            .filter { !$0.hasPrefix("references/documentation/") || $0 == "references/documentation/index.md" || $0 == "references/documentation/sources.json" }
        if !unmentioned.isEmpty {
            skill.content += "\n\n## Reference files\n"
                + "Read these with the skill_file tool when needed:\n"
                + unmentioned.map { "- \($0)" }.joined(separator: "\n")
            warnings.append("Added content pointers for unmentioned references: \(unmentioned.joined(separator: ", "))")
        }
        return (GeneratedSkillPackage(skill: skill, scripts: package.scripts, references: references), warnings)
    }

    // MARK: - 单文件 AI 润色（编辑器「AI 润色此文件」）

    /// 就地润色技能包内单个文件：保持文件类型与用途不变，返回润色后的完整内容。
    /// SKILL.md 只润色正文，frontmatter（name/description/allowed-tools/variables）原样保留
    public func polishFile(path: String, content: String, instruction: String) async throws -> String {
        let role: String
        switch (path as NSString).pathExtension.lowercased() {
        case "py":
            role = "It is a Python script bundled in the skill. Keep the same external behavior (inputs/outputs/file paths); improve clarity, robustness and error handling; stdlib only."
        case "md", "markdown", "txt":
            role = "It is a Markdown/text document bundled in the skill. Improve clarity, structure and precision; keep all factual content and relative path references intact."
        default:
            role = "It is a text file bundled in the skill. Improve it in place while keeping its format valid."
        }
        let system = """
        You improve a single file inside an Agent Skill (Anthropic SKILL.md format) in place.
        \(role)
        Output ONLY the improved full file content — no explanations, no markdown fences around the whole answer.
        """
        let user = """
        File path: \(path)
        Improvement instruction: \(instruction.isEmpty ? "(general polish: clearer, more precise, better structured)" : instruction)

        Current content:
        \(content)
        """
        let reply = try await provider.chat(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: user)
            ],
            tools: [],
            config: LLMConfig(maxTokens: 8192, temperature: 0.4)
        )
        var text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥掉模型可能加的代码围栏（保留内容原貌）
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { throw GeneratorError.emptyOutput }
        // SKILL.md：仅润色正文，frontmatter 原样拼回
        if path == "SKILL.md", let parsed = try? SkillDocument.parse(content) {
            var polished = parsed
            polished.content = text
            return SkillDocument.render(polished)
        }
        return text
    }
}
