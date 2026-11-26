import Foundation
import GRDB

// MARK: - Team Task Record

public enum TeamRetryAction: Equatable, Sendable {
    case rerun, revise
}

/// 任务板读取的一条任务记录：计划 + 最近一次报告快照。
/// 只存 JSON 快照而不是拆分多表：P1 的任务板只需要整体展示和最近状态，
/// 等出现跨任务查询/单子任务检索需求再规范化。
public struct TeamTaskRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let goal: String
    public let status: TeamTaskStatus
    public let plan: TeamPlan
    public let report: TeamTaskReport?
    public let startedAt: Date
    public let updatedAt: Date
    public let finishedAt: Date?
    /// 本次执行的稳定 ID。显式重试会创建新的 runID，并通过 parentTaskID 关联原任务。
    public let runID: UUID?
    public let parentTaskID: UUID?

    public init(
        id: UUID,
        goal: String,
        status: TeamTaskStatus,
        plan: TeamPlan,
        report: TeamTaskReport?,
        startedAt: Date,
        updatedAt: Date,
        finishedAt: Date?,
        runID: UUID? = nil,
        parentTaskID: UUID? = nil
    ) {
        self.id = id
        self.goal = goal
        self.status = status
        self.plan = plan
        self.report = report
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.runID = runID
        self.parentTaskID = parentTaskID
    }

    public var isFinished: Bool { status.isTerminal }

    public var retryAction: TeamRetryAction? {
        guard status == .failed || status == .interrupted,
              report?.artifacts.contains(where: { $0.kind == "file-change" || $0.writeRecordID != nil }) != true
        else { return nil }
        if status == .failed, let report, report.status == .failed,
           report.verification?.rejectedDeliverables == true,
           !report.subtasks.isEmpty, report.subtasks.allSatisfy({ $0.outcome == .succeeded }) {
            return .revise
        }
        return .rerun
    }
}

public extension TeamTaskStatus {
    /// 是否已进入终态（不再由协调器推进）。
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        case .planning, .running, .waitingForUser, .waitingForApproval, .verifying, .cancelling:
            return false
        }
    }
}

// MARK: - Team Task Store

