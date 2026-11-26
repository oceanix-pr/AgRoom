import Foundation
import GRDB

public struct CodingTaskRequest: Codable, Sendable, Equatable {
    public let runID: UUID
    public let text: String
    public let truncated: Bool
}

public struct CodingFileChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let originalData: Data?
    public var currentDigest: String?
    public var applied: Bool
    public var runID: UUID
    public var hasExternalChanges = false
    public var rootIdentity: TaskDirectoryIdentity? = nil
}

public struct CodingDiagnostic: Codable, Sendable, Equatable {
    public struct Location: Codable, Sendable, Equatable {
        public let path: String?
        public let line: Int?
        public let column: Int?
    }
    public let path: String?
    public let line: Int?
    public let column: Int?
    public let severity: String
    public let message: String
    public var occurrences: Int? = nil
    public var relatedLocations: [Location]? = nil
}

public struct CodingVerification: Codable, Sendable, Equatable {
    public let runID: UUID
    public let action: String
    public let directory: String
    public let exitCode: Int32
    public let succeeded: Bool
    public let inputRevision: String?
    public let outputRevision: String?
    public let logPath: String
    public let diagnostics: [CodingDiagnostic]
    /// Includes target, configuration and test filter. Missing on legacy receipts.
    public var checkID: String? = nil
    public var revisionVerified: Bool { succeeded && inputRevision != nil && inputRevision == outputRevision }
    public var identity: String { checkID ?? action + ":" + directory }
}

public struct CodingCheckRequirement: Codable, Sendable, Equatable {
    public let id: String
    public let action: String
    /// Canonical model-facing parameters, not an execution grant.
    public let argumentsJSON: String
}

/// 编码工作记账，归属「空间库 + 会话 + 目录身份」；模型不能借它授予权限或声明验证成功。
public struct CodingTaskState: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let workspace: TaskDirectoryIdentity
    public var currentRunID: UUID
    public var initialRevision: String?
    public var requests: [CodingTaskRequest] = []
    public var plan: [String] = []
    public var acceptance: [String] = []
    public var notes: [String] = []
    public var nextActions: [String] = []
    public var changes: [CodingFileChange] = []
    public var verification: CodingVerification?
    /// Optional for compatibility with already persisted task payloads.
    public var verifications: [CodingVerification]? = nil
    public var requiredChecks: [CodingCheckRequirement]? = nil
    /// Historical failures do not override the latest real acceptance receipt.
    public var failedAttempts: [CodingVerification]? = nil
    public var updatedAt = Date()

    public var latestChecks: [CodingVerification] {
        var checks: [CodingVerification] = []
        for receipt in verifications ?? verification.map({ [$0] }) ?? [] {
            checks.removeAll { $0.identity == receipt.identity }
            checks.append(receipt)
        }
        return checks
    }
}

enum CodingTaskOwner: Equatable, Sendable {
    case absent
    case run(UUID)
}

public final class CodingTaskStore: Sendable {
    let databaseQueue: DatabaseQueue
    public init(databaseQueue: DatabaseQueue) { self.databaseQueue = databaseQueue }

    public static func createSchema(_ db: Database) throws {
        try db.create(table: "coding_tasks", ifNotExists: true) { t in
            t.column("sessionID", .text).notNull()
            t.column("workspaceKey", .text).notNull()
            t.column("payload", .blob).notNull()
            t.primaryKey(["sessionID", "workspaceKey"])
        }
    }

    private static func key(_ workspace: TaskDirectoryIdentity) throws -> String {
        ManagedTextSnapshot.digest(Data(try CodingJSON.encode(workspace).utf8))
    }

    static func noteRestore(in db: Database, sessionID: UUID, workspace: TaskDirectoryIdentity, path: String,
                            expectedDigest: String?, restoredDigest: String?) throws {
        let key = try key(workspace)
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM coding_tasks WHERE sessionID=? AND workspaceKey=?",
            arguments: [sessionID.uuidString, key]) else { return }
        var state = try JSONDecoder().decode(CodingTaskState.self, from: data)
        guard state.sessionID == sessionID, state.workspace == workspace,
              let index = state.changes.firstIndex(where: { $0.path == path && $0.currentDigest == expectedDigest }) else { return }
        state.changes[index].currentDigest = restoredDigest
        state.changes[index].applied = restoredDigest != state.changes[index].originalData.map(ManagedTextSnapshot.digest)
        state.updatedAt = Date()
        try db.execute(sql: "UPDATE coding_tasks SET payload=? WHERE sessionID=? AND workspaceKey=?",
            arguments: [try JSONEncoder().encode(state), sessionID.uuidString, key])
    }

    public func load(sessionID: UUID, workspace: TaskDirectoryIdentity) async throws -> CodingTaskState? {
        let key = try Self.key(workspace)
        return try await databaseQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM coding_tasks WHERE sessionID = ? AND workspaceKey = ?",
                arguments: [sessionID.uuidString, key]) else { return nil }
            let state = try JSONDecoder().decode(CodingTaskState.self, from: data)
            guard state.sessionID == sessionID, state.workspace == workspace else { throw FileAreaService.AreaError.unsafePath }
            return state
        }
    }

    /// 在数据库事务内读取最新值再更新；迟到的旧运行不能覆盖新运行。
    @discardableResult
    func update(sessionID: UUID, workspace: TaskDirectoryIdentity, runID: UUID, begin: Bool = false,
        expectedBeginOwner: CodingTaskOwner? = nil,
        body: @escaping @Sendable (inout CodingTaskState) throws -> Void) async throws -> CodingTaskState {
        let key = try Self.key(workspace)
        return try await databaseQueue.maintenanceWrite { db in
            let data = try Data.fetchOne(db, sql: "SELECT payload FROM coding_tasks WHERE sessionID = ? AND workspaceKey = ?",
                arguments: [sessionID.uuidString, key])
            guard begin || data != nil else {
                throw ToolExecutionFailure(message: "The coding task was removed. A late operation cannot recreate it.")
            }
            var state = try data.map { try JSONDecoder().decode(CodingTaskState.self, from: $0) }
                ?? CodingTaskState(sessionID: sessionID, workspace: workspace, currentRunID: runID)
            if let expectedBeginOwner {
                let owner: CodingTaskOwner = data == nil ? .absent : .run(state.currentRunID)
                guard begin, owner == expectedBeginOwner || owner == .run(runID) else {
                    throw ToolExecutionFailure(message: "The coding task changed before activation. A late run cannot claim it.")
                }
            }
            guard state.workspace == workspace, state.sessionID == sessionID,
                  begin || state.currentRunID == runID else {
                throw ToolExecutionFailure(message: "This coding task belongs to a different run or workspace. Nothing was updated.")
            }
            try body(&state)
            if begin { state.currentRunID = runID }
            state.updatedAt = Date()
            try db.execute(sql: "INSERT INTO coding_tasks (sessionID, workspaceKey, payload) VALUES (?, ?, ?) ON CONFLICT(sessionID, workspaceKey) DO UPDATE SET payload = excluded.payload",
                arguments: [sessionID.uuidString, key, try JSONEncoder().encode(state)])
            return state
        }
    }
}
