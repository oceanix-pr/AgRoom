import Foundation
import GRDB

// MARK: - Space Service Error

public enum SpaceServiceError: LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data for storage."
        }
    }
}

// MARK: - Agent Service

/// 智体服务：绑定单一空间库（空间隔离红线）
public final class AgentService: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表 + 旧库升级（由 `DatabaseBootstrap` 的迁移器集中调用）
    static func createSchema(_ database: Database) throws {
        try database.create(table: "agents", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("nickname", .text).notNull().defaults(to: "")
                t.column("icon", .text).notNull().defaults(to: "🤖")
                t.column("description", .text).notNull().defaults(to: "")
                t.column("systemPrompt", .text).notNull().defaults(to: "")
                t.column("personality", .text).notNull().defaults(to: "")
                t.column("speakingStyle", .text).notNull().defaults(to: "")
                t.column("modelName", .text).notNull().defaults(to: "")
                t.column("providerID", .text)
                t.column("knowledgeEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("skillsJSON", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // 升级旧表：补 nickname / skillsJSON 列
            let columns = try database.columns(in: "agents").map { $0.name }
            if !columns.contains("providerID") {
                try database.alter(table: "agents") { t in t.add(column: "providerID", .text) }
            }
            if !columns.contains("knowledgeEnabled") {
                try database.alter(table: "agents") { t in
                    t.add(column: "knowledgeEnabled", .boolean).notNull().defaults(to: true)
                }
            }
            if !columns.contains("nickname") {
                try database.alter(table: "agents") { t in
                    t.add(column: "nickname", .text).notNull().defaults(to: "")
                }
            }
            if !columns.contains("skillsJSON") {
                try database.alter(table: "agents") { t in
                    t.add(column: "skillsJSON", .text).notNull().defaults(to: "[]")
                }
            }
            // 升级旧表：补性格/说话风格列（空串 = 未设置，行为与旧版一致）
            if !columns.contains("personality") {
                try database.alter(table: "agents") { t in
                    t.add(column: "personality", .text).notNull().defaults(to: "")
                }
            }
            if !columns.contains("speakingStyle") {
                try database.alter(table: "agents") { t in
                    t.add(column: "speakingStyle", .text).notNull().defaults(to: "")
                }
            }
    }

    public func save(_ agent: Agent) async throws {
        try await databaseQueue.maintenanceWrite { db in
            var row = AgentRow(from: agent)
            try row.save(db)
        }
    }

    public func getAll() async throws -> [Agent] {
        try await databaseQueue.read { db in
            try AgentRow
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .compactMap { $0.toAgent() }
        }
    }

    public func delete(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try AgentRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }
}

private struct AgentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agents"

    var id: String
    var name: String
    var nickname: String
    var icon: String
    var description: String
    var systemPrompt: String
    var personality: String
    var speakingStyle: String
    var modelName: String
    var providerID: String?
    var knowledgeEnabled: Bool
    var isEnabled: Bool
    var skillsJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(from agent: Agent) {
        self.id = agent.id.uuidString
        self.name = agent.name
        self.nickname = agent.nickname
        self.icon = agent.icon
        self.description = agent.description
        self.systemPrompt = agent.systemPrompt
        self.personality = agent.personality
        self.speakingStyle = agent.speakingStyle
        self.modelName = agent.modelName
        self.providerID = agent.providerID?.uuidString
        self.knowledgeEnabled = agent.knowledgeEnabled
        self.isEnabled = agent.isEnabled
        self.skillsJSON = (try? JSONEncoder().encode(agent.skillNames))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.createdAt = agent.createdAt
        self.updatedAt = agent.updatedAt
    }

    func toAgent() -> Agent? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let skillNames = skillsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var agent = Agent(
            id: uuid,
            name: name,
            nickname: nickname,
            icon: icon,
            description: description,
            systemPrompt: systemPrompt,
            personality: personality,
            speakingStyle: speakingStyle,
            modelName: modelName,
            providerID: providerID.flatMap(UUID.init(uuidString:)),
            knowledgeEnabled: knowledgeEnabled,
            isEnabled: isEnabled,
            skillNames: skillNames
        )
        agent.createdAt = createdAt
        agent.updatedAt = updatedAt
        return agent
    }
}

// MARK: - Skill Service

/// 技能服务：绑定单一空间库
public final class SkillService: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表 + 旧库升级（由 `DatabaseBootstrap` 的迁移器集中调用）
    static func createSchema(_ database: Database) throws {
        if try !database.tableExists("skills") {
            try database.create(table: "skills") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("description", .text).notNull().defaults(to: "")
                    t.column("content", .text).notNull().defaults(to: "")
                    t.column("allowedTools", .text).notNull().defaults(to: "")
                    t.column("isEnabled", .boolean).notNull().defaults(to: true)
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                    // 旧版字段：仅为兼容旧库保留，新数据不再写入
                    t.column("type", .text).notNull().defaults(to: "skill")
                    t.column("configJSON", .text).notNull().defaults(to: "{}")
                }
                return
            }
            // 旧库升级：补充新标准字段
            let columns = try Set(database.columns(in: "skills").map(\.name))
            try database.alter(table: "skills") { t in
                if !columns.contains("content") {
                    t.add(column: "content", .text).notNull().defaults(to: "")
                }
                if !columns.contains("allowedTools") {
                    t.add(column: "allowedTools", .text).notNull().defaults(to: "")
                }
            }
    }

    public func save(_ skill: Skill) async throws {
        try await databaseQueue.maintenanceWrite { db in
            var row = SkillRow(from: skill)
            try row.save(db)
        }
    }

    public func getAll() async throws -> [Skill] {
        try await databaseQueue.read { db in
            try SkillRow
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .compactMap { $0.toSkill() }
        }
    }

    public func delete(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            _ = try SkillRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }
}

private struct SkillRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "skills"

    var id: String
    var name: String
    var description: String
    var content: String
    var allowedTools: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    // 旧版字段（仅旧库存在值）
    var type: String
    var configJSON: String

    init(from skill: Skill) {
        self.id = skill.id.uuidString
        self.name = skill.name
        self.description = skill.description
        self.content = skill.content
        self.allowedTools = skill.allowedTools
        self.isEnabled = skill.isEnabled
        self.createdAt = skill.createdAt
        self.updatedAt = skill.updatedAt
        self.type = "skill"
        self.configJSON = "{}"
    }

    func toSkill() -> Skill? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var skillContent = content
        // 旧数据迁移：content 为空时从 configJSON 还原（prompt 直取；apiCall 转写为指令）
        if skillContent.isEmpty, let data = configJSON.data(using: .utf8),
           let config = try? JSONDecoder().decode([String: String].self, from: data),
           !config.isEmpty {
            if type == "apiCall" {
                let method = (config["method"] ?? "GET").uppercased()
                var text = "Call the external API with HTTP \(method) \(config["url"] ?? "")."
                if let body = config["body"], !body.isEmpty {
                    text += "\nRequest body template:\n\(body)"
                }
                skillContent = text
            } else {
                skillContent = config["prompt"] ?? ""
            }
        }
        var skill = Skill(
            id: uuid,
            name: name,
            description: description,
            content: skillContent,
            allowedTools: allowedTools,
            isEnabled: isEnabled
        )
        skill.createdAt = createdAt
        skill.updatedAt = updatedAt
        return skill
    }
}