/// 团队任务持久化：绑定单一空间 `DatabaseQueue`，不存在跨空间查询入口。
/// 保存计划与报告快照，供任务板展示和重启后回看；P1 不做运行中恢复。
public final class TeamTaskStore: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表（由 `DatabaseBootstrap` 的迁移器集中调用）。
    static func createSchema(_ database: Database) throws {
        try database.create(table: "team_tasks", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("goal", .text).notNull()
            t.column("status", .text).notNull()
            t.column("planJSON", .text).notNull()
            t.column("reportJSON", .text)
            t.column("startedAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("finishedAt", .datetime)
            t.column("runID", .text)
            t.column("runVersion", .integer).notNull().defaults(to: 0)
            t.column("parentTaskID", .text)
        }
        try database.create(
            index: "team_tasks_updatedAt",
            on: "team_tasks",
            columns: ["updatedAt"],
            ifNotExists: true
        )
    }

    /// 旧库补 runID / runVersion / parentTaskID 列（幂等）。
    static func addRunColumns(_ database: Database) throws {
        let columns = try database.columns(in: "team_tasks").map(\.name)
        if !columns.contains("runID") {
            try database.alter(table: "team_tasks") { t in t.add(column: "runID", .text) }
        }
        if !columns.contains("runVersion") {
            try database.alter(table: "team_tasks") { t in
                t.add(column: "runVersion", .integer).notNull().defaults(to: 0)
            }
        }
        if !columns.contains("parentTaskID") {
            try database.alter(table: "team_tasks") { t in t.add(column: "parentTaskID", .text) }
        }
    }

    /// 保存/覆盖一条任务快照。协调器在启动、每个子任务结束后、最终报告时调用。
    ///
    /// `createIfMissing = false` 用于迟到回调：任务被删除后，旧运行不能把它复活。
    /// `runVersion` 保证同一任务的旧快照不能覆盖新快照；停止/删除流程据此丢弃迟到写入。
    public func save(
        plan: TeamPlan,
        report: TeamTaskReport,
        runID: UUID? = nil,
        runVersion: Int = 0,
        parentTaskID: UUID? = nil,
        createIfMissing: Bool = true
    ) async throws {
        let encoder = JSONEncoder()
        let planData = try encoder.encode(plan)
        let reportData = try encoder.encode(report)
        let planJSON = String(decoding: planData, as: UTF8.self)
        let reportJSON = String(decoding: reportData, as: UTF8.self)
        let id = report.taskID.uuidString
        let goal = report.goal
        let status = report.status.rawValue
        let startedAt = report.startedAt
        let finishedAt = report.status.isTerminal ? report.finishedAt : nil
        let updatedAt = Date()
        let incomingRunID = runID?.uuidString
        let incomingParent = parentTaskID?.uuidString
        try await databaseQueue.maintenanceWrite { db in
            if var existing = try TeamTaskRow.fetchOne(db, key: id) {
                // 同一任务的迟到回调：runID 不同或版本更旧 → 丢弃，绝不覆盖。
                if let incomingRunID, let stored = existing.runID, stored != incomingRunID {
                    return
                }
                if existing.runVersion > runVersion {
                    return
                }
                existing.goal = goal
                existing.status = status
                existing.planJSON = planJSON
                existing.reportJSON = reportJSON
                existing.startedAt = startedAt
                existing.updatedAt = updatedAt
                existing.finishedAt = finishedAt
                existing.runVersion = runVersion
                if let incomingRunID { existing.runID = incomingRunID }
                if let incomingParent { existing.parentTaskID = incomingParent }
                try existing.update(db)
            } else {
                guard createIfMissing else { return }
                var row = TeamTaskRow(
                    id: id,
                    goal: goal,
                    status: status,
                    planJSON: planJSON,
                    reportJSON: reportJSON,
                    startedAt: startedAt,
                    updatedAt: updatedAt,
                    finishedAt: finishedAt,
                    runID: incomingRunID,
                    runVersion: runVersion,
                    parentTaskID: incomingParent
                )
                try row.insert(db)
            }
        }
    }

    /// 重启后没有宿主进程的非终态任务：标记为 interrupted，不能长期显示 running。
    /// 不自动重放不确定副作用。
    public func interruptUnfinishedTasks() async throws {
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(
                sql: """
                    UPDATE team_tasks
                    SET status = ?, updatedAt = ?, finishedAt = COALESCE(finishedAt, ?)
                    WHERE status IN (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    TeamTaskStatus.interrupted.rawValue,
                    Date(),
                    Date(),
                    TeamTaskStatus.planning.rawValue,
                    TeamTaskStatus.running.rawValue,
                    TeamTaskStatus.waitingForUser.rawValue,
                    TeamTaskStatus.waitingForApproval.rawValue,
                    TeamTaskStatus.verifying.rawValue,
                    TeamTaskStatus.cancelling.rawValue,
                ]
            )
        }
    }

    /// 最近任务（按更新时间倒序）；损坏的 JSON 行跳过并记录日志，不阻断任务板。
    public func listTasks(limit: Int = 100) async throws -> [TeamTaskRecord] {
        let capped = min(max(limit, 1), 500)
        let rows = try await databaseQueue.read { db in
            try TeamTaskRow
                .order(Column("updatedAt").desc)
                .limit(capped)
                .fetchAll(db)
        }
        let decoder = JSONDecoder()
        return rows.compactMap { row -> TeamTaskRecord? in
            guard let record = Self.record(from: row, decoder: decoder) else {
                HubLogger.shared.warning("Team task row skipped: invalid id or plan JSON")
                return nil
            }
            return record
        }
    }

    public func task(id: UUID) async throws -> TeamTaskRecord? {
        let row = try await databaseQueue.read { db in try TeamTaskRow.fetchOne(db, key: id.uuidString) }
        return Self.record(from: row)
    }

    /// Resolve the source in this space at confirmation time. A write can have a
    /// durable receipt even if the process stopped before saving its artifact.
    func planForRetry(id: UUID, expectedPlan: TeamPlan, revisionTitle: String?) async throws -> TeamPlan {
        let row = try await databaseQueue.read { db in
            try TeamTaskRow.fetchOne(db, sql: """
                SELECT * FROM team_tasks WHERE id = ?
                AND NOT EXISTS (SELECT 1 FROM team_writes WHERE taskID = team_tasks.id)
                """, arguments: [id.uuidString])
        }
        guard let source = Self.record(from: row), source.plan == expectedPlan,
              let action = source.retryAction else { throw TeamError.retryUnavailable }
        guard action == .revise, let report = source.report, let review = report.verification else {
            return source.plan
        }

        var seen = Set([source.plan.goal])
        let requirements = source.plan.subtasks.flatMap { [$0.objective] + $0.acceptance }
            .filter { seen.insert($0).inserted }
        let editor = TeamSubtask(title: revisionTitle ?? source.goal, objective: source.plan.goal,
                                 role: .synthesizer, acceptance: requirements,
                                 estimatedTokens: source.plan.subtasks.map(\.estimatedTokens).max() ?? 0)
        var plan = TeamPlan(goal: source.plan.goal, acceptance: source.plan.acceptance,
                            subtasks: [editor], maxConcurrency: 1)
        plan.revision = TeamRevision(reviewSummary: review.summary, issues: review.issues,
                                     material: TeamReviewMaterial(subtasks: report.subtasks, artifacts: report.artifacts),
                                     openQuestions: report.openQuestions)
        return plan
    }

    private static func record(from row: TeamTaskRow?, decoder: JSONDecoder = JSONDecoder()) -> TeamTaskRecord? {
        guard let row, let uuid = UUID(uuidString: row.id),
              let planData = row.planJSON.data(using: .utf8),
              let plan = try? decoder.decode(TeamPlan.self, from: planData) else {
            return nil
        }
        let report = row.reportJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode(TeamTaskReport.self, from: $0) }
        return TeamTaskRecord(
            id: uuid,
            goal: row.goal,
            status: TeamTaskStatus(rawValue: row.status) ?? .failed,
            plan: plan,
            report: report,
            startedAt: row.startedAt,
            updatedAt: row.updatedAt,
            finishedAt: row.finishedAt,
            runID: row.runID.flatMap(UUID.init(uuidString:)),
            parentTaskID: row.parentTaskID.flatMap(UUID.init(uuidString:))
        )
    }

    /// 将一条没有运行宿主的非终态任务标记为中断。
    public func markInterrupted(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try TeamTaskRow.fetchOne(db, key: id.uuidString) else { return }
            let status = TeamTaskStatus(rawValue: row.status)
            guard status?.isTerminal == false else { return }
            row.status = TeamTaskStatus.interrupted.rawValue
            row.updatedAt = Date()
            row.finishedAt = row.finishedAt ?? Date()
            try row.update(db)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try TeamTaskRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }
}

// MARK: - Row

private struct TeamTaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "team_tasks"

    var id: String
    var goal: String
    var status: String
    var planJSON: String
    var reportJSON: String?
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var runID: String?
    var runVersion: Int
    var parentTaskID: String?
}
