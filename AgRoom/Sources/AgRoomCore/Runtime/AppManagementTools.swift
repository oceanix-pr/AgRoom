import Foundation

// MARK: - App Management Tool Factory
//
// A 档「空间内容管理」工具：知识、记忆、智体、技能的写路径与联网检索。
// 此前这些能力只在功能页可用，调度 Agent 只能检索不能管理，形成半接线能力。
//
// 设计约束（AGENTS.md、03-工具系统）：
// - 只通过空间服务读写；不直接访问 GRDB，不接受跨空间参数（服务已绑定单一空间）。
// - 删除类工具走确认分级；智体 / 技能删除不可逆（连带文件与配置），使用 hard confirmation。
// - 只读工具显式声明 .readOnly，守护进程可安全重试；写类保守声明为非幂等写。
// - 文本体量设上限，避免把超大内容写进数据库。
public enum AppManagementToolFactory {

    /// 单个写入条目/字段的体积上限（与技能文件读取上限同量级）
    static let maxTextLength = 200_000

    /// 组装 A 档管理工具。缺省的服务不注册对应工具，避免公布「公布了却执行不了」的能力
    public static func build(
        memoryService: MemoryService?,
        knowledgeService: KnowledgeService?,
        agentService: AgentService?,
        skillStore: SkillStore?,
        knowledgeBaseIDs: Set<UUID>? = nil
    ) -> [any DispatcherTool] {
        var tools: [any DispatcherTool] = []
        if let memoryService {
            tools += [MemoryListTool(service: memoryService), MemoryUpdateTool(service: memoryService), MemoryDeleteTool(service: memoryService)]
        }
        if let knowledgeService {
            tools.append(KnowledgeListTool(service: knowledgeService, allowedBaseIDs: knowledgeBaseIDs))
            tools.append(KnowledgeSaveTool(service: knowledgeService, allowedBaseIDs: knowledgeBaseIDs))
            tools.append(KnowledgeDeleteTool(service: knowledgeService, allowedBaseIDs: knowledgeBaseIDs))
        }
        if let agentService {
            tools.append(AgentsListTool(service: agentService))
            tools.append(AgentsSaveTool(service: agentService))
            tools.append(AgentsDeleteTool(service: agentService))
        }
        if let skillStore {
            tools.append(SkillDeleteTool(store: skillStore))
            tools.append(SkillSetEnabledTool(store: skillStore))
        }
        tools.append(WebSearchTool())
        return tools
    }

    /// 写入文本的前置校验：过长时给出可操作的错误，而不是静默截断
    static func validateLength(_ value: String, field: String) throws {
        guard value.count <= maxTextLength else {
            throw LLMError.configurationError(
                reason: "\(field) exceeds the \(maxTextLength)-character limit; split it into smaller entries"
            )
        }
    }

    /// 目标唯一性：多条命中时不允许猜测，返回候选让模型改用显式 id
    static func ambiguousError(_ label: String, candidates: [(UUID, String)]) -> LLMError {
        let list = candidates.prefix(10)
            .map { "- \($0.1) (id: \($0.0.uuidString))" }
            .joined(separator: "\n")
        return LLMError.configurationError(
            reason: "\(label) matches \(candidates.count) items; retry with an explicit 'id':\n\(list)"
        )
    }

    /// 知识库名称匹配：忽略大小写与首尾空白；重名库取最早创建的一个
    static func matchBase(named name: String, in bases: [KnowledgeBase]) -> KnowledgeBase? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return bases
            .sorted { $0.createdAt < $1.createdAt }
            .first { $0.name.lowercased() == target }
    }
}

// MARK: - Memory Tools

/// 记忆列表：含已停用条目，供模型先看清单再决定改哪条
struct MemoryListTool: DispatcherTool {
    let service: MemoryService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory_list",
            description: "List the user's long-term memories with their ids, categories and enabled state. "
                + "Use before memory_update or memory_delete to obtain the exact id. "
                + "Prefer memory_search for keyword lookup when the list is long.",
            parametersSchemaJSON: #"{"type":"object","properties":{"category":{"type":"string","enum":["preference","fact","decision","entity","other"],"description":"Optional: only memories in this category"},"include_disabled":{"type":"boolean","description":"Include memories that are currently turned off (default true)"},"limit":{"type":"integer","description":"Maximum entries to return (default 50)"}}}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let includeDisabled = (args["include_disabled"] as? Bool) ?? true
        let limit = min(max((args["limit"] as? Int) ?? 50, 1), 200)
        let category = MemoryCategory(
            rawValue: ToolArguments.string(args, "category").lowercased()
        )

