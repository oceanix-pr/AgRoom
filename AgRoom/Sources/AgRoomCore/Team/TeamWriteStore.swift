import Foundation
import GRDB

// MARK: - Write Record

/// 一次成功的团队文件写快照，用于任务板审阅与回滚。
/// 旧内容为 nil 表示该文件是团队新建的；回滚时会删除它。
public enum TeamWriteState: String, Codable, Sendable, Equatable {
    /// 快照已落库，但文件尚未确认写入（崩溃后可能是这个状态，需要恢复核对）
    case prepared
    case applied
    case failed
    case reverted
    case needsRecovery
}

public struct TeamWriteRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let space: String
    public let rootPath: String
    public let rootIdentity: TaskDirectoryIdentity?
    public let path: String
    public let oldContent: String?
    public let newContent: String
    public let createdAt: Date
    public let revertedAt: Date?
    public let state: TeamWriteState
    public let policyVersion: Int?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        space: String,
        rootPath: String,
        path: String,
        oldContent: String?,
        newContent: String,
        createdAt: Date = Date(),
        revertedAt: Date? = nil,
        state: TeamWriteState = .prepared,
        policyVersion: Int? = nil,
        rootIdentity: TaskDirectoryIdentity? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.space = space
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.path = path
        self.oldContent = oldContent
        self.newContent = newContent
        self.createdAt = createdAt
        self.revertedAt = revertedAt
        self.state = state
        self.policyVersion = policyVersion
    }

    public var isReverted: Bool { revertedAt != nil }
}

/// 团队写审批的持久化审计：只记稳定标识、路径摘要和决定，不写文件正文。
public struct TeamApprovalAuditRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let space: String
    public let path: String
    public let decision: String
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        space: String,
        path: String,
        decision: String,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.space = space
        self.path = path
        self.decision = decision
        self.reason = reason
        self.createdAt = createdAt
    }
}

// MARK: - Write Store

/// 团队写快照存储：绑定单一空间库，供回滚和变更审阅使用。
/// 大内容直接存 SQLite 文本；P2b 只做单文件回滚，不做自动备份链。
public final class TeamWriteStore: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    static func createSchema(_ database: Database) throws {
        try database.create(table: "team_writes", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("taskID", .text).notNull()
            t.column("space", .text).notNull()
            t.column("rootPath", .text).notNull()
            t.column("path", .text).notNull()
            t.column("oldContent", .text)
            t.column("newContent", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("revertedAt", .datetime)
            t.column("state", .text).notNull().defaults(to: TeamWriteState.prepared.rawValue)
            t.column("policyVersion", .integer)
        }
        try database.create(table: "team_approval_audit", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("taskID", .text).notNull()
            t.column("space", .text).notNull()
            t.column("path", .text).notNull()
            t.column("decision", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try database.create(
            index: "team_writes_taskID",
            on: "team_writes",
            columns: ["taskID", "createdAt"],
            ifNotExists: true
        )
    }

    @discardableResult
    public func record(
        taskID: UUID,
        space: String,
        rootPath: String,
        path: String,
        oldContent: String?,
        newContent: String,
        policyVersion: Int? = nil,
        rootIdentity: TaskDirectoryIdentity? = nil
    ) async throws -> TeamWriteRecord {
        let record = TeamWriteRecord(
            taskID: taskID,
            space: space,
            rootPath: rootPath,
            path: path,
            oldContent: oldContent,
            newContent: newContent,
            state: .prepared,
            policyVersion: policyVersion, rootIdentity: rootIdentity
        )
        try await databaseQueue.maintenanceWrite { db in
            var row = TeamWriteRow(record: record)
            try row.insert(db)
        }
        return record
    }

    public func recordApproval(
        taskID: UUID,
        space: String,
        path: String,
        decision: String,
        reason: String
    ) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO team_approval_audit
                        (id, taskID, space, path, decision, reason, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, taskID.uuidString, space, path,
                    decision, reason, Date(),
                ]
            )
        }
    }

    public func approvalAudit(taskID: UUID) async throws -> [TeamApprovalAuditRecord] {
        let rows = try await databaseQueue.read { db in
            try TeamApprovalAuditRow.fetchAll(
                db,
                sql: """
                    SELECT id, taskID, space, path, decision, reason, createdAt
                    FROM team_approval_audit
                    WHERE taskID = ?
                    ORDER BY createdAt ASC
                    """,
                arguments: [taskID.uuidString]
            )
        }
        return rows.compactMap(\.record)
    }

    public func records(taskID: UUID) async throws -> [TeamWriteRecord] {
        let rows = try await databaseQueue.read { db in
            try TeamWriteRow
                .filter(Column("taskID") == taskID.uuidString)
                .order(Column.rowID.asc)
                .fetchAll(db)
        }
        return rows.compactMap(\.record)
    }

    public func markApplied(id: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamWriteRow.filter(Column("id") == id.uuidString)
                .updateAll(db, Column("state").set(to: TeamWriteState.applied.rawValue))
        }
    }

    public func markFailed(id: UUID, needsRecovery: Bool = false) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamWriteRow.filter(Column("id") == id.uuidString)
                .updateAll(db, Column("state").set(to: (needsRecovery
                    ? TeamWriteState.needsRecovery : TeamWriteState.failed).rawValue))
        }
    }

    public func markReverted(id: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamWriteRow
                .filter(Column("id") == id.uuidString)
                .updateAll(
                    db,
                    Column("revertedAt").set(to: Date()),
                    Column("state").set(to: TeamWriteState.reverted.rawValue)
                )
        }
    }

    /// 旧库补 state / policyVersion 列（幂等）。
    static func addStateColumns(_ database: Database) throws {
        let columns = try database.columns(in: "team_writes").map(\.name)
        if !columns.contains("state") {
            try database.alter(table: "team_writes") { t in
                t.add(column: "state", .text).notNull()
                    .defaults(to: TeamWriteState.prepared.rawValue)
            }
        }
        if !columns.contains("policyVersion") {
            try database.alter(table: "team_writes") { t in
                t.add(column: "policyVersion", .integer)
            }
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamWriteRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    public func delete(taskID: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamWriteRow.filter(Column("taskID") == taskID.uuidString).deleteAll(db)
        }
    }
}

