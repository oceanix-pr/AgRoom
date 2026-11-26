import Foundation
import GRDB

/// One space queue, including all transitions, attempts and usage records.
public final class GoalStore: Sendable {
    public static let didChange = Notification.Name("agroom.goals.changed")
    private let queue: DatabaseQueue
    public let space: AppSpace
    static let maximumRecordBytes = 128 * 1024
    public init(databaseQueue: DatabaseQueue, space: AppSpace) { queue = databaseQueue; self.space = space }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "execution_goals", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("sessionID", .text).notNull().references("chat_sessions", onDelete: .cascade)
            t.column("workspaceID", .text).notNull()
            t.column("status", .text).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("payload", .blob).notNull()
        }
        try db.create(index: "execution_goals_session", on: "execution_goals", columns: ["sessionID", "updatedAt"], ifNotExists: true)
        try db.create(table: "goal_attempts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("goalID", .text).notNull().references("execution_goals", onDelete: .cascade)
            t.column("sequence", .integer).notNull()
            t.column("payload", .blob).notNull()
            t.uniqueKey(["goalID", "sequence"])
        }
        try db.create(table: "goal_events", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("goalID", .text).notNull().references("execution_goals", onDelete: .cascade)
            t.column("createdAt", .datetime).notNull()
            t.column("kind", .text).notNull()
        }
    }

    static func decode(_ data: Data, space: AppSpace) throws -> ExecutionGoal {
        guard data.count <= maximumRecordBytes else { throw GoalError.invalid }
        let value = try JSONDecoder().decode(ExecutionGoal.self, from: data)
        guard value.space == space, value.isValid else { throw GoalError.invalid }
        return value
    }
    private static func read(_ db: Database, id: UUID, space: AppSpace) throws -> ExecutionGoal {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM execution_goals WHERE id=?", arguments: [id.uuidString]) else { throw GoalError.unavailable }
        return try decodeRow(row, space: space)
    }
    private static func decodeRow(_ row: Row, space: AppSpace) throws -> ExecutionGoal {
        let value = try decode(row["payload"], space: space)
        guard value.id.uuidString == row["id"], value.sessionID.uuidString == row["sessionID"],
              value.workspaceID.uuidString == row["workspaceID"], value.status.rawValue == row["status"] else { throw GoalError.invalid }
        return value
    }
    static func write(_ value: ExecutionGoal, in db: Database, event: String) throws {
        guard value.isValid else { throw GoalError.invalid }
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumRecordBytes else { throw GoalError.invalid }
        try db.execute(sql: "UPDATE execution_goals SET workspaceID=?,status=?,updatedAt=?,payload=? WHERE id=?",
            arguments: [value.workspaceID.uuidString, value.status.rawValue, value.updatedAt, data, value.id.uuidString])
        try db.execute(sql: "INSERT INTO goal_events(id,goalID,createdAt,kind) VALUES(?,?,?,?)",
            arguments: [UUID().uuidString, value.id.uuidString, value.updatedAt, event])
    }
    public func goal(id: UUID) async throws -> ExecutionGoal { let space = space; return try await queue.read { try Self.read($0, id: id, space: space) } }
    public func latest(sessionID: UUID) async throws -> ExecutionGoal? {
        let space = space
        return try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM execution_goals WHERE sessionID=? ORDER BY updatedAt DESC,id DESC LIMIT 1", arguments: [sessionID.uuidString]) else { return nil }
            return try Self.decodeRow(row, space: space)
        }
    }
    public func list(limit: Int = 50, before: ExecutionGoal? = nil, includeHidden: Bool = false) async throws -> [ExecutionGoal] {
        let space = space
        return try await queue.read { db in
            let visibility = includeHidden ? "1" : "COALESCE(s.isHidden,0)=0"
            let cursor = before == nil ? "" : " AND (g.updatedAt < ? OR (g.updatedAt=? AND g.id < ?))"
            var args: [DatabaseValue] = []
            if let before { args += [before.updatedAt.databaseValue, before.updatedAt.databaseValue, before.id.uuidString.databaseValue] }
            args += [min(100, max(1, limit)).databaseValue]
            return try Row.fetchAll(db, sql: "SELECT g.* FROM execution_goals g JOIN chat_sessions s ON s.id=g.sessionID WHERE \(visibility)\(cursor) ORDER BY g.updatedAt DESC,g.id DESC LIMIT ?", arguments: StatementArguments(args))
                .map { try Self.decodeRow($0, space: space) }
        }
    }
    private static func decodeAttempt(_ row: Row, goalID: UUID) throws -> GoalAttempt {
        let data: Data = row["payload"]
        guard data.count <= maximumRecordBytes else { throw GoalError.invalid }
        let value = try JSONDecoder().decode(GoalAttempt.self, from: data)
        guard value.isValid, value.id.uuidString == row["id"], value.goalID == goalID,
              value.sequence == row["sequence"] else { throw GoalError.invalid }
        return value
    }
    public func attempt(goalID: UUID, runID: UUID) async throws -> GoalAttempt? {
        try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM goal_attempts WHERE id=? AND goalID=?",
                arguments: [runID.uuidString, goalID.uuidString]) else { return nil }
            return try Self.decodeAttempt(row, goalID: goalID)
        }
    }
    public func attempts(goalID: UUID, limit: Int = 50, beforeSequence: Int? = nil) async throws -> [GoalAttempt] {
        try await queue.read { db in
            Array(try Row.fetchAll(db, sql: "SELECT * FROM goal_attempts WHERE goalID=? AND sequence < ? ORDER BY sequence DESC LIMIT ?",
                arguments: [goalID.uuidString, beforeSequence ?? Int.max, min(100, max(1, limit))])
                .map { try Self.decodeAttempt($0, goalID: goalID) }.reversed())
        }
    }
    @discardableResult public func create(_ goal: ExecutionGoal) async throws -> ExecutionGoal {
        guard goal.space == space, goal.isValid, goal.scope != nil, goal.status == .ready,
              goal.activeRunID == nil, goal.attemptCount == 0, goal.spentTokens == 0,
              goal.definition.criteria.allSatisfy({ $0.verdict == .unknown && $0.evidenceRunID == nil }) else { throw GoalError.invalid }
        try await queue.maintenanceWrite { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM execution_goals WHERE sessionID=? AND (status NOT IN ('succeeded','cancelled') OR json_extract(CAST(payload AS TEXT),'$.activeRunID') IS NOT NULL))", arguments: [goal.sessionID.uuidString]) ?? false
            guard !exists else { throw GoalError.busy }
            if let draftID = goal.draftID {
                for data in try Data.fetchAll(db, sql: "SELECT payload FROM execution_goals WHERE sessionID=?", arguments: [goal.sessionID.uuidString]) {
                    if try Self.decode(data, space: goal.space).draftID == draftID { throw GoalError.changed }
                }
            }
            try db.execute(sql: "INSERT INTO execution_goals(id,sessionID,workspaceID,status,updatedAt,payload) VALUES(?,?,?,?,?,?)",
                arguments: [goal.id.uuidString, goal.sessionID.uuidString, goal.workspaceID.uuidString, goal.status.rawValue, goal.updatedAt, try JSONEncoder().encode(goal)])
            try Self.write(goal, in: db, event: "created")
        }
        await changed(); return goal
    }
    /// A transition uses the expected revision; active receipt commits additionally
    /// require the original run ID. A stale callback cannot resurrect another run.
    @discardableResult
    func update(id: UUID, expectedRevision: UUID, event: String,
                       _ change: @escaping @Sendable (inout ExecutionGoal, Database) throws -> Void) async throws -> ExecutionGoal {
        let space = space
        let result = try await queue.maintenanceWrite { db in
            var value = try Self.read(db, id: id, space: space)
            guard value.revision == expectedRevision else { throw GoalError.changed }
            try change(&value, db)
            value.revision = UUID(); value.updatedAt = Date()
            try Self.write(value, in: db, event: event)
            return value
        }
        await changed(); return result
    }
    private func changed() async {
        let space = space
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) }
    }

    /// Portable content contains neither directory identity nor approval authority.
    /// Unknown usage is marked incomplete after import; a fresh scope is required.
    static func portable(_ original: ExecutionGoal, space: AppSpace, workspaceMappings: [String: String], importing: Bool) -> ExecutionGoal {
        var value = original
        value.scope = nil
        if importing {
            value.space = space
            value.workspaceID = workspaceMappings[value.workspaceID.uuidString].flatMap(UUID.init(uuidString:)) ?? value.workspaceID
            if value.activeRunID != nil || value.reservedTokens > 0 || value.reservedToolCalls > 0 { value.usageIsIncomplete = true }
            value.spentTokens = GoalUsage.adding(value.spentTokens, value.reservedTokens)
            value.toolCalls = GoalUsage.adding(value.toolCalls, value.reservedToolCalls)
            value.reservedTokens = 0; value.reservedToolCalls = 0; value.activeRunID = nil
            value.deadline = nil; value.revision = UUID()
            if !value.status.isTerminal { value.status = .paused; value.stopReason = .interrupted }
        }
        return value
    }

    static func pauseForRestore(_ db: Database, space: AppSpace) throws {
        guard try db.tableExists("execution_goals") else { return }
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM execution_goals") {
            let current = try decode(data, space: space)
            let paused = portable(current, space: space, workspaceMappings: [:], importing: true)
            try write(paused, in: db, event: "restored")
        }
    }
}