        var items = try await service.getAll()
        if !includeDisabled {
            items = items.filter(\.isEnabled)
        }
        if let category {
            items = items.filter { $0.category == category }
        }
        guard !items.isEmpty else {
            return "No memories found."
        }
        let total = items.count
        let lines = items.prefix(limit).map { item in
            let state = item.isEnabled ? "on" : "off"
            return "- \(item.content) [\(item.category.rawValue), \(state)] (id: \(item.id.uuidString))"
        }
        let suffix = total > lines.count ? "\n\nShowing \(lines.count) of \(total)." : ""
        return "\(total) memories:\n" + lines.joined(separator: "\n") + suffix
    }
}

/// 记忆更新：按 id 修改正文、类别或启停；其余字段保持不变
struct MemoryUpdateTool: DispatcherTool {
    let service: MemoryService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory_update",
            description: "Update one memory by id: change its content, category or enabled state. "
                + "Omitted fields keep their current value. Get the id from memory_list or memory_search.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Id of the memory to update"},"content":{"type":"string","description":"New content; omit to keep the current text"},"category":{"type":"string","enum":["preference","fact","decision","entity","other"]},"enabled":{"type":"boolean","description":"Turn this memory on or off"}},"required":["id"]}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 按 id 更新到目标状态，重复执行结果一致
    var sideEffectClass: ToolSideEffectClass { .idempotentWrite }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: rawID) else {
            throw LLMError.configurationError(reason: "memory_update requires a valid 'id' (UUID)")
        }
        guard let existing = try await service.getAll().first(where: { $0.id == id }) else {
            throw LLMError.configurationError(reason: "No memory found with id \(rawID)")
        }

        var updated = existing
        if let content = args["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw LLMError.configurationError(reason: "memory content cannot be empty")
            }
            try AppManagementToolFactory.validateLength(trimmed, field: "content")
            updated.content = trimmed
        }
        if let rawCategory = args["category"] as? String {
            guard let category = MemoryCategory(rawValue: rawCategory.lowercased()) else {
                throw LLMError.configurationError(
                    reason: "Unknown category '\(rawCategory)'. Valid values: "
                        + MemoryCategory.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            updated.category = category
        }
        if let enabled = args["enabled"] as? Bool {
            updated.isEnabled = enabled
        }
        try await service.save(updated)
        return "Updated memory [\(updated.category.rawValue), \(updated.isEnabled ? "on" : "off")]: \(updated.content)"
    }
}

/// 记忆删除：按 id，或用唯一命中的正文片段定位；不可恢复
struct MemoryDeleteTool: DispatcherTool {
    let service: MemoryService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory_delete",
            description: "Permanently delete one memory. Identify it by 'id' (preferred) or by a text fragment "
                + "that matches exactly one memory. This cannot be undone.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Id of the memory to delete"},"content_match":{"type":"string","description":"Text fragment identifying the memory, used only when 'id' is omitted"}}}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let match = ToolArguments.string(args, "content_match")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty || !match.isEmpty else {
            throw LLMError.configurationError(reason: "memory_delete requires 'id' or 'content_match'")
        }

        let items = try await service.getAll()
        let target: MemoryItem
        if !rawID.isEmpty {
            guard let found = items.first(where: { $0.id.uuidString == rawID }) else {
                throw LLMError.configurationError(reason: "No memory found with id \(rawID)")
            }
            target = found
        } else {
            let hits = items.filter { $0.content.localizedCaseInsensitiveContains(match) }
            guard !hits.isEmpty else {
                throw LLMError.configurationError(reason: "No memory contains \"\(match)\"")
            }
            guard hits.count == 1 else {
                throw AppManagementToolFactory.ambiguousError(
                    "content_match \"\(match)\"",
                    candidates: hits.map { ($0.id, $0.content) }
                )
            }
            target = hits[0]
        }
        try await service.delete(id: target.id)
        return "Deleted memory: \(target.content)"
    }
}

// MARK: - Knowledge Tools

