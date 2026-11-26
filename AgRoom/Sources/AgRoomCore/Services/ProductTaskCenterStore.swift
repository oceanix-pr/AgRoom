import Foundation
import GRDB

public enum ProductTaskSource: String, CaseIterable, Sendable { case chat, team, scheduled, job }

private extension ProductTaskSource {
    var historyTable: String {
        switch self {
        case .chat: "product_task_runs"
        case .team: "team_tasks"
        case .scheduled: "scheduled_runs"
        case .job: "product_job_runs"
        }
    }

    /// Used by both the timeline and the write transaction. A missing live
    /// snapshot alone cannot establish that a running receipt is safe to clear.
    var clearableHistorySQL: String {
        switch self {
        case .chat: "r.status IN ('succeeded','cancelled','failed','incomplete')"
        case .team: "r.status IN ('completed','cancelled','failed','interrupted')"
        case .scheduled: "r.status IN ('succeeded','cancelled','skipped','failed','missed','interrupted')"
        case .job:
            """
            (r.status IN ('succeeded','cancelled','failed','interrupted','interruptionAcknowledged')
             OR (r.status IN ('queued','running') AND r.hostID IS NOT ?))
            """
        }
    }
}

public struct ProductTaskCenterItem: Identifiable, Sendable, Equatable {
    public let space: AppSpace?
    public let source: ProductTaskSource
    public let sourceID: UUID
    public var id: String { source.rawValue + ":" + sourceID.uuidString }
    public let title: String
    public let preview: String
    public let status: TaskRunStatus
    public let sourceStatus: String
    public let canClearHistory: Bool
    public let startedAt: Date
    public let finishedAt: Date?
    public let sessionID: UUID?
    public let messageID: UUID?
    public let workspaceID: String?
    public let mode: ChatMode?
    public let parentID: UUID?
    public var origin: String? = nil

    public static func job(_ job: BackgroundJob) -> Self {
        return .init(space: job.space, source: .job, sourceID: job.id, title: job.name, preview: String((job.errorText ?? job.resultText ?? "").prefix(512)),
            status: job.state.taskCenterStatus, sourceStatus: job.state.rawValue, canClearHistory: job.state.isFinished,
            startedAt: Date.fromDatabaseValue(job.submittedAt.databaseValue) ?? job.submittedAt,
            finishedAt: job.finishedAt, sessionID: nil, messageID: nil, workspaceID: nil, mode: nil, parentID: nil, origin: job.origin)
    }
}

public extension BackgroundJob.State {
    var taskCenterStatus: TaskRunStatus {
        switch self {
        case .queued, .running: .running
        case .awaitingSave, .interrupted: .recoveryRequired
        case .failed: .failed
        case .cancelled, .interruptionAcknowledged: .cancelled
        case .succeeded: .succeeded
        }
    }
}

public struct ProductTaskCenterPage: Sendable {
    public let items: [ProductTaskCenterItem]
    public let hasMore: Bool
}

