import Foundation
import GRDB

// MARK: - Session Service Error

public enum SessionServiceError: LocalizedError, Equatable {
    /// 会话行与模型不兼容；不向 UI 透传可能含会话内容的 GRDB 行诊断。
    case recordDecodingFailed
    /// 单条消息编码失败：抛错保留库内旧数据，绝不静默清空
    case messageEncodingFailed(index: Int)
    case staleAfterRestore
    /// 会话存在损坏消息行：拒绝普通覆盖保存，避免用缺内容的数组清掉库内原行
    case saveBlockedByCorruption(sessionId: String)

    public var errorDescription: String? {
        switch self {
        case .recordDecodingFailed:
            return "Unable to decode chat records; check database migrations and record format."
        case .messageEncodingFailed(let index):
            return "Failed to encode chat message at index \(index); existing data preserved."
        case .staleAfterRestore:
            return "This conversation was restored. Reload it before saving or continuing."
        case .saveBlockedByCorruption(let sessionId):
            return "Session \(sessionId) has corrupted message rows; repair before saving."
        }
    }
}

/// 消息读取结果：正文 + 健康态 + 损坏行占用的持久化 seq。
/// 调用方据此区分「正常短会话」与「读坏后只剩几条」，并按 seq 定位原始坏行
public struct LoadedMessages: Sendable {
    public var restorationToken: String?
    public var pendingConfirmation: PendingConfirmationSnapshot?
    public var pendingQuestion: PendingQuestionSnapshot?
    public let messages: [ChatMessage]
    public let health: MessageLoadHealth
    /// 无法解码的持久化 seq（仅分表行；旧整包损坏时为空，健康态为 corruptLegacyBlob）
    public let corruptedSeqs: [Int]

    public init(messages: [ChatMessage], health: MessageLoadHealth, corruptedSeqs: [Int]) {
        self.messages = messages
        self.health = health
        self.corruptedSeqs = corruptedSeqs
    }
}

public struct LoadedMessagePage: Sendable {
    public let messages: [ChatMessage]
    public let health: MessageLoadHealth
    public let offset: Int
    public var restorationToken: String? = nil
    public var pendingConfirmation: PendingConfirmationSnapshot? = nil
    public var pendingQuestion: PendingQuestionSnapshot? = nil
}

public struct SessionRestoreVersion: Sendable {
    public let id: UUID
    public let token: String?
    public init(id: UUID, token: String?) { self.id = id; self.token = token }
}

/// 损坏消息修复结果：坏行已隔离（原文保留），可读行已压实为连续 seq
public struct MessageRepairResult: Sendable, Equatable {
    /// 移入隔离区的坏行数量（旧格式整包损坏时计 1）
    public let quarantinedCount: Int
    /// 修复后保留的可读消息条数
    public let remainingCount: Int
    /// 是否处理的是旧格式整包损坏（messagesJSON 解不开）
    public let wasLegacyBlob: Bool

    public init(quarantinedCount: Int, remainingCount: Int, wasLegacyBlob: Bool) {
        self.quarantinedCount = quarantinedCount
        self.remainingCount = remainingCount
        self.wasLegacyBlob = wasLegacyBlob
    }
}

// MARK: - Session Service

/// The expectation contains record identity, restore generation and a
/// reason-free state category. No message text or database path escapes a
/// space-bound SessionService probe; callers must not log the restore token.
struct LegacyDaemonRecordExpectation: Sendable, Equatable {
    let sessionID: UUID
    let assistantMessageID: UUID
    let taskRunID: UUID?
    let restorationToken: String?
    let state: DaemonLegacyInventory.BodyState

    init(sessionID: UUID, assistantMessageID: UUID, taskRunID: UUID?,
         restorationToken: String?, state: DaemonLegacyInventory.BodyState) {
        self.sessionID = sessionID
        self.assistantMessageID = assistantMessageID
        self.taskRunID = taskRunID
        self.restorationToken = restorationToken
        self.state = state
    }

    init(record: DaemonRunRecord) {
        self.init(sessionID: record.sessionId,
                  assistantMessageID: record.assistantMessageId,
                  taskRunID: record.settings.taskAuthorization?.runID,
                  restorationToken: record.restorationToken,
                  state: DaemonLegacyInventory.bodyState(record.state))
    }
}

enum LegacyDaemonRecordProbeResult: Sendable, Equatable {
    case exact, missing, conflict, unavailable
}

/// 会话持久化服务：绑定单一空间的 DatabaseQueue（空间隔离红线）。
/// 消息分表存储（chat_messages，按行）：会话主表只存元数据，
/// 流式落盘只写脏行而非整包 JSON（消灭写放大）；旧库 messagesJSON 自动迁移
public final class SessionService: @unchecked Sendable {
    var maintenanceKey: String { databaseQueue.maintenanceKey }
    let databaseQueue: DatabaseQueue
    private let expectedRestoreVersion: SessionRestoreVersion?

    public init(databaseQueue: DatabaseQueue, expectedRestoreVersion: SessionRestoreVersion? = nil) {
        self.databaseQueue = databaseQueue
        self.expectedRestoreVersion = expectedRestoreVersion
    }

    private static func restorationToken(_ id: UUID, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT token FROM chat_restore_tokens WHERE sessionId=?", arguments: [id.uuidString])
    }

    public func checkRestorationVersion() async throws {
        guard let expectedRestoreVersion else { return }
        try await databaseQueue.read { db in
            guard try Self.restorationToken(expectedRestoreVersion.id, in: db) == expectedRestoreVersion.token else {
                throw SessionServiceError.staleAfterRestore
            }
        }
    }