/// 知识条目列表：跨知识库，带 id 与所属库名
struct KnowledgeListTool: DispatcherTool {
    let service: KnowledgeService
    let allowedBaseIDs: Set<UUID>?
    init(service: KnowledgeService, allowedBaseIDs: Set<UUID>? = nil) { self.service = service; self.allowedBaseIDs = allowedBaseIDs }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "knowledge_list",
            description: "List knowledge entries with their ids, kinds, tags and knowledge base names. "
                + "Use before knowledge_delete to obtain the exact id, or to review what is already stored. "
                + "Prefer knowledge_search for relevance-based lookup.",
            parametersSchemaJSON: #"{"type":"object","properties":{"base_id":{"type":"string","description":"Optional knowledge base UUID"},"folder_id":{"type":"string","description":"Optional folder UUID"},"include_descendants":{"type":"boolean","description":"Include child folders (default true)"},"base":{"type":"string","description":"Optional: only entries in this knowledge base (by name)"},"kind":{"type":"string","enum":["document","wiki"],"description":"Optional: only entries of this kind"},"limit":{"type":"integer","description":"Maximum entries to return (default 50)"}}}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let limit = min(max((args["limit"] as? Int) ?? 50, 1), 200)
        let baseName = ToolArguments.string(args, "base")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = KnowledgeKind(
            rawValue: ToolArguments.string(args, "kind").lowercased()
        )

        let snapshot = try await service.browserSnapshot()
        let bases = snapshot.bases.filter { allowedBaseIDs?.contains($0.id) ?? true }
        var scope = try KnowledgeScopeResolver.resolve(args, snapshot: snapshot)
        if !baseName.isEmpty {
            let matches = bases.filter { $0.name.caseInsensitiveCompare(baseName) == .orderedSame }
            guard matches.count == 1, let base = matches.first else {
                throw LLMError.configurationError(reason: "Knowledge base name is missing or ambiguous. Use base_id from knowledge_list.")
            }
            switch scope {
            case .all: scope = .base(base.id)
            case .base(let id) where id == base.id: break
            case .folder(let id, _) where snapshot.foldersByID[id]?.baseId == base.id: break
            default: throw KnowledgeOrganizationError.invalidParent
            }
        }
        let items = try snapshot.scopedItems(scope).filter { (kind == nil || $0.kind == kind) && WorkspaceKnowledgeSelection.allows($0.baseId, in: allowedBaseIDs) }
        let catalogBases: [KnowledgeBase]
        let catalogFolders: [KnowledgeFolder]
        switch scope {
        case .base(let id):
            catalogBases = bases.filter { $0.id == id }
            catalogFolders = snapshot.folders.filter { $0.baseId == id && WorkspaceKnowledgeSelection.allows($0.baseId, in: allowedBaseIDs) }
        case .folder(let id, let recursive):
            let ids = recursive ? snapshot.descendantIDs(of: id) : [id]
            catalogBases = bases.filter { $0.id == snapshot.foldersByID[id]?.baseId }
            catalogFolders = snapshot.folders.filter { ids.contains($0.id) && WorkspaceKnowledgeSelection.allows($0.baseId, in: allowedBaseIDs) }
        default: catalogBases = bases; catalogFolders = snapshot.folders.filter { WorkspaceKnowledgeSelection.allows($0.baseId, in: allowedBaseIDs) }
        }
        let catalog = "Knowledge bases:\n" + catalogBases.prefix(limit).map { "- \($0.name) (base_id: \($0.id))" }.joined(separator: "\n")
            + "\nFolders (\(min(limit, catalogFolders.count)) of \(catalogFolders.count)):\n"
            + catalogFolders.prefix(limit).map { folder in
                let base = bases.first { $0.id == folder.baseId }?.name ?? "unfiled"
                let path = ([base] + snapshot.ancestors(of: folder.id).map(\.name)).joined(separator: " / ")
                return "- \(path) (folder_id: \(folder.id), base_id: \(folder.baseId))"
            }.joined(separator: "\n")
        guard !items.isEmpty else { return catalog + "\n\nNo knowledge entries found." }
        let total = items.count
        let lines = items.prefix(limit).map { item -> String in
            let path = snapshot.path(for: item).joined(separator: " / ")
            let tags = item.tags.isEmpty ? "" : " tags: \(item.tags.joined(separator: ", "))"
            return "- \(item.title) [\(item.kind.rawValue) · \(path.isEmpty ? "unfiled" : path)]\(tags) (id: \(item.id.uuidString))"
        }
        let suffix = total > lines.count ? "\n\nShowing \(lines.count) of \(total)." : ""
        return catalog + "\n\n\(total) knowledge entries:\n" + lines.joined(separator: "\n") + suffix
    }
}

