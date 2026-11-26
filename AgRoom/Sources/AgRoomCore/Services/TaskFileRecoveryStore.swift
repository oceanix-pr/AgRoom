import Foundation
import GRDB
import CryptoKit

// MARK: - Task File Recovery

public enum TaskFileRecoveryState: String, Codable, Sendable, Equatable {
    case prepared
    case applied
    case failed
    case reverted
    case needsRecovery
}

/// 一次任务文件修改的恢复点。正文只存在当前空间数据库，不进入 Hub 缓存或普通日志。
public struct TaskFileRecoveryRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let space: String
    public let rootPath: String
    public let rootIdentity: TaskDirectoryIdentity?
    public let path: String
    public let oldData: Data?
    public let newDigest: String
    public let state: TaskFileRecoveryState
    public let policyVersion: String?
    public let createdAt: Date
    public let revertedAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        space: String,
        rootPath: String,
        rootIdentity: TaskDirectoryIdentity? = nil,
        path: String,
        oldData: Data?,
        newDigest: String,
        state: TaskFileRecoveryState = .prepared,
        policyVersion: String? = nil,
        createdAt: Date = Date(),
        revertedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.space = space
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.path = path
        self.oldData = oldData
        self.newDigest = newDigest
        self.state = state
        self.policyVersion = policyVersion
        self.createdAt = createdAt
        self.revertedAt = revertedAt
    }
}

/// 空间库中的任务恢复点。所有读写绑定当前空间数据库连接，不缓存到 Hub。
public final class TaskFileRecoveryStore: @unchecked Sendable {
    public let space: AppSpace
    private let databaseQueue: DatabaseQueue

    public init(space: AppSpace, databaseQueue: DatabaseQueue) {
        self.space = space
        self.databaseQueue = databaseQueue
    }

    public static func createSchema(_ db: Database) throws {
        try db.create(table: "task_file_recoveries", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("taskID", .text).notNull()
            t.column("space", .text).notNull()
            t.column("rootPath", .text).notNull()
            t.column("rootIdentity", .blob)
            t.column("path", .text).notNull()
            t.column("oldData", .blob)
            t.column("newDigest", .text).notNull()
            t.column("state", .text).notNull()
            t.column("policyVersion", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("revertedAt", .datetime)
        }
        try db.create(
            index: "task_file_recoveries_taskID",
            on: "task_file_recoveries",
            columns: ["taskID", "createdAt"],
            ifNotExists: true
        )
        try db.create(
            index: "task_file_recoveries_state",
            on: "task_file_recoveries",
            columns: ["space", "state"],
            ifNotExists: true
        )
    }

    @discardableResult
    public func record(
        taskID: UUID,
        space: String,
        rootPath: String,
        rootIdentity: TaskDirectoryIdentity? = nil,
        path: String,
        oldData: Data?,
        newDigest: String,
        policyVersion: String?
    ) async throws -> TaskFileRecoveryRecord {
        guard space == self.space.rawValue else {
            throw ToolExecutionFailure(message: "Refusing to save a recovery point for another space.")
        }
        guard (oldData?.count ?? 0) <= WorkspaceTextLimits.maximumEditBytes else {
            throw ToolExecutionFailure(message: "The previous file exceeds the managed edit recovery limit. Nothing was edited.")
        }
        let root = URL(fileURLWithPath: rootPath)
        let identity = try rootIdentity ?? TaskDirectoryIdentity.capture(root)
        guard identity.matches(root) else { throw TaskFileRecoveryError.outsideRoot }
        let encodedIdentity = try JSONEncoder().encode(identity)
        let record = TaskFileRecoveryRecord(
            taskID: taskID,
            space: space,
            rootPath: identity.canonicalPath,
            rootIdentity: identity,
            path: path,
            oldData: oldData,
            newDigest: newDigest,
            state: .prepared,
            policyVersion: policyVersion
        )
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO task_file_recoveries
                        (id, taskID, space, rootPath, rootIdentity, path, oldData, newDigest, state, policyVersion, createdAt, revertedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString, record.taskID.uuidString, record.space,
                    record.rootPath, encodedIdentity, record.path, record.oldData, record.newDigest,
                    record.state.rawValue, record.policyVersion, record.createdAt, record.revertedAt,
                ]
            )
        }
        return record
    }

    public func markApplied(id: UUID) async throws {
        try await updateState(id: id, state: .applied)
    }

    public func markFailed(id: UUID, needsRecovery: Bool) async throws {
        try await updateState(id: id, state: needsRecovery ? .needsRecovery : .failed)
    }

    public func markReverted(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: "UPDATE task_file_recoveries SET state = ?, revertedAt = ? WHERE id = ?",
                arguments: [TaskFileRecoveryState.reverted.rawValue, Date(), id.uuidString]
            )
        }
    }

    public func record(id: UUID) async throws -> TaskFileRecoveryRecord? {
        try await databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM task_file_recoveries WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return Self.decode(row)
        }
    }

    public func recoveries(taskID: UUID) async throws -> [TaskFileRecoveryRecord] {
        try await databaseQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_file_recoveries WHERE taskID = ? AND space = ? ORDER BY createdAt ASC",
                arguments: [taskID.uuidString, space.rawValue]
            ).compactMap(Self.decode)
        }
    }

    public func recoverable() async throws -> [TaskFileRecoveryRecord] {
        try await databaseQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_file_recoveries WHERE space = ? AND state IN (?, ?, ?) ORDER BY createdAt DESC",
                arguments: [
                    space.rawValue,
                    TaskFileRecoveryState.applied.rawValue,
                    TaskFileRecoveryState.needsRecovery.rawValue,
                    TaskFileRecoveryState.prepared.rawValue,
                ]
            ).compactMap(Self.decode)
        }
    }

    private func updateState(id: UUID, state: TaskFileRecoveryState) async throws {
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: "UPDATE task_file_recoveries SET state = ? WHERE id = ?",
                arguments: [state.rawValue, id.uuidString]
            )
        }
    }

    private static func decode(_ row: Row) -> TaskFileRecoveryRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let taskID = UUID(uuidString: row["taskID"]),
              let space = row["space"] as String?,
              let rootPath = row["rootPath"] as String?,
              let path = row["path"] as String?,
              let newDigest = row["newDigest"] as String?,
              let state = TaskFileRecoveryState(rawValue: row["state"]),
              let createdAt: Date = row["createdAt"] else { return nil }
        let identity: TaskDirectoryIdentity?
        if let data: Data = row["rootIdentity"] {
            guard let decoded = try? JSONDecoder().decode(TaskDirectoryIdentity.self, from: data),
                  decoded.canonicalPath == rootPath else { return nil }
            identity = decoded
        } else { identity = nil }
        return TaskFileRecoveryRecord(
            id: id,
            taskID: taskID,
            space: space,
            rootPath: rootPath,
            rootIdentity: identity,
            path: path,
            oldData: row["oldData"] as Data?,
            newDigest: newDigest,
            state: state,
            policyVersion: row["policyVersion"] as String?,
            createdAt: createdAt,
            revertedAt: row["revertedAt"] as Date?
        )
    }
}

