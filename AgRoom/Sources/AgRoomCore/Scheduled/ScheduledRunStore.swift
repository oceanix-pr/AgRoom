import Foundation
import GRDB

// MARK: - Scheduled Run Store

/// 定时运行记录：绑定单一空间 `DatabaseQueue`。
/// `(taskID, scheduledFor)` 唯一索引防止重复 tick、时钟回拨或并发扫描产生重复运行。
public final class ScheduledRunStore: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    static func createSchema(_ database: Database) throws {
        try database.create(table: "scheduled_runs", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("taskID", .text).notNull()
            t.column("taskName", .text).notNull()
            t.column("trigger", .text).notNull()
            t.column("scheduledFor", .datetime)
            t.column("status", .text).notNull()
            t.column("startedAt", .datetime)
            t.column("finishedAt", .datetime)
            t.column("outputText", .text)
            t.column("summary", .text)
            t.column("toolNamesJSON", .text).notNull().defaults(to: "[]")
            t.column("toolCallCount", .integer).notNull().defaults(to: 0)
            t.column("inputTokens", .integer).notNull().defaults(to: 0)
            t.column("outputTokens", .integer).notNull().defaults(to: 0)
            t.column("errorCode", .text)
            t.column("errorText", .text)
            t.column("durationMs", .integer)
            t.column("experienceJSON", .text)
        }
        try database.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS scheduled_runs_occurrence
            ON scheduled_runs(taskID, scheduledFor)
            WHERE scheduledFor IS NOT NULL
            """)
        try database.create(
            index: "scheduled_runs_task_started",
            on: "scheduled_runs",
            columns: ["taskID", "startedAt"],
            ifNotExists: true
        )
        try database.create(
            index: "scheduled_runs_status",
            on: "scheduled_runs",
            columns: ["status"],
            ifNotExists: true
        )
    }

    /// 插入一条运行记录；同一计划时刻已存在时返回 false（不覆盖旧记录）。
    @discardableResult
    public func insert(_ run: ScheduledRun) async throws -> Bool {
        let row = try ScheduledRunRow(run: run)
        let inserted = try await databaseQueue.maintenanceWrite { db -> Bool in
            if let scheduledFor = run.scheduledFor {
                let exists = try ScheduledRunRow
                    .filter(Column("taskID") == run.taskID.uuidString)
                    .filter(Column("scheduledFor") == scheduledFor)
                    .fetchCount(db) > 0
                if exists { return false }
            }
            var mutable = row
            try mutable.insert(db)
            return true
        }
        return inserted
    }

    public func update(_ run: ScheduledRun) async throws {
        let row = try ScheduledRunRow(run: run)
        try await databaseQueue.maintenanceWrite { db in
            try row.update(db)
        }
    }

    /// Persist the result and comparison decision together. A failed commit
    /// never advances the baseline, and retrying a committed receipt is inert.
    public func finish(_ run: ScheduledRun, task: ScheduledTask) async throws -> ScheduledRun {
        guard run.taskID == task.id, run.isTerminal else { throw ScheduledExperienceError.changed }
        return try await databaseQueue.maintenanceWrite { db in
            guard let oldRow = try ScheduledRunRow.fetchOne(db, key: run.id.uuidString),
                  let old = Self.run(from: oldRow), old.taskID == task.id else { throw ScheduledExperienceError.missing }
            if old.isTerminal {
                guard old.status == run.status, old.outputText == run.outputText, old.errorCode == run.errorCode,
                      old.inputTokens == run.inputTokens, old.outputTokens == run.outputTokens else { throw ScheduledExperienceError.changed }
                return old
            }
            var finished = run
            if run.status == .succeeded, task.effectiveOptions.notifyOnlyOnChange {
                guard var details = run.experience, let value = details.comparisonValue,
                      !ScheduledComparison.canonical(value).isEmpty, value.count <= 4_096,
                      details.definitionFingerprint == task.comparisonFingerprint else { throw ScheduledExperienceError.invalidComparison }
                let previous = try ScheduledRunRow.filter(Column("taskID") == task.id.uuidString)
                    .filter(Column("status") == ScheduledRunStatus.succeeded.rawValue)
                    .filter(Column("id") != run.id.uuidString)
                    .filter(sql: "CASE WHEN json_valid(experienceJSON) THEN json_extract(experienceJSON,'$.definitionFingerprint') END = ?", arguments: [task.comparisonFingerprint])
                    .order(sql: "rowid DESC").limit(1).fetchOne(db).flatMap(Self.run(from:))
                if let previous, let prior = previous.experience?.comparisonValue, !ScheduledComparison.canonical(prior).isEmpty {
                    details.baselineRunID = previous.id
                    details.comparisonState = ScheduledComparison.canonical(prior) == ScheduledComparison.canonical(value) ? .unchanged : .changed
                } else { details.comparisonState = .baseline; details.baselineRunID = nil }
                finished.experience = details
            }
            try ScheduledRunRow(run: finished).update(db)
            try db.execute(sql: "UPDATE scheduled_tasks SET lastRunAt=?,lastRunStatus=? WHERE id=?",
                arguments: [finished.finishedAt ?? Date(), finished.status.rawValue, task.id.uuidString])
            guard let stored = try ScheduledRunRow.fetchOne(db, key: finished.id.uuidString).flatMap(Self.run(from:)) else {
                throw ScheduledExperienceError.missing
            }
            return stored
        }
    }

    public func runs(taskID: UUID, limit: Int = 50) async throws -> [ScheduledRun] {
        let rows = try await databaseQueue.read { db in
            try ScheduledRunRow
                .filter(Column("taskID") == taskID.uuidString)
                .order(sql: "rowid DESC")
                .limit(limit)
                .fetchAll(db)
        }
        return rows.compactMap(Self.run(from:))
    }

    public func latestRun(taskID: UUID) async throws -> ScheduledRun? {
        try await runs(taskID: taskID, limit: 1).first
    }

    public func run(id: UUID) async throws -> ScheduledRun? {
        try await databaseQueue.read { db in
            try ScheduledRunRow.fetchOne(db, key: id.uuidString).flatMap(Self.run(from:))
        }
    }

    public func reference(_ inspected: ScheduledRun) async throws -> ScheduledRun {
        guard let current = try await run(id: inspected.id) else { throw ScheduledExperienceError.missing }
        guard current.isTerminal, current.taskID == inspected.taskID, current.taskName == inspected.taskName,
              current.status == inspected.status, current.outputText == inspected.outputText,
              current.experience?.outputTruncated == inspected.experience?.outputTruncated,
              !(current.outputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduledExperienceError.changed
        }
        return current
    }

    public func activeRun(taskID: UUID) async throws -> ScheduledRun? {
        let rows = try await databaseQueue.read { db in
            try ScheduledRunRow
                .filter(Column("taskID") == taskID.uuidString)
                .filter(
                    Column("status") == ScheduledRunStatus.pending.rawValue
                        || Column("status") == ScheduledRunStatus.running.rawValue
                )
                .order(sql: "rowid DESC")
                .limit(1)
                .fetchAll(db)
        }
        return rows.compactMap(Self.run(from:)).first
    }

    /// 启动时对账：没有运行宿主的 pending/running 记录标记为 interrupted，不自动重放。
    @discardableResult
    public func markInterrupted(now: Date = Date()) async throws -> Int {
        return try await databaseQueue.maintenanceWrite { db in
            let values: [(any DatabaseValueConvertible)?] = [
                ScheduledRunStatus.interrupted.rawValue,
                now,
                "interrupted",
                ScheduledRunStatus.pending.rawValue,
                ScheduledRunStatus.running.rawValue,
            ]
            try db.execute(
                sql: """
                    UPDATE scheduled_runs
                    SET status = ?, finishedAt = ?, errorCode = ?
                    WHERE status IN (?, ?)
                    """,
                arguments: StatementArguments(values)
            )
            return db.changesCount
        }
    }

    /// Explicit cleanup only. Ordinary insertion retains execution receipts.
    /// Never removes active runs, which also guard against duplicate execution.
    public func prune(taskID: UUID, keep: Int = 100) async throws {
        guard keep > 0 else { return }
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: """
                    DELETE FROM scheduled_runs
                    WHERE taskID = ?
                      AND status NOT IN ('pending','running')
                      AND id NOT IN (
                          SELECT id FROM scheduled_runs
                          WHERE taskID = ? AND status NOT IN ('pending','running')
                          ORDER BY rowid DESC
                          LIMIT ?
                      )
                    """,
                arguments: [taskID.uuidString, taskID.uuidString, keep]
            )
        }
    }

    private static func run(from row: ScheduledRunRow) -> ScheduledRun? {
        guard let id = UUID(uuidString: row.id),
              let taskID = UUID(uuidString: row.taskID),
              let trigger = ScheduledRunTrigger(rawValue: row.trigger),
              let status = ScheduledRunStatus(rawValue: row.status) else {
            HubLogger.shared.warning("Scheduled run row skipped: invalid id/trigger/status")
            return nil
        }
        let toolNames = row.toolNamesJSON
            .data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            ?? []
        return ScheduledRun(
            id: id,
            taskID: taskID,
            taskName: row.taskName,
            trigger: trigger,
            scheduledFor: row.scheduledFor,
            status: status,
            startedAt: row.startedAt,
            finishedAt: row.finishedAt,
            outputText: row.outputText,
            summary: row.summary,
            toolNames: toolNames,
            toolCallCount: row.toolCallCount,
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            errorCode: row.errorCode,
            errorText: row.errorText,
            durationMs: row.durationMs,
            experience: row.experienceJSON.flatMap { try? JSONDecoder().decode(ScheduledRunExperience.self, from: Data($0.utf8)) }
        )
    }
}

// MARK: - Row

private struct ScheduledRunRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "scheduled_runs"

    var id: String
    var taskID: String
    var taskName: String
    var trigger: String
    var scheduledFor: Date?
    var status: String
    var startedAt: Date?
    var finishedAt: Date?
    var outputText: String?
    var summary: String?
    var toolNamesJSON: String
    var toolCallCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var errorCode: String?
    var errorText: String?
    var durationMs: Int?
    var experienceJSON: String?

    init(run: ScheduledRun) throws {
        id = run.id.uuidString
        taskID = run.taskID.uuidString
        taskName = run.taskName
        trigger = run.trigger.rawValue
        scheduledFor = run.scheduledFor
        status = run.status.rawValue
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        outputText = run.outputText
        summary = run.summary
        toolNamesJSON = String(
            decoding: try JSONEncoder().encode(run.toolNames),
            as: UTF8.self
        )
        toolCallCount = run.toolCallCount
        inputTokens = run.inputTokens
        outputTokens = run.outputTokens
        errorCode = run.errorCode
        errorText = run.errorText
        durationMs = run.durationMs
        experienceJSON = try run.experience.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }
}