/// 知识条目保存：按 id / 同名条目更新，否则新建；可指定或新建知识库
struct KnowledgeSaveTool: DispatcherTool {
    let service: KnowledgeService
    let allowedBaseIDs: Set<UUID>?
    init(service: KnowledgeService, allowedBaseIDs: Set<UUID>? = nil) { self.service = service; self.allowedBaseIDs = allowedBaseIDs }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "knowledge_save",
            description: "Create or update a knowledge entry. Update when 'id' is given, or when an entry with "
                + "the same title already exists in the target base; otherwise a new entry is created. "
                + "If 'base' names a knowledge base that does not exist yet, it is created.",
            parametersSchemaJSON: #"{"type":"object","properties":{"folder_id":{"type":"string","description":"Folder UUID from knowledge_list; empty string selects the base root. Omit to preserve the current folder when staying in the same base."},"title":{"type":"string","description":"Entry title"},"content":{"type":"string","description":"Markdown body; omit to keep the existing body when updating"},"kind":{"type":"string","enum":["document","wiki"],"description":"document = reference material, wiki = distilled know-how (default document)"},"tags":{"type":"array","items":{"type":"string"},"description":"Optional tags; replaces the existing tags when updating"},"base":{"type":"string","description":"Knowledge base name (default: the unfiled area, or the existing entry's base when updating)"},"id":{"type":"string","description":"Id of an existing entry to update"}},"required":["title"]}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let title = ToolArguments.string(args, "title")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw LLMError.configurationError(reason: "knowledge_save requires a non-empty 'title'")
        }
        try AppManagementToolFactory.validateLength(title, field: "title")

        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = ToolArguments.string(args, "base")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = try await service.browserSnapshot()
        var bases = snapshot.bases.filter { allowedBaseIDs?.contains($0.id) ?? true }
        var newBase: KnowledgeBase?
        let matchingBases = bases.filter { $0.name.caseInsensitiveCompare(baseName) == .orderedSame }
        if !baseName.isEmpty, matchingBases.count > 1 {
            throw AppManagementToolFactory.ambiguousError("knowledge base", candidates: matchingBases.map { ($0.id, $0.name) })
        }
        var targetBaseID = matchingBases.first?.id
        if !baseName.isEmpty, targetBaseID == nil {
            let base = KnowledgeBase(name: baseName)
            newBase = base; targetBaseID = base.id
        }
        let hasFolder = args.keys.contains("folder_id")
        var targetFolder: KnowledgeFolder?
        if hasFolder {
            guard let text = args["folder_id"] as? String else {
                throw LLMError.configurationError(reason: "folder_id must be a UUID, or an empty string for the base root.")
            }
            if !text.isEmpty {
                guard let id = UUID(uuidString: text), let folder = snapshot.foldersByID[id] else {
                    throw KnowledgeOrganizationError.folderMissing
                }
                if !baseName.isEmpty, folder.baseId != targetBaseID { throw KnowledgeOrganizationError.invalidParent }
                targetFolder = folder
                targetBaseID = folder.baseId
            }
        }
        // 同名条目只能在明确指定的库/目录范围内匹配；有歧义时要求稳定 ID。
        var existing: KnowledgeItem?
        if !rawID.isEmpty {
            guard let id = UUID(uuidString: rawID), let found = try await service.get(id: id) else {
                throw KnowledgeOrganizationError.itemMissing
            }
            existing = found
            guard WorkspaceKnowledgeSelection.allows(found.baseId, in: allowedBaseIDs) else { throw WorkspaceProjectError.outsideKnowledgeScope }
        } else {
            let sameTitle = snapshot.items.filter { item in
                WorkspaceKnowledgeSelection.allows(item.baseId, in: allowedBaseIDs) && item.title == title
                    && (baseName.isEmpty && targetFolder == nil || item.baseId == targetBaseID)
                    && (!hasFolder || item.folderId == targetFolder?.id)
            }
            guard sameTitle.count <= 1 else {
                throw AppManagementToolFactory.ambiguousError("title \"\(title)\"", candidates: sameTitle.map { ($0.id, $0.title) })
            }
            if let id = sameTitle.first?.id { existing = try await service.get(id: id) }
        }

        var item = existing ?? KnowledgeItem(title: title)
        item.title = title
        if let content = args["content"] as? String {
            try AppManagementToolFactory.validateLength(content, field: "content")
            item.content = content
        }
        if let rawKind = args["kind"] as? String {
            guard let kind = KnowledgeKind(rawValue: rawKind.lowercased()) else {
                throw LLMError.configurationError(
                    reason: "Unknown kind '\(rawKind)'. Valid values: document, wiki"
                )
            }
            item.kind = kind
        }
        if let tags = args["tags"] as? [String] {
            item.tags = tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let previousBaseID = item.baseId
        if !baseName.isEmpty || targetFolder != nil { item.baseId = targetBaseID }
        if hasFolder { item.folderId = targetFolder?.id }
        else if item.baseId != previousBaseID { item.folderId = nil }
        guard WorkspaceKnowledgeSelection.allows(item.baseId, in: allowedBaseIDs) else { throw WorkspaceProjectError.outsideKnowledgeScope }
        if let newBase { try await service.saveBase(newBase); bases.append(newBase) }
        item.updatedAt = Date()

        try await service.save(item, allowedBaseIDs: allowedBaseIDs)
        let baseLabel = item.baseId.flatMap { id in bases.first { $0.id == id }?.name } ?? "unfiled"
        let verb = existing == nil ? "Created" : "Updated"
        return "\(verb) knowledge entry \"\(item.title)\" in \(baseLabel) (id: \(item.id.uuidString))"
    }
}