// MARK: - Rows

private struct TeamApprovalAuditRow: Codable, FetchableRecord {
    static let databaseTableName = "team_approval_audit"

    var id: String
    var taskID: String
    var space: String
    var path: String
    var decision: String
    var reason: String
    var createdAt: Date

    var record: TeamApprovalAuditRecord? {
        guard let id = UUID(uuidString: id),
              let taskID = UUID(uuidString: taskID) else { return nil }
        return TeamApprovalAuditRecord(
            id: id,
            taskID: taskID,
            space: space,
            path: path,
            decision: decision,
            reason: reason,
            createdAt: createdAt
        )
    }
}

private struct TeamWriteRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "team_writes"

    var id: String
    var taskID: String
    var space: String
    var rootPath: String
    var rootDevice: Int64?
    var rootInode: Int64?
    var path: String
    var oldContent: String?
    var newContent: String
    var createdAt: Date
    var revertedAt: Date?
    var state: String
    var policyVersion: Int?

    init(record: TeamWriteRecord) {
        self.id = record.id.uuidString
        self.taskID = record.taskID.uuidString
        self.space = record.space
        self.rootPath = record.rootPath
        self.rootDevice = record.rootIdentity.map { Int64(bitPattern: $0.device) }
        self.rootInode = record.rootIdentity.map { Int64(bitPattern: $0.inode) }
        self.path = record.path
        self.oldContent = record.oldContent
        self.newContent = record.newContent
        self.createdAt = record.createdAt
        self.revertedAt = record.revertedAt
        self.state = record.state.rawValue
        self.policyVersion = record.policyVersion
    }

    var record: TeamWriteRecord? {
        guard let id = UUID(uuidString: id),
              let taskID = UUID(uuidString: taskID) else { return nil }
        return TeamWriteRecord(
            id: id,
            taskID: taskID,
            space: space,
            rootPath: rootPath,
            path: path,
            oldContent: oldContent,
            newContent: newContent,
            createdAt: createdAt,
            revertedAt: revertedAt,
            state: TeamWriteState(rawValue: state) ?? .needsRecovery,
            policyVersion: policyVersion,
            rootIdentity: rootDevice.flatMap { device in rootInode.map {
                TaskDirectoryIdentity(canonicalPath: rootPath, device: UInt64(bitPattern: device), inode: UInt64(bitPattern: $0))
            } }
        )
    }
}