/// SQL projects only bounded summaries and pages the combined timeline, instead
/// of loading every conversation or taking the latest answer from each one.
public struct ProductTaskCenterStore: Sendable {
    public static let didChange = Notification.Name("agroom.product.taskCenterHistoryChanged")
    private let queue: DatabaseQueue
    private let space: AppSpace
    public init(databaseQueue: DatabaseQueue, space: AppSpace) { queue = databaseQueue; self.space = space }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "product_task_center_cleared", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("clearedAt", .datetime).notNull()
        }
    }

    /// Remove one run or all eligible history from this space's task center.
    /// Recheck the source at confirmation time and retain its original receipt.
    @discardableResult
    public func clearFinished(only item: ProductTaskCenterItem? = nil, jobs: [BackgroundJob] = []) async throws -> Int {
        if let item, item.space != space { throw ProductTaskHistoryError.invalidRecord }
        let sources = item.map { [$0.source] } ?? ProductTaskSource.allCases
        let scopedJobs = jobs.filter { job in
            guard job.space == space else { return false }
            guard let item else { return true }
            return item.source == .job && item.sourceID == job.id
        }
        let liveIDs = scopedJobs.filter { !$0.state.isFinished }.map { $0.id.uuidString }
        let count = try await queue.maintenanceWrite { db in
            let now = Date()
            var count = 0
            for source in sources {
                var predicates = [source.clearableHistorySQL]
                var arguments = [now.databaseValue]
                if source == .job {
                    arguments.append(ProductJobRunStore.hostID.databaseValue)
                    if !liveIDs.isEmpty {
                        predicates.append("r.id NOT IN (" + Array(repeating: "?", count: liveIDs.count).joined(separator: ",") + ")")
                        arguments += liveIDs.map(\.databaseValue)
                    }
                }
                if let item {
                    predicates.append("r.id = ?")
                    arguments.append(item.sourceID.uuidString.databaseValue)
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO product_task_center_cleared (id, clearedAt)
                    SELECT '\(source.rawValue):' || r.id, ? FROM \(source.historyTable) r
                    WHERE \(predicates.joined(separator: " AND "))
                    """, arguments: StatementArguments(arguments))
                count += db.changesCount
            }
            // Older toolbar jobs can have a cache entry but no database receipt.
            for job in scopedJobs where job.state.isFinished {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO product_task_center_cleared (id, clearedAt)
                    SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM product_job_runs WHERE id=?)
                    """, arguments: ["job:" + job.id.uuidString, now, job.id.uuidString])
                count += db.changesCount
            }
            return count
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return count
    }

    public func page(group: ProductTaskGroup? = nil, source: ProductTaskSource? = nil, search: String = "",
                     before: ProductTaskCenterItem? = nil, limit: Int = 40,
                     activeChatRunIDs: Set<UUID> = [], activeTeamTaskIDs: Set<UUID> = [], activeScheduledRunIDs: Set<UUID> = [],
                     jobs: [BackgroundJob] = [], includeHidden: Bool = false) async throws -> ProductTaskCenterPage {
        let count = min(100, max(1, limit))
        let (databaseItems, clearedJobs, overlaidJobs) = try await queue.read { db in
            var arguments: [DatabaseValue] = []
            func activityTest(_ ids: Set<UUID>, column: String) -> String {
                let values = ids.map(\.uuidString).sorted()
                arguments += values.map(\.databaseValue)
                return values.isEmpty ? "0" : column + " IN (" + Array(repeating: "?", count: values.count).joined(separator: ",") + ")"
            }
            let activeTest = activityTest(activeChatRunIDs, column: "r.id")
            let teamActiveTest = activityTest(activeTeamTaskIDs, column: "id")
            let scheduledActiveTest = activityTest(activeScheduledRunIDs, column: "id")
            let overlaidJobs = try jobs.filter { job in
                guard job.space == space else { return false }
                guard job.state == .interrupted else { return true }
                // An interrupted cache entry must follow any subsequent disposition in the database.
                return try String.fetchOne(db, sql: "SELECT id FROM product_job_runs WHERE id=?",
                    arguments: [job.id.uuidString]) == nil
            }
            let liveJobIDs = overlaidJobs.map { $0.id.uuidString }.sorted()
            let archivedJobTest = liveJobIDs.isEmpty ? "1" : "id NOT IN (" + Array(repeating: "?", count: liveJobIDs.count).joined(separator: ",") + ")"
            arguments.append(ProductJobRunStore.hostID.databaseValue)
            arguments += liveJobIDs.map(\.databaseValue)
            var predicates = [includeHidden ? "1" : "hidden = 0",
                "(NOT canClearHistory OR NOT EXISTS (SELECT 1 FROM product_task_center_cleared c WHERE c.id=timeline.itemKey))"]
            if let group {
                let states: [TaskRunStatus] = [.running, .waitingForConfirmation, .waitingForInput, .succeeded, .incomplete, .failed, .cancelled, .recoveryRequired]
                let accepted = states.filter { $0.taskGroup == group }
                predicates.append("status IN (" + Array(repeating: "?", count: accepted.count).joined(separator: ",") + ")")
                arguments += accepted.map { $0.rawValue.databaseValue }
            }
            if let source { predicates.append("source = ?"); arguments.append(source.rawValue.databaseValue) }
            if !search.isEmpty {
                predicates.append("(instr(lower(title), lower(?)) > 0 OR instr(lower(preview), lower(?)) > 0)")
                arguments += [search.databaseValue, search.databaseValue]
            }
            if let before {
                predicates.append("(startedAt < ? OR (startedAt = ? AND itemKey < ?))")
                arguments += [before.startedAt.databaseValue, before.startedAt.databaseValue, before.id.databaseValue]
            }
            arguments.append((count + 1).databaseValue)
            let sql = """
                WITH timeline AS (
                    SELECT 'chat' AS source, r.id AS sourceID, 'chat:' || r.id AS itemKey,
                        r.title, r.preview, CASE WHEN r.status='running' AND NOT (\(activeTest)) THEN 'recoveryRequired' ELSE r.status END AS status,
                        r.status AS sourceStatus, r.startedAt, r.finishedAt, r.sessionID, r.messageID, r.workspaceID, r.mode,
                        NULL AS parentID, COALESCE(s.isHidden,0) AS hidden, NULL AS origin,
                        \(ProductTaskSource.chat.clearableHistorySQL) AS canClearHistory
                    FROM product_task_runs r LEFT JOIN chat_sessions s ON s.id=r.sessionID
                    UNION ALL
                    SELECT 'team', id, 'team:' || id, substr(goal,1,120),
                        substr(CASE WHEN json_valid(reportJSON) THEN COALESCE(json_extract(reportJSON,'$.verification.summary'),json_extract(reportJSON,'$.errors[0]'),json_extract(reportJSON,'$.subtasks[0].summary'),'') ELSE '' END,1,512),
                        CASE WHEN status NOT IN ('completed','failed','cancelled','interrupted') AND NOT (\(teamActiveTest)) THEN 'recoveryRequired' ELSE
                        CASE status WHEN 'completed' THEN 'succeeded' WHEN 'failed' THEN 'failed'
                            WHEN 'cancelled' THEN 'cancelled' WHEN 'interrupted' THEN 'recoveryRequired'
                            WHEN 'waitingForApproval' THEN 'waitingForConfirmation' WHEN 'waitingForUser' THEN 'waitingForInput' ELSE 'running' END END,
                        status, startedAt, finishedAt, NULL, NULL, NULL, NULL, parentTaskID, 0, NULL, \(ProductTaskSource.team.clearableHistorySQL)
                    FROM team_tasks r
                    UNION ALL
                    SELECT 'scheduled', id, 'scheduled:' || id, taskName, substr(COALESCE(errorText,summary,outputText,''),1,512),
                        CASE WHEN status IN ('pending','running') AND NOT (\(scheduledActiveTest)) THEN 'recoveryRequired' ELSE
                        CASE status WHEN 'succeeded' THEN 'succeeded' WHEN 'cancelled' THEN 'cancelled' WHEN 'skipped' THEN 'cancelled'
                            WHEN 'pending' THEN 'running' WHEN 'running' THEN 'running' WHEN 'interrupted' THEN 'recoveryRequired' ELSE 'failed' END END,
                        status, COALESCE(startedAt,scheduledFor,finishedAt,'1970-01-01 00:00:00.000'), finishedAt, NULL, NULL, NULL, NULL, taskID, 0, NULL, \(ProductTaskSource.scheduled.clearableHistorySQL)
                    FROM scheduled_runs r
                    UNION ALL
                    SELECT 'job', id, 'job:' || id, title, preview,
                        CASE status WHEN 'succeeded' THEN 'succeeded' WHEN 'cancelled' THEN 'cancelled'
                            WHEN 'interruptionAcknowledged' THEN 'cancelled' WHEN 'failed' THEN 'failed' ELSE 'recoveryRequired' END,
                        status, startedAt, finishedAt, NULL, NULL, NULL, NULL, NULL, 0, origin, \(ProductTaskSource.job.clearableHistorySQL)
                    FROM product_job_runs r WHERE \(archivedJobTest)
                )
                SELECT * FROM timeline WHERE \(predicates.joined(separator: " AND ")) ORDER BY startedAt DESC, itemKey DESC LIMIT ?
                """
            let items = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row -> ProductTaskCenterItem in
                guard let source = ProductTaskSource(rawValue: row["source"]), let id = UUID(uuidString: row["sourceID"]),
                      let status = TaskRunStatus(rawValue: row["status"]) else { throw ProductTaskHistoryError.invalidRecord }
                let session: String? = row["sessionID"], message: String? = row["messageID"], parent: String? = row["parentID"], mode: String? = row["mode"]
                return .init(space: space, source: source, sourceID: id, title: row["title"], preview: row["preview"], status: status,
                    sourceStatus: row["sourceStatus"], canClearHistory: row["canClearHistory"], startedAt: row["startedAt"], finishedAt: row["finishedAt"],
                    sessionID: session.flatMap(UUID.init(uuidString:)), messageID: message.flatMap(UUID.init(uuidString:)),
                    workspaceID: row["workspaceID"], mode: mode.flatMap(ChatMode.init(rawValue:)), parentID: parent.flatMap(UUID.init(uuidString:)), origin: row["origin"])
            }
            let clearedJobs = try Self.clearedHistoryIDs(liveJobIDs.map { "job:" + $0 }, in: db)
            return (items, clearedJobs, overlaidJobs)
        }
        let jobItems = overlaidJobs.map(ProductTaskCenterItem.job).filter { item in
            (group == nil || item.status.taskGroup == group) && (source == nil || source == .job)
                && (!item.canClearHistory || !clearedJobs.contains(item.id))
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.preview.localizedCaseInsensitiveContains(search))
                && (before == nil || item.startedAt < before!.startedAt || (item.startedAt == before!.startedAt && item.id < before!.id))
        }
        let combined = (databaseItems + jobItems).sorted { $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt }
        return .init(items: Array(combined.prefix(count)), hasMore: combined.count > count)
    }

    /// The toolbar and live job overlay observe the same per-space clear markers.
    public func clearedHistoryIDs(among ids: Set<String>) async throws -> Set<String> {
        try await queue.read { try Self.clearedHistoryIDs(Array(ids), in: $0) }
    }

    private static func clearedHistoryIDs(_ ids: [String], in db: Database) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let request: SQLRequest<String> = "SELECT id FROM product_task_center_cleared WHERE id IN \(ids)"
        return Set(try request.fetchAll(db))
    }
}