/// 知识条目删除：按 id，或用唯一命中的标题定位；不可恢复
struct KnowledgeDeleteTool: DispatcherTool {
    let service: KnowledgeService
    let allowedBaseIDs: Set<UUID>?
    init(service: KnowledgeService, allowedBaseIDs: Set<UUID>? = nil) { self.service = service; self.allowedBaseIDs = allowedBaseIDs }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "knowledge_delete",
            description: "Permanently delete one knowledge entry. Identify it by 'id' (preferred) or by a title "
                + "that matches exactly one entry. This cannot be undone.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Id of the entry to delete"},"title":{"type":"string","description":"Exact or partial title, used only when 'id' is omitted"}}}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = ToolArguments.string(args, "title")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty || !title.isEmpty else {
            throw LLMError.configurationError(reason: "knowledge_delete requires 'id' or 'title'")
        }

        let items = try await service.getAll().filter { WorkspaceKnowledgeSelection.allows($0.baseId, in: allowedBaseIDs) }
        let target: KnowledgeItem
        if !rawID.isEmpty {
            guard let found = items.first(where: { $0.id.uuidString == rawID }) else {
                throw LLMError.configurationError(reason: "No knowledge entry found with id \(rawID)")
            }
            target = found
        } else {
            let exact = items.filter { $0.title == title }
            let hits = exact.isEmpty
                ? items.filter { $0.title.localizedCaseInsensitiveContains(title) }
                : exact
            guard !hits.isEmpty else {
                throw LLMError.configurationError(reason: "No knowledge entry matches title \"\(title)\"")
            }
            guard hits.count == 1 else {
                throw AppManagementToolFactory.ambiguousError(
                    "title \"\(title)\"",
                    candidates: hits.map { ($0.id, $0.title) }
                )
            }
            target = hits[0]
        }
        try await service.delete(id: target.id, allowedBaseIDs: allowedBaseIDs)
        return "Deleted knowledge entry \"\(target.title)\" (id: \(target.id.uuidString))"
    }
}

// MARK: - Agent Tools

/// 智体列表：含停用智体与技能挂载情况
struct AgentsListTool: DispatcherTool {
    let service: AgentService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "agents_list",
            description: "List the agents configured in the current space, with ids, enabled state, description "
                + "and mounted skills. Use before agents_save or agents_delete.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let agents = try await service.getAll()
        guard !agents.isEmpty else {
            return "No agents configured in this space."
        }
        let lines = agents.map { agent -> String in
            let skills = agent.skillNames.isEmpty ? "all skills" : agent.skillNames.joined(separator: ", ")
            let summary = agent.description.isEmpty ? "" : " — \(agent.description)"
            return "- \(agent.displayName) [\(agent.isEnabled ? "on" : "off")\(agent.knowledgeEnabled ? ", knowledge" : "")]"
                + "\(summary) (skills: \(skills)) (id: \(agent.id.uuidString))"
        }
        return "\(agents.count) agents:\n" + lines.joined(separator: "\n")
    }
}