// MARK: - Restore

public enum TaskFileRecoveryError: LocalizedError, Equatable {
    case wrongSpace
    case notRestorable
    case outsideRoot
    case missingFile
    case symlink
    case changedSinceWrite
    case noPreviousVersion
    case oversizedFile

    public var errorDescription: String? {
        switch self {
        case .wrongSpace: return "This recovery point belongs to another space."
        case .notRestorable: return "This recovery point is not in a restorable state."
        case .outsideRoot: return "The recorded file is outside its original workspace root."
        case .missingFile: return "The recorded file no longer exists; it cannot be restored safely."
        case .symlink: return "The recorded path is now a symbolic link; refusing to restore."
        case .changedSinceWrite: return "The file changed after the AI write; refusing to overwrite newer content."
        case .noPreviousVersion: return "This record has no previous content to restore (it was a new file)."
        case .oversizedFile: return "The file or its recovery point exceeds the managed edit recovery limit. Nothing was restored."
        }
    }
}

/// 单文件恢复：只恢复「当前内容仍等于 AI 写入版本」的文件。
/// 用户之后又改过的文件明确拒绝，绝不覆盖；恢复后仍保留用户原有内容。
public struct TaskFileRecoveryService: Sendable {
    public let store: TaskFileRecoveryStore
    public let service: FileAreaService
    public let leases: TeamLeaseCenter

    public init(
        store: TaskFileRecoveryStore,
        service: FileAreaService,
        leases: TeamLeaseCenter = .shared
    ) {
        self.store = store
        self.service = service
        self.leases = leases
    }

    public func restore(_ record: TaskFileRecoveryRecord) async throws -> TaskFileRecoveryRecord {
        guard record.space == store.space.rawValue else { throw TaskFileRecoveryError.wrongSpace }
        // A prepared record can survive a crash after the file was replaced but before
        // its receipt was committed. The content comparison below is the authority.
        guard record.state == .applied || record.state == .needsRecovery || record.state == .prepared else {
            throw TaskFileRecoveryError.notRestorable
        }
        guard let oldData = record.oldData else { throw TaskFileRecoveryError.noPreviousVersion }
        guard oldData.count <= WorkspaceTextLimits.maximumEditBytes else {
            throw TaskFileRecoveryError.oversizedFile
        }
        let root = URL(fileURLWithPath: record.rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let target = try service.treeSource(record.path, space: store.space, changesLocation: false)
        guard target.path == record.path, record.rootIdentity?.matches(root) != false, FileAreaService.isInside(target, root: root) else {
            throw TaskFileRecoveryError.outsideRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TaskFileRecoveryError.missingFile
        }
        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw TaskFileRecoveryError.symlink }

        let lease = try await leases.acquire(
            space: record.space,
            path: target.path,
            taskID: record.taskID,
            subtaskID: record.id
        )
        do {
            let current: Data
            do {
                current = try ScriptFileIdentity.read(target, root: root, limit: WorkspaceTextLimits.maximumEditBytes)
            } catch let error as CocoaError where error.code == .fileReadTooLarge {
                throw TaskFileRecoveryError.oversizedFile
            }
            guard Self.digest(current) == record.newDigest else {
                throw TaskFileRecoveryError.changedSinceWrite
            }
            try Task.checkCancellation()
            try SecureFileWriter.write(oldData, to: target, root: root, policy: .matching(current), expectedRoot: record.rootIdentity)
            try await store.markReverted(id: record.id)
            await leases.release(lease)
            return TaskFileRecoveryRecord(
                id: record.id,
                taskID: record.taskID,
                space: record.space,
                rootPath: record.rootPath,
                rootIdentity: record.rootIdentity,
                path: record.path,
                oldData: record.oldData,
                newDigest: record.newDigest,
                state: .reverted,
                policyVersion: record.policyVersion,
                createdAt: record.createdAt,
                revertedAt: Date()
            )
        } catch {
            await leases.release(lease)
            throw error
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