    /// A migration preflight reads only this already-bound database queue.
    /// The caller must select the queue from a trustworthy record space; this
    /// result is never an authorization to move files or resume a run.
    func probeLegacyDaemonRecord(_ expected: LegacyDaemonRecordExpectation) async -> LegacyDaemonRecordProbeResult {
        do {
            return try await databaseQueue.read { db in
                let sessionID = expected.sessionID.uuidString
                guard let row = try SessionRow.fetchOne(db, key: sessionID) else { return .missing }
                guard row.id == sessionID,
                      try Self.restorationToken(expected.sessionID, in: db) == expected.restorationToken else {
                    return .conflict
                }
                // A damaged or ambiguous message source cannot establish
                // message absence, even if the target ID is unseen.
                let splitCount = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM chat_messages WHERE sessionId = ?",
                    arguments: [sessionID]) ?? 0
                if row.messagesJSON.count > 2 && splitCount > 0 { return .conflict }
                let loaded = try Self.loadMessagesDetailed(sessionId: sessionID,
                    legacyJSON: row.messagesJSON, in: db)
                guard loaded.health == .healthy else { return .unavailable }
                let matches = loaded.messages.filter { $0.id == expected.assistantMessageID }
                guard !matches.isEmpty else { return .missing }
                guard matches.count == 1, let message = matches.first,
                      message.role == .assistant,
                      message.taskRun?.id == expected.taskRunID,
                      message.sourceTaskRunID == nil,
                      row.pendingConfirmationJSON?.isEmpty != false,
                      row.pendingQuestionJSON?.isEmpty != false else { return .conflict }
                if let variations = message.variations, !variations.isEmpty {
                    guard variations.indices.contains(message.activeVariationIndex),
                          variations[message.activeVariationIndex].taskRun?.id == expected.taskRunID else {
                        return .conflict
                    }
                }
                switch expected.state {
                case .completed:
                    switch message.runStatus {
                    case .succeeded, .incomplete, .failed, .cancelled: return .exact
                    default: return .conflict
                    }
                case .recoveryRequired:
                    switch message.runStatus {
                    case .running, .recoveryRequired: return .exact
                    default: return .conflict
                    }
                case .active:
                    return .conflict
                }
            }
        } catch {
            return .unavailable
        }
    }

    private func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        let expected = expectedRestoreVersion
        return try await databaseQueue.maintenanceWrite { db in
            if let expected, try Self.restorationToken(expected.id, in: db) != expected.token {
                throw SessionServiceError.staleAfterRestore
            }
            return try updates(db)
        }
    }

    static func createRestoreSchema(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS chat_restore_tokens (sessionId TEXT PRIMARY KEY NOT NULL, token TEXT NOT NULL)")
    }

    func invalidateRestoredSnapshots(ids: [UUID]) async throws {
        let token = UUID().uuidString
        try await write { db in
            for id in ids {
                try db.execute(sql: "INSERT OR REPLACE INTO chat_restore_tokens(sessionId,token) VALUES (?,?)", arguments: [id.uuidString, token])
            }
        }
    }

    /// 建表 + 旧库升级（由 `DatabaseBootstrap` 的迁移器集中调用）。
    /// 构造函数不再产生建表副作用：迁移失败时该库不可用，不会构造出半可用的服务
    public func latestMessage(id: UUID) async throws -> ChatMessage? {
        try await databaseQueue.read { db in
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM chat_messages WHERE sessionId = ? ORDER BY seq DESC LIMIT 1", arguments: [id.uuidString]),
                  let data = payload.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(ChatMessage.self, from: data)
        }
    }

    static func createSchema(_ database: Database) throws {
        try createRestoreSchema(database)
        try database.create(table: "chat_sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                // 历史列：迁移后恒为 '[]'（消息在 chat_messages 表；保留列避免改表）
                t.column("messagesJSON", .text).notNull().defaults(to: "[]")
                t.column("pendingConfirmationJSON", .text)
                t.column("pendingQuestionJSON", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // 隐藏会话标志（右键隐藏；默认 0 = 未隐藏）
                t.column("isHidden", .boolean).notNull().defaults(to: false)
                // 置顶会话标志（右键置顶；默认 0 = 未置顶）
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                // 归档会话标志（按工作区批量归档；默认 0 = 未归档）
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                // 所属对话工作区 id（NULL = 默认工作区）
                t.column("workspaceId", .text)
                // 会话模式（chat / coding；旧数据默认 chat）
                t.column("mode", .text).notNull().defaults(to: ChatMode.chat.rawValue)
                // 自动审核开关（按会话；默认 0 = 关闭）
                t.column("autoReviewEnabled", .boolean).notNull().defaults(to: false)
                // 权限模式（旧库升级默认完全权限，保持升级前行为）
                t.column("permissionMode", .text)
                    .notNull()
                    .defaults(to: PermissionMode.dangerFullAccess.rawValue)
            }
            // 旧库迁移：补确认挂起/提问挂起快照列（已有列的库跳过）
            let columns = try database.columns(in: "chat_sessions")
            if !columns.contains(where: { $0.name == "pendingConfirmationJSON" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "pendingConfirmationJSON", .text)
                }
            }
            if !columns.contains(where: { $0.name == "pendingQuestionJSON" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "pendingQuestionJSON", .text)
                }
            }
            if !columns.contains(where: { $0.name == "isHidden" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "isHidden", .boolean).notNull().defaults(to: false)
                }
            }
            if !columns.contains(where: { $0.name == "isPinned" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
                }
            }
            if !columns.contains(where: { $0.name == "isArchived" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
                }
            }
            if !columns.contains(where: { $0.name == "workspaceId" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "workspaceId", .text)
                }
            }
            if !columns.contains(where: { $0.name == "mode" }) {
                try database.alter(table: "chat_sessions") { t in
                    t.add(column: "mode", .text).notNull().defaults(to: ChatMode.chat.rawValue)
                }
            }
            // 自动审核开关列：v1_chat 对已迁移的旧库不会重跑，故另由 v2_chat_auto_review 补列
            try addAutoReviewColumn(database)
            // 权限模式列：同样由独立迁移补齐旧库
            try addPermissionModeColumn(database)
            try addDataPolicyColumn(database)
            try database.create(index: "idx_sessions_updatedAt", on: "chat_sessions", columns: ["updatedAt"], ifNotExists: true)

            // 消息分表（sessionId + seq 联合主键，按序读取）
            try database.create(table: "chat_messages", ifNotExists: true) { t in
                t.column("sessionId", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("payload", .text).notNull()
                t.primaryKey(["sessionId", "seq"])
            }
            // 旧数据迁移：messagesJSON 有内容的会话逐条搬入分表，成功后清空旧列；
            // 失败的会话保留原 JSON（下次启动重试），不丢数据
            try migrateMessagesIfNeeded(database)
    }

    /// 补 autoReviewEnabled 列（幂等）。
    /// v1_chat 只对首次建库的会话表生效：已迁移过的旧库不会重跑 createSchema，
    /// 因此必须由独立迁移 v2_chat_auto_review 再执行一次，否则旧库缺列，
    /// SessionRow 解码会抛 GRDB.RowDecodingError
    static func addAutoReviewColumn(_ database: Database) throws {
        let columns = try database.columns(in: "chat_sessions")
        guard !columns.contains(where: { $0.name == "autoReviewEnabled" }) else { return }
        try database.alter(table: "chat_sessions") { t in
            t.add(column: "autoReviewEnabled", .boolean).notNull().defaults(to: false)
        }
    }

    /// 补 permissionMode 列（幂等）。旧库默认完全权限，避免升级后突然收紧
    /// 既有会话的 shell/文件能力；新会话由 ChatSession 初始化值决定。
    static func addPermissionModeColumn(_ database: Database) throws {
        let columns = try database.columns(in: "chat_sessions")
        guard !columns.contains(where: { $0.name == "permissionMode" }) else { return }
        try database.alter(table: "chat_sessions") { t in
            t.add(column: "permissionMode", .text)
                .notNull()
                .defaults(to: PermissionMode.dangerFullAccess.rawValue)
        }
    }

    static func addDataPolicyColumn(_ db: Database) throws {
        let columns = Set(try db.columns(in: "chat_sessions").map(\.name))
        if !columns.contains("dataPolicy") {
            try db.alter(table: "chat_sessions") { $0.add(column: "dataPolicy", .text).notNull().defaults(to: TaskDataPolicy.configuredServices.rawValue) }
        }
        if !columns.contains("allowsHostExecution") {
            try db.alter(table: "chat_sessions") { $0.add(column: "allowsHostExecution", .boolean).notNull().defaults(to: true) }
        }
    }

    public func dataPolicy(id: UUID) async throws -> TaskDataPolicy? {
        try await executionAccess(id: id)?.dataPolicy
    }

    func executionAccess(id: UUID) async throws -> (dataPolicy: TaskDataPolicy, allowsHost: Bool)? {
        try await databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT dataPolicy, allowsHostExecution FROM chat_sessions WHERE id = ?",
                                             arguments: [id.uuidString]) else { return nil }
            return (TaskDataPolicy(rawValue: row["dataPolicy"]) ?? .localOnly, row["allowsHostExecution"])
        }
    }

    public func setDataPolicy(id: UUID, policy: TaskDataPolicy, allowsHostExecution: Bool? = nil, restorationToken: String?) async throws {
        try await write { db in
            guard try Self.restorationToken(id, in: db) == restorationToken else { throw SessionServiceError.staleAfterRestore }
            try db.execute(sql: "UPDATE chat_sessions SET dataPolicy = ?, allowsHostExecution = COALESCE(?, allowsHostExecution) WHERE id = ?",
                           arguments: [policy.rawValue, allowsHostExecution, id.uuidString])
        }
    }

    /// 补 isArchived 列（幂等）。v1_chat 对已迁移的旧库不会重跑，
    /// 因此必须由独立迁移 v3_chat_archive 再执行一次，否则旧库缺列，
    /// SessionRow 解码会抛 GRDB.RowDecodingError
    static func addIsArchivedColumn(_ database: Database) throws {
        let columns = try database.columns(in: "chat_sessions")
        guard !columns.contains(where: { $0.name == "isArchived" }) else { return }
        try database.alter(table: "chat_sessions") { t in
            t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
        }
    }

    /// 旧库 → 分表一次性迁移（幂等：messagesJSON 已清空的行自动跳过）
    private static func migrateMessagesIfNeeded(_ database: Database) throws {
        let legacyRows = try SessionRow.fetchAll(database)
        for row in legacyRows where row.messagesJSON.count > 2 {
            guard let data = row.messagesJSON.data(using: .utf8) else { continue }
            do {
                let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
                for (seq, message) in messages.enumerated() {
                    try database.execute(
                        sql: "INSERT OR REPLACE INTO chat_messages (sessionId, seq, payload) VALUES (?, ?, ?)",
                        arguments: [row.id, seq, try Self.encodeMessage(message, index: seq)]
                    )
                }
                try database.execute(
                    sql: "UPDATE chat_sessions SET messagesJSON = '[]' WHERE id = ?",
                    arguments: [row.id]
                )
                HubLogger.shared.info("Session messages migrated to chat_messages: \(row.id) (\(messages.count) messages)")
            } catch {
                HubLogger.shared.error("Session \(row.id) migration failed, legacy JSON kept for retry: \(HubLogger.safeErrorSummary(error))")
            }
        }
    }

    // MARK: - CRUD

    /// 保存会话。changedMessageIndexFrom 提供时只重写该下标起的脏行
    /// （流式落盘单行更新）；消息数变少时尾部自动截断。
    /// 编码失败抛错：库内旧数据原样保留。
    ///
    /// 会话读取时发现损坏（`messageLoadHealth != .healthy`）会拒绝普通保存：
    /// 内存里的 messages 是「跳过坏行后的压缩数组」，按下标写回会用缺内容的
    /// 数组覆盖库内原行、并让后续正常行错位。必须显式走修复流程或由调用方
    /// 明确 `allowRepairOverwrite` 承担覆盖后果。
    public func save(
        _ session: ChatSession,
        changedMessageIndexFrom: Int? = nil,
        allowRepairOverwrite: Bool = false,
        branchSource: SessionRestoreVersion? = nil
    ) async throws {
        if session.messageLoadHealth != .healthy && !allowRepairOverwrite {
            throw SessionServiceError.saveBlockedByCorruption(sessionId: session.id.uuidString)
        }
        let from = changedMessageIndexFrom.map { Swift.max(0, Swift.min($0, session.messages.count)) } ?? 0
        // 只编码脏区间（部分更新时跳过前方未变消息）；失败抛错保数据
        var encoded: [(seq: Int, payload: String, message: ChatMessage)] = []
        for seq in from..<session.messages.count {
            encoded.append((session.messageOffset + seq, try Self.encodeMessage(session.messages[seq], index: seq), session.messages[seq]))
        }
        // 闭包捕获不可变副本（GRDB 写闭包可并发执行，var 捕获会撕裂）
        let rows = encoded
        let rowId = session.id.uuidString
        let restoring = ResourceMaintenance.owned.contains(maintenanceKey)
        try await write { db in
            if let branchSource {
                guard try SessionRow.exists(db, key: branchSource.id.uuidString),
                      try Self.restorationToken(branchSource.id, in: db) == branchSource.token else {
                    throw SessionServiceError.staleAfterRestore
                }
            }
            if !restoring, try Self.restorationToken(session.id, in: db) != session.restorationToken {
                throw SessionServiceError.staleAfterRestore
            }
            if session.messageOffset > 0, try SessionRow.fetchOne(db, key: rowId) == nil {
                throw SessionServiceError.recordDecodingFailed
            }
            var row = SessionRow(from: session)
            try row.save(db)
            if changedMessageIndexFrom == nil && session.messageOffset == 0 {
                try db.execute(
                    sql: "DELETE FROM chat_messages WHERE sessionId = ?",
                    arguments: [rowId]
                )
            } else if session.messages.count > 0 {
                // 尾部截断（重试/编辑重发删除后续消息时）
                try db.execute(
                    sql: "DELETE FROM chat_messages WHERE sessionId = ? AND seq >= ?",
                    arguments: [rowId, session.messageOffset + session.messages.count]
                )
            }
            for item in rows {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO chat_messages (sessionId, seq, payload) VALUES (?, ?, ?)",
                    arguments: [rowId, item.seq, item.payload]
                )
            }
            if !restoring, try db.tableExists("product_task_runs") {
                var prompt = try ProductTaskRunStore.precedingPrompt(db, sessionID: session.id, before: rows.first?.seq ?? 0)
                for item in rows {
                    if item.message.role == .user { prompt = item.message.content }
                    else { try ProductTaskRunStore.capture(item.message, sessionID: session.id, workspaceID: session.workspaceId,
                        mode: session.mode, prompt: prompt, in: db) }
                }
            }
        }
        if !restoring { await MainActor.run { NotificationCenter.default.post(name: ProductTaskRunStore.didChange, object: nil) } }
    }

    /// 单条消息编码（失败抛错——保数据优先于保进度）
    private static func encodeMessage(_ message: ChatMessage, index: Int) throws -> String {
        guard let data = try? JSONEncoder().encode(message),
              let payload = String(data: data, encoding: .utf8) else {
            throw SessionServiceError.messageEncodingFailed(index: index)
        }
        return payload
    }

    public func getAll() async throws -> [ChatSession] {
        try await databaseQueue.read { db in
            try SessionRow
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .map { row -> ChatSession in
                    guard var session = row.toSession() else { throw SessionServiceError.recordDecodingFailed }
                    let loaded = try Self.loadMessagesDetailed(sessionId: row.id, legacyJSON: row.messagesJSON, in: db)
                    session.messages = loaded.messages
                    session.messageLoadHealth = loaded.health
                    session.isMessagesLoaded = true
                    session.restorationToken = try Self.restorationToken(session.id, in: db)
                    return session
                }
        }
    }

    /// 摘要列表：只提取列表展示所需字段（id/标题/时间/隐藏标志），不反序列化完整消息，
    /// 返回的会话 isMessagesLoaded=false，切换到该会话时经 getMessages(id:) 按需加载
    public func getSummaries() async throws -> [ChatSession] {
        do {
            return try await databaseQueue.read { db in
                try SessionRow
                    .order(Column("updatedAt").desc)
                    .fetchAll(db)
                    .compactMap { row -> ChatSession? in
                        guard let uuid = UUID(uuidString: row.id) else { return nil }
                        var session = ChatSession(id: uuid, title: row.title, createdAt: row.createdAt)
                        session.updatedAt = row.updatedAt
                        session.restorationToken = try Self.restorationToken(uuid, in: db)
                        session.isHidden = row.isHidden
                        session.isPinned = row.isPinned
                        session.isArchived = row.isArchived
                        session.workspaceId = row.workspaceId
                        session.mode = ChatMode(rawValue: row.mode) ?? .chat
                        session.autoReviewEnabled = row.autoReviewEnabled
                        session.allowsHostExecution = row.allowsHostExecution
                        session.dataPolicy = TaskDataPolicy(rawValue: row.dataPolicy) ?? .localOnly
                        session.permissionMode = PermissionMode(rawValue: row.permissionMode)
                            ?? .dangerFullAccess
                        // 标题派生：旧数据 title 为空时取首条用户消息前 30 字符（与 displayTitle 一致）
                        if session.title.isEmpty {
                            let dicts = try Self.messageDicts(sessionId: row.id, legacyJSON: row.messagesJSON, limit: 6, in: db)
                            session.title = Self.firstUserMessagePrefix(in: dicts)
                        }
                        session.isMessagesLoaded = false
                        return session
                    }
            }
        } catch is RowDecodingError {
            HubLogger.shared.error("Chat summary decoding failed; check database migrations and record format")
            throw SessionServiceError.recordDecodingFailed
        }
    }

    /// 按需加载单个会话的完整消息列表
    public func getMessages(id: UUID) async throws -> [ChatMessage] {
        try await getMessagesDetailed(id: id).messages
    }

    /// 正文候选检索：返回消息正文（或未迁移的旧整包）命中查询的会话 id，按 updatedAt 降序。
    /// 供全局搜索「按需加载」——不再为一次搜索把全部会话正文读进内存做全量匹配。
    /// LIKE 通配符按字面转义；ASCII 大小写不敏感由 SQLite LIKE 默认提供
    public func searchSessionIds(matching text: String, limit: Int = 200) async throws -> [UUID] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let pattern = "%\(SQLikeEscaping.escape(trimmed))%"
        return try await databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM chat_sessions
                WHERE id IN (
                    SELECT DISTINCT sessionId FROM chat_messages WHERE payload LIKE ? ESCAPE '\\'
                ) OR messagesJSON LIKE ? ESCAPE '\\'
                ORDER BY updatedAt DESC
                LIMIT ?
                """,
                arguments: [pattern, pattern, limit]
            )
            return rows.compactMap { UUID(uuidString: $0["id"]) }
        }
    }

    /// 按需加载单个会话消息，并返回健康态与损坏行 seq。
    /// 调用方据此区分「正常短会话」与「读坏后只剩几条」：
    /// 非 healthy 时不得据此覆盖保存，应引导用户走修复流程
    public func getMessagesDetailed(id: UUID) async throws -> LoadedMessages {
        try await databaseQueue.read { db in
            guard let row = try SessionRow.filter(Column("id") == id.uuidString).fetchOne(db) else {
                return LoadedMessages(messages: [], health: .healthy, corruptedSeqs: [])
            }
            var loaded = try Self.loadMessagesDetailed(sessionId: row.id, legacyJSON: row.messagesJSON, in: db)
            loaded.restorationToken = try Self.restorationToken(id, in: db)
            let metadata = row.toSession()
            loaded.pendingConfirmation = metadata?.pendingConfirmation
            loaded.pendingQuestion = metadata?.pendingQuestion
            return loaded
        }
    }

    public func getMessagePage(id: UUID, before: Int? = nil, limit: Int = 100) async throws -> LoadedMessagePage {
        try await databaseQueue.read { db in
            guard let session = try SessionRow.fetchOne(db, key: id.uuidString) else {
                return LoadedMessagePage(messages: [], health: .healthy, offset: 0)
            }
            let metadata = before == nil ? session.toSession() : nil
            if session.messagesJSON.count > 2 {
                let loaded = try Self.loadMessagesDetailed(sessionId: session.id, legacyJSON: session.messagesJSON, in: db)
                return LoadedMessagePage(messages: loaded.messages, health: loaded.health, offset: 0, restorationToken: try Self.restorationToken(id, in: db),
                    pendingConfirmation: metadata?.pendingConfirmation, pendingQuestion: metadata?.pendingQuestion)
            }
            let cursor = try Row.fetchCursor(db, sql: "SELECT seq, payload FROM chat_messages WHERE sessionId=? AND seq<? ORDER BY seq DESC LIMIT ?",
                arguments: [id.uuidString, before ?? Int.max, max(1, min(200, limit))])
            var messages: [ChatMessage] = []
            var offset = before ?? 0
            var damaged = 0
            var bytes = 0
            while let row = try cursor.next() {
                let payload: String = row["payload"]
                if bytes + payload.utf8.count > 8 * 1024 * 1024, !messages.isEmpty { break }
                bytes += payload.utf8.count
                offset = row["seq"]
                if let message = try? JSONDecoder().decode(ChatMessage.self, from: Data(payload.utf8)) { messages.append(message) }
                else { damaged += 1 }
            }
            return LoadedMessagePage(messages: messages.reversed(), health: damaged == 0 ? .healthy : .partiallyCorrupted(skipped: damaged), offset: offset,
                restorationToken: try Self.restorationToken(id, in: db), pendingConfirmation: metadata?.pendingConfirmation, pendingQuestion: metadata?.pendingQuestion)
        }
    }

    /// 取完整会话（元数据 + 消息 + 挂起快照）：恢复回滚的 before-image 用。
    /// 返回 nil 表示库内不存在该会话（回滚时按「本次新增」删除）
    public func fetch(id: UUID) async throws -> ChatSession? {
        try await databaseQueue.read { db in
            guard let row = try SessionRow.filter(Column("id") == id.uuidString).fetchOne(db),
                  var session = row.toSession() else { return nil }
            let loaded = try Self.loadMessagesDetailed(sessionId: row.id, legacyJSON: row.messagesJSON, in: db)
            session.messages = loaded.messages
            session.messageLoadHealth = loaded.health
            session.isMessagesLoaded = true
            session.restorationToken = try Self.restorationToken(id, in: db)
            return session
        }
    }

    // MARK: - 损坏消息修复

    /// 修复会话的损坏消息：把无法解码的行移入隔离表（原文保留，不删除），
    /// 再把剩余可读行压实为连续 seq（0..n-1），使持久化身份恢复一致、后续普通保存可用。
    ///
    /// 旧格式整包损坏（messagesJSON 解不开）时，把整段原文存入隔离表并清空该列，
    /// 让迁移逻辑不再反复尝试解码坏包。只处理消息数据，不触碰会话元数据与其它列。
    @discardableResult
    public func repairCorruptedMessages(sessionId: UUID) async throws -> MessageRepairResult {
        let rowId = sessionId.uuidString
        return try await write { db in
            try db.create(table: "chat_message_quarantine", ifNotExists: true) { t in
                t.column("sessionId", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("payload", .text).notNull()
                t.column("quarantinedAt", .datetime).notNull()
            }
            guard let row = try SessionRow.filter(Column("id") == rowId).fetchOne(db) else {
                return MessageRepairResult(quarantinedCount: 0, remainingCount: 0, wasLegacyBlob: false)
            }
            let now = Date()

            // 旧格式整包损坏：原文隔离后清空列（迁移按空列跳过，不再反复解码坏包）
            if row.messagesJSON.count > 2 {
                let decoded = row.messagesJSON.data(using: .utf8).flatMap {
                    try? JSONDecoder().decode([ChatMessage].self, from: $0)
                }
                if let decoded {
                    // 实际并未损坏：无需修复
                    return MessageRepairResult(quarantinedCount: 0, remainingCount: decoded.count, wasLegacyBlob: false)
                }
                try db.execute(
                    sql: "INSERT INTO chat_message_quarantine (sessionId, seq, payload, quarantinedAt) VALUES (?, ?, ?, ?)",
                    arguments: [rowId, -1, row.messagesJSON, now]
                )
                try db.execute(
                    sql: "UPDATE chat_sessions SET messagesJSON = '[]' WHERE id = ?",
                    arguments: [rowId]
                )
                return MessageRepairResult(quarantinedCount: 1, remainingCount: 0, wasLegacyBlob: true)
            }

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT seq, payload FROM chat_messages WHERE sessionId = ? ORDER BY seq",
                arguments: [rowId]
            )
            let decoder = JSONDecoder()
            var validPayloads: [String] = []
            var quarantined = 0
            for r in rows {
                let seq: Int = r["seq"]
                let payload: String = r["payload"]
                let isReadable = payload.data(using: .utf8).flatMap {
                    try? decoder.decode(ChatMessage.self, from: $0)
                } != nil
                if isReadable {
                    validPayloads.append(payload)
                } else {
                    try db.execute(
                        sql: "INSERT INTO chat_message_quarantine (sessionId, seq, payload, quarantinedAt) VALUES (?, ?, ?, ?)",
                        arguments: [rowId, seq, payload, now]
                    )
                    quarantined += 1
                }
            }
            // 压实 seq：先全清再按序重插，避免剩余行主键冲突
            try db.execute(sql: "DELETE FROM chat_messages WHERE sessionId = ?", arguments: [rowId])
            for (index, payload) in validPayloads.enumerated() {
                try db.execute(
                    sql: "INSERT INTO chat_messages (sessionId, seq, payload) VALUES (?, ?, ?)",
                    arguments: [rowId, index, payload]
                )
            }
            return MessageRepairResult(
                quarantinedCount: quarantined,
                remainingCount: validPayloads.count,
                wasLegacyBlob: false
            )
        }
    }

    // MARK: - Daemon Write-back（守护进程写回）

    /// 原子更新单条消息（守护进程完成后写回正文/思维链/轨迹/用量）：
    /// 在同一个 GRDB 写事务里定位、变异并重写目标行，避免流式进度与终态互相覆盖。
    public func updateMessage(
        sessionId: UUID,
        messageId: UUID,
        expectedTaskRunID: UUID? = nil,
        isProgressUpdate: Bool = false,
        clearPendingForMessage: Bool = false,
        expectedRestorationVersion: SessionRestoreVersion? = nil,
        messageSequence: Int? = nil,
        _ mutate: @Sendable (inout ChatMessage) -> Void
    ) async throws {
        let rowId = sessionId.uuidString
        let restoring = ResourceMaintenance.owned.contains(maintenanceKey)
        try await write { db in
            if let version = expectedRestorationVersion {
                guard version.id == sessionId, try Self.restorationToken(sessionId, in: db) == version.token else {
                    throw SessionServiceError.staleAfterRestore
                }
            }
            let rows: [Row]
            if let messageSequence {
                guard messageSequence >= 0 else { throw SessionServiceError.recordDecodingFailed }
                // The paged UI already knows the stable persisted seq. Verify
                // message and run IDs below without materializing all history.
                rows = try Row.fetchAll(db, sql: "SELECT seq,payload FROM chat_messages WHERE sessionId=? AND seq=?",
                    arguments: [rowId, messageSequence])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT seq,payload FROM chat_messages WHERE sessionId=? ORDER BY seq",
                    arguments: [rowId])
            }
            guard let match = try rows.lazy.compactMap({ row -> (Int, ChatMessage)? in
                let seq: Int = row["seq"]
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else { return nil }
                let message = try JSONDecoder().decode(ChatMessage.self, from: data)
                return message.id == messageId ? (seq, message) : nil
            }).first else { return }
            var message = match.1
            if let expectedTaskRunID, message.taskRun?.id != expectedTaskRunID {
                throw ProductTaskHistoryError.identityConflict
            }
            if clearPendingForMessage {
                guard let row = try SessionRow.fetchOne(db, key: rowId),
                      let session = row.toSession(),
                      session.pendingConfirmation?.messageId == nil || session.pendingConfirmation?.messageId == messageId,
                      session.pendingQuestion?.messageId == nil || session.pendingQuestion?.messageId == messageId else {
                    throw ProductTaskHistoryError.identityConflict
                }
            }
            if isProgressUpdate && message.runStatus?.isTerminal == true { return }
            mutate(&message)
            let payload = try Self.encodeMessage(message, index: match.0)
            try db.execute(
                sql: "UPDATE chat_messages SET payload = ? WHERE sessionId = ? AND seq = ?",
                arguments: [payload, rowId, match.0]
            )
            try db.execute(
                sql: clearPendingForMessage
                    ? "UPDATE chat_sessions SET pendingConfirmationJSON = NULL, pendingQuestionJSON = NULL, updatedAt = ? WHERE id = ?"
                    : "UPDATE chat_sessions SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), rowId]
            )
            if !restoring, try db.tableExists("product_task_runs"), let session = try Row.fetchOne(db, sql: "SELECT workspaceId, mode FROM chat_sessions WHERE id=?", arguments: [rowId]) {
                try ProductTaskRunStore.capture(message, sessionID: sessionId, workspaceID: session["workspaceId"],
                    mode: ChatMode(rawValue: session["mode"] ?? "") ?? .chat,
                    prompt: ProductTaskRunStore.precedingPrompt(db, sessionID: sessionId, before: match.0), in: db)
            }
        }
        if !restoring { await MainActor.run { NotificationCenter.default.post(name: ProductTaskRunStore.didChange, object: nil) } }
    }

    /// 写待确认/待提问挂起展示快照列（守护进程停在挂起上时持久化；
    /// App 重启后只重建人工核对卡，不恢复原审批或作答句柄）。nil = 清空该列
    public func setPending(
        sessionId: UUID,
        confirmation: PendingConfirmationSnapshot?,
        question: PendingQuestionSnapshot?
    ) async throws {
        func encodeJSON<T: Encodable>(_ value: T?) -> String? {
            guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let confirmationJSON = encodeJSON(confirmation)
        let questionJSON = encodeJSON(question)
        let rowId = sessionId.uuidString
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET pendingConfirmationJSON = ?, pendingQuestionJSON = ?, updatedAt = ? WHERE id = ?",
                arguments: [confirmationJSON, questionJSON, Date(), rowId]
            )
        }
    }

    /// 读会话的挂起快照（App 重启/后台完成后恢复确认卡与表单用）
    public func getPendingSnapshots(id: UUID) async throws -> (confirmation: PendingConfirmationSnapshot?, question: PendingQuestionSnapshot?) {
        try await databaseQueue.read { db in
            guard let row = try SessionRow.filter(Column("id") == id.uuidString).fetchOne(db) else {
                return (nil, nil)
            }
            return (row.toSession()?.pendingConfirmation, row.toSession()?.pendingQuestion)
        }
    }

    /// 加载会话消息：优先分表，未迁移的旧数据走 legacy JSON。
    /// 返回健康态：单条解码失败跳过该行但记为 partiallyCorrupted（原始坏行保留在库中），
    /// 旧整包解不开记为 corruptLegacyBlob——调用方不会把它当成「正常短会话」
    static func loadMessagesDetailed(sessionId: String, legacyJSON: String, in db: Database) throws -> LoadedMessages {
        if legacyJSON.count > 2 {
            guard let data = legacyJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
                HubLogger.shared.error("Legacy session messages could not be decoded")
                return LoadedMessages(messages: [], health: .corruptLegacyBlob, corruptedSeqs: [])
            }
            return LoadedMessages(messages: decoded, health: .healthy, corruptedSeqs: [])
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT seq, payload FROM chat_messages WHERE sessionId = ? ORDER BY seq",
            arguments: [sessionId]
        )
        let decoder = JSONDecoder()
        var messages: [ChatMessage] = []
        var corrupted: [Int] = []
        for row in rows {
            let seq: Int = row["seq"]
            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8),
                  let message = try? decoder.decode(ChatMessage.self, from: data) else {
                HubLogger.shared.error("Session message row could not be decoded; original row retained")
                corrupted.append(seq)
                continue
            }
            messages.append(message)
        }
        let health: MessageLoadHealth = corrupted.isEmpty
            ? .healthy
            : .partiallyCorrupted(skipped: corrupted.count)
        return LoadedMessages(messages: messages, health: health, corruptedSeqs: corrupted)
    }

    /// 仅取正文的兼容包装（需要健康态时用 loadMessagesDetailed）
    static func loadMessages(sessionId: String, legacyJSON: String, in db: Database) throws -> [ChatMessage] {
        try loadMessagesDetailed(sessionId: sessionId, legacyJSON: legacyJSON, in: db).messages
    }

    /// 消息字典列表（JSONSerialization 轻量解析，摘要标题/用量统计用）。
    /// 优先分表，未迁移的旧数据走 legacy JSON；limit 限定前 N 条
    static func messageDicts(sessionId: String, legacyJSON: String, limit: Int?, in db: Database) throws -> [[String: Any]] {
        if legacyJSON.count > 2 {
            guard let data = legacyJSON.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                HubLogger.shared.error("Legacy messages parse failed for session \(sessionId)")
                return []
            }
            return array
        }
        var sql = "SELECT payload FROM chat_messages WHERE sessionId = ? ORDER BY seq"
        if let limit {
            sql += " LIMIT \(limit)"
        }
        let payloads = try String.fetchAll(db, sql: sql, arguments: [sessionId])
        return payloads.compactMap { payload -> [String: Any]? in
            guard let data = payload.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                HubLogger.shared.error("Message payload parse failed for session \(sessionId), row skipped")
                return nil
            }
            return dict
        }
    }

    /// 从消息字典中提取首条用户消息前 30 字符（摘要标题用；避免完整 Codable 解码）
    private static func firstUserMessagePrefix(in dicts: [[String: Any]]) -> String {
        for item in dicts {
            if (item["role"] as? String) == "user",
               let content = item["content"] as? String, !content.isEmpty {
                let prefix = content.prefix(30)
                return prefix.count < content.count ? "\(prefix)..." : String(prefix)
            }
        }
        return ""
    }

    /// 重命名会话（只更新标题列，不动消息内容）
    public func rename(id: UUID, title: String) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET title = ? WHERE id = ?",
                arguments: [title, id.uuidString]
            )
        }
    }

    /// Background titles must not replace a rename or a restored conversation.
    public func renameIfUnchanged(id: UUID, title: String, expectedTitle: String, restorationToken: String?) async throws -> Bool {
        try await write { db in
            guard try Self.restorationToken(id, in: db) == restorationToken else { return false }
            try db.execute(sql: "UPDATE chat_sessions SET title=? WHERE id=? AND title=?",
                arguments: [title, id.uuidString, expectedTitle])
            return db.changesCount == 1
        }
    }

    /// 设置/取消隐藏会话（只更新 isHidden 列，不动其他数据）
    public func setHidden(id: UUID, hidden: Bool) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET isHidden = ? WHERE id = ?",
                arguments: [hidden, id.uuidString]
            )
        }
    }

    /// 设置/取消置顶会话（只更新 isPinned 列，不动其他数据）
    public func setPinned(id: UUID, isPinned: Bool) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET isPinned = ? WHERE id = ?",
                arguments: [isPinned, id.uuidString]
            )
        }
    }

    /// 批量设置归档状态（同一写事务内只改 isArchived 列）。
    /// 只更新元数据列：摘要会话未加载消息，绝不能走整包 save（会用空消息覆盖分表）
    public func setArchived(ids: [UUID], archived: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE chat_sessions SET isArchived = ? WHERE id = ?",
                    arguments: [archived, id.uuidString]
                )
            }
        }
    }

    /// 单条归档/恢复（只更新 isArchived 列）
    public func setArchived(id: UUID, archived: Bool) async throws {
        try await setArchived(ids: [id], archived: archived)
    }

    /// 设置会话所属工作区（只更新 workspaceId 列，不动消息与其它字段）。
    /// 摘要会话未加载消息，不能走整包 save（会用空消息覆盖分表），故单列更新
    public func setWorkspaceId(id: UUID, workspaceId: String?) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET workspaceId = ? WHERE id = ?",
                arguments: [workspaceId, id.uuidString]
            )
        }
    }

    /// 批量迁移会话归属工作区（同一写事务内只改 workspaceId 列）。
    /// 移除工作区登记时调用：含已归档对话一并转入目标工作区
    public func setWorkspaceId(ids: [UUID], workspaceId: String?) async throws {
        guard !ids.isEmpty else { return }
        try await write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE chat_sessions SET workspaceId = ? WHERE id = ?",
                    arguments: [workspaceId, id.uuidString]
                )
            }
        }
    }

    /// A preset changes both knobs in one transaction without replacing messages
    /// from a partially loaded session. Existing sessions keep their stored pair.
    public func setPermissionConfiguration(
        id: UUID, configuration: PermissionConfiguration, restorationToken: String? = nil
    ) async throws {
        try await write { db in
            guard try Self.restorationToken(id, in: db) == restorationToken else {
                throw SessionServiceError.staleAfterRestore
            }
            try db.execute(
                sql: "UPDATE chat_sessions SET permissionMode = ?, autoReviewEnabled = ? WHERE id = ?",
                arguments: [configuration.mode.rawValue, configuration.autoReviewEnabled, id.uuidString]
            )
        }
    }

    /// 设置会话权限模式（只更新 permissionMode 列）。
    public func setPermissionMode(id: UUID, mode: PermissionMode) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET permissionMode = ? WHERE id = ?",
                arguments: [mode.rawValue, id.uuidString]
            )
        }
    }

    /// 设置会话模式（只更新 mode 列）。摘要会话未加载消息，不能走整包 save
    public func setMode(id: UUID, mode: ChatMode) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET mode = ? WHERE id = ?",
                arguments: [mode.rawValue, id.uuidString]
            )
        }
    }

    /// 设置会话自动审核开关（只更新 autoReviewEnabled 列）。
    /// 摘要会话未加载消息，不能走整包 save，故单列更新
    public func setAutoReviewEnabled(id: UUID, enabled: Bool) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET autoReviewEnabled = ? WHERE id = ?",
                arguments: [enabled, id.uuidString]
            )
        }
    }

    public func delete(id: UUID) async throws {
        let restoring = ResourceMaintenance.owned.contains(maintenanceKey)
        let clearedFirstResult = try await write { db in
            _ = try SessionRow.filter(Column("id") == id.uuidString).deleteAll(db)
            if try db.tableExists("coding_tasks") {
                try db.execute(sql: "DELETE FROM coding_tasks WHERE sessionID = ?", arguments: [id.uuidString])
            }
            // 级联清理消息分表行（否则删除会话留下孤儿消息）
            try db.execute(
                sql: "DELETE FROM chat_messages WHERE sessionId = ?",
                arguments: [id.uuidString]
            )
            if !restoring, try db.tableExists("product_task_runs") {
                try db.execute(sql: "DELETE FROM product_task_runs WHERE sessionID = ?", arguments: [id.uuidString])
            }
            if !restoring, try db.tableExists("artifact_versions") {
                try db.execute(sql: "DELETE FROM artifact_versions WHERE sessionID = ?", arguments: [id.uuidString])
            }
            if !restoring, try db.tableExists("product_preferences"),
               let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key='first-result.progress'"),
               let progress = try? JSONDecoder().decode(FirstResultProgress.self, from: data), progress.sessionID == id {
                try db.execute(sql: "DELETE FROM product_preferences WHERE key='first-result.progress'")
                return true
            }
            return false
        }
        if !restoring {
            await MainActor.run {
                NotificationCenter.default.post(name: ProductTaskRunStore.didChange, object: nil)
                if clearedFirstResult { NotificationCenter.default.post(name: ProductPreferencesService.didChange, object: nil) }
            }
        }
    }

    /// 分表行数（测试辅助：验证级联删除与迁移结果）
    public func testMessageRowCount(sessionId: String) throws -> Int {
        try databaseQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chat_messages WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
    }

    // MARK: - Usage receipts
    func makeUsageService() -> UsageService { UsageService(databaseQueue: databaseQueue) }
    public func getUsageStats() async throws -> UsageStats {
        try await UsageService(databaseQueue: databaseQueue).getStats()
    }

    /// Migration-only baseline. Historical variations have no individual date, so use the
    /// original message timestamp and label these aggregates separately from request receipts.
    static func backfillUsage(_ db: Database) throws {
        let hasMessageTable = try db.tableExists("chat_messages")
        // This migration runs before the newer session permission columns exist.
        struct LegacyUsageRow: Decodable, FetchableRecord {
            let id: String
            let messagesJSON: String
            let createdAt: Date
        }
        for row in try LegacyUsageRow.fetchAll(db, sql: "SELECT id, messagesJSON, createdAt FROM chat_sessions") {
            // Very old stores may have v1_chat marked complete without a message table.
            // Their nonempty legacy blob is still readable; an empty blob has no usage to import.
            guard hasMessageTable || row.messagesJSON.count > 2 else { continue }
            let messages = try messageDicts(sessionId: row.id, legacyJSON: row.messagesJSON, limit: nil, in: db)
            for (seq, item) in messages.enumerated() where item["role"] as? String == "assistant" {
                let date = (item["timestamp"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? row.createdAt
                let variants = (item["variations"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? [item]
                for (index, version) in variants.enumerated() {
                    let input = max(0, version["inputTokens"] as? Int ?? 0)
                    let output = max(0, version["outputTokens"] as? Int ?? 0)
                    guard input > 0 || output > 0 else { continue }
                    let messageID = item["id"] as? String ?? String(seq)
                    let id = "legacy:\(row.id):\(messageID):\(index)"
                    try db.execute(sql: "INSERT OR IGNORE INTO provider_usage (id, sessionId, source, startedAt, inputTokens, outputTokens, status) VALUES (?, ?, 'legacy', ?, ?, ?, 'succeeded')",
                        arguments: [id, row.id, date, input, output])
                }
            }
        }
    }

}

// MARK: - Usage Stats Model

/// 流量统计结果：总量 + 按天 + 按会话明细
public struct UsageStats: Sendable {
    /// 单会话用量明细
    public struct SessionUsage: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let turns: Int
        public let updatedAt: Date
        public var isDeleted: Bool = false
    }

    public var totalInputTokens = 0
    public var totalOutputTokens = 0
    public var totalCacheReadTokens = 0
    public var totalCacheWriteTokens = 0
    public var unknownCacheRequests = 0
    public var reportedInputRecords = 0
    public var reportedOutputRecords = 0
    public var reportedCacheReadRecords = 0
    public var reportedCacheWriteRecords = 0
    public var byModel: [UsageModelSummary] = []
    /// Receipt count (new provider requests plus legacy answer aggregates).
    public var totalTurns = 0
    public var totalRequests = 0
    public var legacyTurns = 0
    public var unreportedRequests = 0
    public var failedRequests = 0
    public var unfinishedRequests = 0
    /// 按天聚合（key = yyyy-MM-dd，本地时区）
    public var byDay: [String: (input: Int, output: Int, turns: Int)] = [:]
    /// 按会话聚合（updatedAt 降序）
    public var bySession: [SessionUsage] = []

    public init() {}

    public var totalTokens: Int { totalInputTokens + totalOutputTokens }

    /// 近 N 天序列（升序，无记录的天补零）
    public func recentDays(_ count: Int, endingAt: Date = Date(), calendar: Calendar = .current) -> [(day: String, input: Int, output: Int, turns: Int)] {
        let formatter = Self.dayKeyFormatter(calendar: calendar)
        return (0..<max(0, count)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endingAt) else { return nil }
            let key = formatter.string(from: date)
            let entry = byDay[key] ?? (input: 0, output: 0, turns: 0)
            return (day: key, input: entry.input, output: entry.output, turns: entry.turns)
        }
    }

    private static func dayKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

// MARK: - GRDB Row

private struct SessionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_sessions"

    var id: String
    var title: String
    /// 消息已分表存储：此列恒为 '[]'（仅迁移前存量数据可能非空）
    var messagesJSON: String
    /// 确认挂起快照 JSON（空串=无挂起）
    var pendingConfirmationJSON: String?
    /// 提问挂起快照 JSON（ask_user 表单）
    var pendingQuestionJSON: String?
    /// 隐藏会话标志（列表默认不显示）
    var isHidden: Bool
    /// 置顶会话标志
    var isPinned: Bool
    /// 归档会话标志（主列表不显示，仅「已归档对话」入口可见）
    var isArchived: Bool
    /// 所属对话工作区 id（NULL = 默认工作区）
    var workspaceId: String?
    /// 会话模式（chat / coding）
    var mode: String
    /// 自动审核开关（按会话；默认关闭）
    var autoReviewEnabled: Bool
    /// 权限模式（旧库默认完全权限）
    var allowsHostExecution: Bool
    var dataPolicy: String
    var permissionMode: String
    var createdAt: Date
    var updatedAt: Date

    init(from session: ChatSession) {
        self.id = session.id.uuidString
        self.title = session.title
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.isHidden = session.isHidden
        self.isPinned = session.isPinned
        self.isArchived = session.isArchived
        self.workspaceId = session.workspaceId
        self.mode = session.mode.rawValue
        self.autoReviewEnabled = session.autoReviewEnabled
        self.allowsHostExecution = session.allowsHostExecution
        self.dataPolicy = session.dataPolicy.rawValue
        self.permissionMode = session.permissionMode.rawValue
        self.messagesJSON = "[]"
        if let pending = session.pendingConfirmation {
            if let data = try? JSONEncoder().encode(pending),
               let json = String(data: data, encoding: .utf8) {
                self.pendingConfirmationJSON = json
            } else {
                // 编码失败不应清掉已有挂起快照：记日志并保底存储标记（下次保存重试）
                HubLogger.shared.error("Pending confirmation encode failed for session \(session.id)")
                self.pendingConfirmationJSON = nil
            }
        } else {
            self.pendingConfirmationJSON = nil
        }
        if let pending = session.pendingQuestion {
            if let data = try? JSONEncoder().encode(pending),
               let json = String(data: data, encoding: .utf8) {
                self.pendingQuestionJSON = json
            } else {
                HubLogger.shared.error("Pending question encode failed for session \(session.id)")
                self.pendingQuestionJSON = nil
            }
        } else {
            self.pendingQuestionJSON = nil
        }
    }

    func toSession() -> ChatSession? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var session = ChatSession(id: uuid, title: title, createdAt: createdAt)
        session.updatedAt = updatedAt
        session.isHidden = isHidden
        session.isPinned = isPinned
        session.isArchived = isArchived
        session.workspaceId = workspaceId
        session.mode = ChatMode(rawValue: mode) ?? .chat
        session.autoReviewEnabled = autoReviewEnabled
        session.allowsHostExecution = allowsHostExecution
        session.dataPolicy = TaskDataPolicy(rawValue: dataPolicy) ?? .localOnly
        session.permissionMode = PermissionMode(rawValue: permissionMode) ?? .dangerFullAccess
        // 消息经 SessionService.loadMessages 从分表加载（此处不碰 messagesJSON）
        if let json = pendingConfirmationJSON, !json.isEmpty,
           let data = json.data(using: .utf8) {
            do {
                session.pendingConfirmation = try JSONDecoder().decode(PendingConfirmationSnapshot.self, from: data)
            } catch {
                HubLogger.shared.error("Pending confirmation decode failed for session \(id): \(HubLogger.safeErrorSummary(error))")
            }
        }
        if let json = pendingQuestionJSON, !json.isEmpty,
           let data = json.data(using: .utf8) {
            do {
                session.pendingQuestion = try JSONDecoder().decode(PendingQuestionSnapshot.self, from: data)
            } catch {
                HubLogger.shared.error("Pending question decode failed for session \(id): \(HubLogger.safeErrorSummary(error))")
            }
        }
        return session
    }
}