/// 智体保存：按 id / 同名智体更新，否则新建；人设取值受固定枚举约束
struct AgentsSaveTool: DispatcherTool {
    let service: AgentService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "agents_save",
            description: "Create or update an agent. Update when 'id' is given, or when an agent with the same "
                + "name already exists; otherwise a new (enabled) agent is created. Omitted fields keep their "
                + "current value when updating.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Id of an existing agent to update"},"name":{"type":"string","description":"Agent name (stable identifier shown in the roster)"},"nickname":{"type":"string","description":"Optional display name"},"icon":{"type":"string","description":"Single emoji used as the avatar"},"description":{"type":"string","description":"One-line summary of what this agent does"},"system_prompt":{"type":"string","description":"Role and responsibilities prompt for the agent"},"personality":{"type":"string","description":"Optional personality; must be one of the documented values"},"speaking_style":{"type":"string","description":"Optional speaking style; must be one of the documented values"},"model_name":{"type":"string","description":"Optional model override (empty = provider default)"},"knowledge_enabled":{"type":"boolean","description":"Attach relevant knowledge entries when delegating"},"enabled":{"type":"boolean","description":"Whether the agent is available for delegation"},"skills":{"type":"array","items":{"type":"string"},"description":"Mounted skill names; empty array = all skills available"}},"required":["name"]}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ToolArguments.string(args, "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LLMError.configurationError(reason: "agents_save requires a non-empty 'name'")
        }

        let agents = try await service.getAll()
        var existing: Agent?
        if !rawID.isEmpty {
            guard let found = agents.first(where: { $0.id.uuidString == rawID }) else {
                throw LLMError.configurationError(reason: "No agent found with id \(rawID)")
            }
            existing = found
        } else {
            let sameName = agents.filter { $0.name == name }
            guard sameName.count <= 1 else {
                throw AppManagementToolFactory.ambiguousError(
                    "name \"\(name)\"",
                    candidates: sameName.map { ($0.id, $0.displayName) }
                )
            }
            existing = sameName.first
        }

        var agent = existing ?? Agent(name: name)
        agent.name = name
        if let value = args["nickname"] as? String { agent.nickname = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args["icon"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { agent.icon = trimmed }
        }
        if let value = args["description"] as? String {
            try AppManagementToolFactory.validateLength(value, field: "description")
            agent.description = value
        }
        if let value = args["system_prompt"] as? String {
            try AppManagementToolFactory.validateLength(value, field: "system_prompt")
            agent.systemPrompt = value
        }
        if let value = args["personality"] as? String {
            agent.personality = try Self.validated(
                value, allowed: Agent.personalities, field: "personality"
            )
        }
        if let value = args["speaking_style"] as? String {
            agent.speakingStyle = try Self.validated(
                value, allowed: Agent.speakingStyles, field: "speaking_style"
            )
        }
        if let value = args["model_name"] as? String { agent.modelName = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args["knowledge_enabled"] as? Bool { agent.knowledgeEnabled = value }
        if let value = args["enabled"] as? Bool { agent.isEnabled = value }
        if let skills = args["skills"] as? [String] {
            agent.skillNames = skills
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        agent.updatedAt = Date()

        try await service.save(agent)
        let verb = existing == nil ? "Created" : "Updated"
        return "\(verb) agent \"\(agent.displayName)\" (id: \(agent.id.uuidString), \(agent.isEnabled ? "enabled" : "disabled"))"
    }

    /// 人设字段只接受固定枚举值：非法值给出可选值清单，而不是把垃圾写进库
    private static func validated(_ value: String, allowed: [String], field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard allowed.contains(trimmed) else {
            throw LLMError.configurationError(
                reason: "Invalid \(field) '\(trimmed)'. Valid values: \(allowed.joined(separator: ", "))"
            )
        }
        return trimmed
    }
}

/// 智体删除：连带其人设与技能挂载配置，不可恢复 → 逐次硬确认
struct AgentsDeleteTool: DispatcherTool {
    let service: AgentService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "agents_delete",
            description: "Permanently delete one agent, including its persona and skill mounts. "
                + "Identify it by 'id' (preferred) or by a name that matches exactly one agent. "
                + "This cannot be undone.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Id of the agent to delete"},"name":{"type":"string","description":"Agent name, used only when 'id' is omitted"}}}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 不可逆：无视本轮「始终允许」，每次都必须用户明确批准
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawID = ToolArguments.string(args, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ToolArguments.string(args, "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty || !name.isEmpty else {
            throw LLMError.configurationError(reason: "agents_delete requires 'id' or 'name'")
        }

        let agents = try await service.getAll()
        let target: Agent
        if !rawID.isEmpty {
            guard let found = agents.first(where: { $0.id.uuidString == rawID }) else {
                throw LLMError.configurationError(reason: "No agent found with id \(rawID)")
            }
            target = found
        } else {
            let hits = agents.filter { $0.name == name || $0.nickname == name }
            guard !hits.isEmpty else {
                throw LLMError.configurationError(reason: "No agent named \"\(name)\"")
            }
            guard hits.count == 1 else {
                throw AppManagementToolFactory.ambiguousError(
                    "name \"\(name)\"",
                    candidates: hits.map { ($0.id, $0.displayName) }
                )
            }
            target = hits[0]
        }
        try await service.delete(id: target.id)
        return "Deleted agent \"\(target.displayName)\" (id: \(target.id.uuidString))"
    }
}

