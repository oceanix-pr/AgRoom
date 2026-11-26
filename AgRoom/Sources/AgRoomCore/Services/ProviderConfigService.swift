import Foundation
import GRDB

// MARK: - Provider Config Service

/// LLM 提供者配置服务（全局库）：配置入全局 sqlite，API Key 仅存 Keychain
public final class ProviderConfigService: @unchecked Sendable {
    public enum MoveDirection: Sendable { case up, down }
    public enum OrderingError: Error, Sendable { case providerNotFound }
    /// 只广播配置已提交，不携带提供商资料或凭据，也不代表远端连接测试成功。
    public static let configurationDidChange = Notification.Name("agroom.provider.configurationDidChange")
    private let databaseQueue: DatabaseQueue
    public let modelParameters: ModelParameterService

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
        self.modelParameters = ModelParameterService(databaseQueue: databaseQueue)
    }

    /// 建表（由 `DatabaseBootstrap` 的迁移器集中调用）
    static func createSchema(_ database: Database) throws {
        try database.create(table: "llm_providers", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("alias", .text).notNull().defaults(to: "")
            t.column("endpoint", .text).notNull()
            t.column("model", .text).notNull().defaults(to: "")
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("createdAt", .datetime).notNull()
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
        }
    }

    static func addAliasColumn(_ database: Database) throws {
        guard try !database.columns(in: "llm_providers").contains(where: { $0.name == "alias" }) else { return }
        try database.alter(table: "llm_providers") { table in
            table.add(column: "alias", .text).notNull().defaults(to: "")
        }
    }

    static func addSortOrderColumn(_ database: Database) throws {
        guard try !database.columns(in: "llm_providers").contains(where: { $0.name == "sortOrder" }) else { return }
        try database.alter(table: "llm_providers") { table in
            table.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
        }
        // Retain the previous creation-time order, including insertion order for ties.
        let ids = try String.fetchAll(database, sql: "SELECT id FROM llm_providers ORDER BY createdAt ASC, rowid ASC")
        for (index, id) in ids.enumerated() {
            try database.execute(sql: "UPDATE llm_providers SET sortOrder=? WHERE id=?", arguments: [index, id])
        }
    }

    // MARK: - CRUD

    /// 保存提供者配置；apiKey 非空时先落 Keychain，失败则整体报错。
    /// 端点入库前规范化（补齐被截断的 API 路径），避免「检测可用但对话 404」
    public func save(_ config: LLMProviderConfig, apiKey: String?) async throws {
        if let apiKey, !apiKey.isEmpty {
            try KeychainService.saveAPIKey(apiKey, for: config.id)
        }
        var normalized = config
        normalized.endpoint = CloudProvider.normalizedEndpoint(config.endpoint)
        let row = ProviderRow(from: normalized)
        try await databaseQueue.write { db in
            var record = row
            if let existingOrder = try Int.fetchOne(db, sql: "SELECT sortOrder FROM llm_providers WHERE id=?", arguments: [record.id]) {
                record.sortOrder = existingOrder
            } else {
                record.sortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM llm_providers") ?? -1) + 1
            }
            try record.save(db)
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: nil)
    }

    public func getAll() async throws -> [LLMProviderConfig] {
        try await databaseQueue.read { db in
            try Self.orderedRows(in: db).compactMap { $0.toConfig() }
        }
    }

    /// Apply an adjacent move to the latest database order, updating only positions.
    /// A stale settings row cannot overwrite model details or concurrent additions.
    public func move(id: UUID, direction: MoveDirection) async throws -> [LLMProviderConfig] {
        let (changed, configurations) = try await databaseQueue.write { db in
            var rows = try Self.orderedRows(in: db).filter { UUID(uuidString: $0.id) != nil }
            guard let index = rows.firstIndex(where: { UUID(uuidString: $0.id) == id }) else { throw OrderingError.providerNotFound }
            let destination = index + (direction == .up ? -1 : 1)
            guard rows.indices.contains(destination) else { return (false, rows.compactMap { $0.toConfig() }) }
            rows.swapAt(index, destination)
            for (position, row) in rows.enumerated() {
                try db.execute(sql: "UPDATE llm_providers SET sortOrder=? WHERE id=?", arguments: [position, row.id])
            }
            return (true, rows.compactMap { $0.toConfig() })
        }
        if changed { NotificationCenter.default.post(name: Self.configurationDidChange, object: nil) }
        return configurations
    }

    private static func orderedRows(in db: Database) throws -> [ProviderRow] {
        try ProviderRow.order(Column("sortOrder").asc, Column("createdAt").asc, Column("id").asc).fetchAll(db)
    }

    /// 当前生效提供者：优先用户在对话栏选择的（agroom.chat.providerId），
    /// 选中项被停用/删除时回退首个启用者
    public func activeProvider(usageRecorder: ProviderUsageRecorder? = nil, mode: ChatMode = .chat) async throws -> CloudProvider? {
        guard let config = try await activeConfiguration() else { return nil }
        let key = KeychainService.loadAPIKey(for: config.id) ?? ""
        return CloudProvider(config: config, apiKey: key, usageRecorder: usageRecorder, parameterService: modelParameters, parameterMode: mode)
    }

    public func activeConfiguration() async throws -> LLMProviderConfig? {
        let all = try await getAll()
        let enabled = all.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return nil }
        let preferredID = UserDefaults.standard.string(forKey: "agroom.chat.providerId")
            .flatMap(UUID.init(uuidString:))
        let config = enabled.first(where: { $0.id == preferredID }) ?? enabled[0]
        return config
    }

    /// A frozen run remains bound to its selected provider/model, even if the composer changes.
    public func provider(matching parameters: ResolvedModelParameters, usageRecorder: ProviderUsageRecorder?, mode: ChatMode) async throws -> CloudProvider? {
        guard let config = try await getAll().first(where: {
            $0.id == parameters.providerID && $0.isEnabled && $0.model == parameters.config.modelName
                && CloudProvider.normalizedEndpoint($0.endpoint) == parameters.endpoint
        }) else { return nil }
        return CloudProvider(config: config, apiKey: KeychainService.loadAPIKey(for: config.id) ?? "",
            usageRecorder: usageRecorder, parameterService: modelParameters, parameterMode: mode)
    }

    /// Reuses the central configuration and Keychain without creating a second credential store.
    public func provider(id: UUID, usageRecorder: ProviderUsageRecorder?) async throws -> CloudProvider {
        guard let config = try await getAll().first(where: { $0.id == id && $0.isEnabled }) else { throw AgentModelError.providerUnavailable }
        try EndpointSafety.validate(config.endpoint)
        return CloudProvider(config: config, apiKey: KeychainService.loadAPIKey(for: id) ?? "", usageRecorder: usageRecorder, parameterService: modelParameters)
    }

    /// Automatic graph work stays pinned to the provider/model explicitly enabled by the user.
    public func graphProvider(id: UUID, model: String, usageRecorder: ProviderUsageRecorder?) async throws -> CloudProvider {
        guard let config = try await getAll().first(where: { $0.id == id && $0.isEnabled && $0.model == model }) else {
            throw KnowledgeGraphError.configurationChanged
        }
        return CloudProvider(config: config, apiKey: KeychainService.loadAPIKey(for: id) ?? "", usageRecorder: usageRecorder, parameterService: modelParameters)
    }

    public func delete(id: UUID) async throws {
        try await databaseQueue.write { db in
            _ = try ProviderRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
        do {
            try KeychainService.deleteAPIKey(for: id)
        } catch {
            HubLogger.shared.warning("Failed to remove API key from Keychain: \(HubLogger.safeErrorSummary(error))")
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: nil)
    }

    // MARK: - Connection Test

    /// 真实连接测试：发一次最小请求验证端点/密钥/模型可用
    public func testConnection(config: LLMProviderConfig, apiKey: String, usageRecorder: ProviderUsageRecorder? = nil) async -> Result<String, Error> {
        do {
            try EndpointSafety.validate(config.endpoint)
            let provider = CloudProvider(config: config, apiKey: apiKey, usageRecorder: usageRecorder)
            if provider.isImageGenerationModel() {
                guard try await provider.listModels().contains(config.model) else {
                    throw ImageGenerationError.modelUnavailable
                }
                return .success("image-model-metadata")
            }
            let probeConfig = LLMConfig(modelName: config.model, maxTokens: 8, temperature: 0)
            let output = try await provider.generate(prompt: "ping", config: probeConfig)
            return .success(String(output.prefix(100)))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - GRDB Row

private struct ProviderRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "llm_providers"

    var id: String
    var name: String
    var alias: String
    var endpoint: String
    var model: String
    var isEnabled: Bool
    var createdAt: Date
    var sortOrder: Int

    init(from config: LLMProviderConfig) {
        self.id = config.id.uuidString
        self.name = config.name
        self.alias = config.alias
        self.endpoint = config.endpoint
        self.model = config.model
        self.isEnabled = config.isEnabled
        self.createdAt = config.createdAt
        self.sortOrder = 0
    }

    func toConfig() -> LLMProviderConfig? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var config = LLMProviderConfig(
            id: uuid,
            name: name,
            endpoint: endpoint,
            model: model,
            isEnabled: isEnabled,
            alias: alias
        )
        config.createdAt = createdAt
        return config
    }
}