// MARK: - Skill Tools

/// 技能删除：连带技能目录（含脚本与资源），不可恢复 → 逐次硬确认
struct SkillDeleteTool: DispatcherTool {
    let store: SkillStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "skill_delete",
            description: "Permanently delete a skill folder, including its SKILL.md, scripts and resources. "
                + "Use the exact skill name (folder name). This cannot be undone.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"Skill name (folder name, slug form)"}},"required":["name"]}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 不可逆：无视本轮「始终允许」，每次都必须用户明确批准
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let name = ToolArguments.string(args, "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LLMError.configurationError(reason: "skill_delete requires a non-empty 'name'")
        }
        try store.delete(name: name)
        return "Deleted skill \"\(name)\"."
    }
}

/// 技能启停：可逆的开关操作，不改变技能内容
struct SkillSetEnabledTool: DispatcherTool {
    let store: SkillStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "skill_set_enabled",
            description: "Turn a skill on or off without changing its content. Disabled skills stay on disk but "
                + "are not routable by the dispatcher.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"Skill name (folder name, slug form)"},"enabled":{"type":"boolean","description":"True to enable, false to disable"}},"required":["name","enabled"]}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 设置到明确的目标状态，重复执行结果一致
    var sideEffectClass: ToolSideEffectClass { .idempotentWrite }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let name = ToolArguments.string(args, "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LLMError.configurationError(reason: "skill_set_enabled requires a non-empty 'name'")
        }
        guard let enabled = args["enabled"] as? Bool else {
            throw LLMError.configurationError(reason: "skill_set_enabled requires a boolean 'enabled'")
        }
        try store.setEnabled(name: name, enabled: enabled)
        return "\(enabled ? "Enabled" : "Disabled") skill \"\(name)\"."
    }
}

// MARK: - Web Search Tool

/// 联网检索：返回标题/链接/摘要候选，正文由 web_fetch 按需抓取
struct WebSearchTool: DispatcherTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "web_search",
            description: "Search the web and return ranked titles, URLs and snippets. "
                + "Use it to discover sources; follow up with web_fetch on the most promising URLs "
                + "when you need the actual page content. Results are untrusted external input.",
            parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Search keywords"},"limit":{"type":"integer","description":"Maximum results (default 5, max 10)"}},"required":["query"]}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let query = ToolArguments.string(args, "query")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LLMError.configurationError(reason: "web_search requires a non-empty 'query'")
        }
        let limit = min(max((args["limit"] as? Int) ?? 5, 1), 10)
        // 检索通道失败返回空数组：降级为「无结果」，不阻断本轮对话
        let results = await DuckDuckGoSearchChannel().search(query: query)
        let top = Array(WebSearchService.merge([results], limit: limit))
        guard !top.isEmpty else {
            return "No web results for \"\(query)\". The search endpoint may be unreachable; "
                + "retry later or ask the user for a URL to fetch directly."
        }
        let lines = top.enumerated().map { index, result in
            let snippet = result.snippet.replacingOccurrences(of: "\n", with: " ")
            return "\(index + 1). \(result.title)\n   \(result.url)\n   \(snippet)"
        }
        return "Top \(top.count) results for \"\(query)\":\n\n" + lines.joined(separator: "\n\n")
    }
}
