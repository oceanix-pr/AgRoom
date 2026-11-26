import Foundation
import GRDB

// MARK: - Scheduled Task Store

/// 定时任务定义：绑定单一空间 `DatabaseQueue`，不存在跨空间查询入口。
/// `scheduleJSON` / `notificationJSON` 存快照；能力面只存版本号。
public final class ScheduledTaskStore: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    /// 建表（由 `DatabaseBootstrap` 的迁移器集中调用）。
    static func createSchema(_ database: Database) throws {
        try database.create(table: "scheduled_tasks", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("enabled", .boolean).notNull().defaults(to: false)
            t.column("prompt", .text).notNull()
            t.column("scheduleJSON", .text).notNull()
            t.column("profileVersion", .text).notNull()
            t.column("notificationJSON", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("nextFireAt", .datetime)
            t.column("lastRunAt", .datetime)
            t.column("lastRunStatus", .text)
            t.column("optionsJSON", .text)
        }
        try database.create(
            index: "scheduled_tasks_enabled",
            on: "scheduled_tasks",
            columns: ["enabled"],
            ifNotExists: true
        )
        try database.create(
            index: "scheduled_tasks_nextFireAt",
            on: "scheduled_tasks",
            columns: ["nextFireAt"],
            ifNotExists: true
        )
    }

    public func all() async throws -> [ScheduledTask] {
        let rows = try await databaseQueue.read { db in
            try ScheduledTaskRow
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
        return rows.compactMap(Self.task(from:))
    }

    public func enabled() async throws -> [ScheduledTask] {
        let rows = try await databaseQueue.read { db in
            try ScheduledTaskRow
                .filter(Column("enabled") == true)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
        return rows.compactMap(Self.task(from:))
    }

    public func task(id: UUID) async throws -> ScheduledTask? {
        let row = try await databaseQueue.read { db in
            try ScheduledTaskRow.fetchOne(db, key: id.uuidString)
        }
        return row.flatMap(Self.task(from:))
    }

    public func save(_ task: ScheduledTask) async throws {
        let row = try Self.row(from: task)
        try await databaseQueue.maintenanceWrite { db in
            var mutable = row
            try mutable.save(db)
        }
    }
    public func insert(_ task: ScheduledTask) async throws {
        let row = try Self.row(from: task)
        try await databaseQueue.maintenanceWrite { db in var value = row; try value.insert(db) }
    }

    /// 只更新已存在的任务；任务已删除时 no-op，避免编辑/开关的迟到写入把它复活。
    /// 只写定义与触发游标，保留 `lastRunAt` / `lastRunStatus`：编辑期间完成的运行
    /// 不能被编辑器里的旧快照覆盖。
    public func update(_ task: ScheduledTask) async throws {
        let row = try Self.row(from: task)
        try await databaseQueue.maintenanceWrite { db in
            guard var existing = try ScheduledTaskRow.fetchOne(db, key: row.id) else { return }
            existing.name = row.name
            existing.enabled = row.enabled
            existing.prompt = row.prompt
            existing.scheduleJSON = row.scheduleJSON
            existing.profileVersion = row.profileVersion
            existing.notificationJSON = row.notificationJSON
            existing.optionsJSON = row.optionsJSON
            existing.nextFireAt = row.nextFireAt
            existing.updatedAt = row.updatedAt
            try existing.update(db)
        }
    }

    private static func row(from task: ScheduledTask) throws -> ScheduledTaskRow {
        let encoder = JSONEncoder()
        let scheduleJSON = String(decoding: try encoder.encode(task.schedule), as: UTF8.self)
        let notificationJSON = String(decoding: try encoder.encode(task.notificationPolicy), as: UTF8.self)
        return ScheduledTaskRow(
            id: task.id.uuidString,
            name: task.name,
            enabled: task.enabled,
            prompt: task.prompt,
            scheduleJSON: scheduleJSON,
            profileVersion: task.profileVersion,
            notificationJSON: notificationJSON,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            nextFireAt: task.nextFireAt,
            lastRunAt: task.lastRunAt,
            lastRunStatus: task.lastRunStatus?.rawValue,
            optionsJSON: try task.options.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        )
    }

    /// 只更新触发游标与最近运行状态，避免覆盖并发编辑的正文/规则。
    public func updateFireState(
        id: UUID,
        nextFireAt: Date?,
        lastRunAt: Date?,
        lastRunStatus: ScheduledRunStatus?,
        updatedAt: Date = Date()
    ) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try ScheduledTaskRow.fetchOne(db, key: id.uuidString) else { return }
            row.nextFireAt = nextFireAt
            row.lastRunAt = lastRunAt
            row.lastRunStatus = lastRunStatus?.rawValue
            row.updatedAt = updatedAt
            try row.update(db)
        }
    }

    /// 只更新下次触发时刻（任务编辑/启用/停用后重算）。
    public func updateNextFireAt(id: UUID, nextFireAt: Date?, updatedAt: Date = Date()) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try ScheduledTaskRow.fetchOne(db, key: id.uuidString) else { return }
            row.nextFireAt = nextFireAt
            row.updatedAt = updatedAt
            try row.update(db)
        }
    }

    /// 只更新最近运行状态，不动下一次触发时刻。
    public func updateLastRun(
        id: UUID,
        lastRunAt: Date,
        lastRunStatus: ScheduledRunStatus
    ) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try ScheduledTaskRow.fetchOne(db, key: id.uuidString) else { return }
            row.lastRunAt = lastRunAt
            row.lastRunStatus = lastRunStatus.rawValue
            row.updatedAt = Date()
            try row.update(db)
        }
    }

    /// 一次任务触发后自动停用；其他任务由用户显式停用。
    public func setEnabled(id: UUID, enabled: Bool) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try ScheduledTaskRow.fetchOne(db, key: id.uuidString) else { return }
            row.enabled = enabled
            row.updatedAt = Date()
            try row.update(db)
        }
    }

    public func setEnabled(id: UUID, enabled: Bool, recalculateAt now: Date) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard var row = try ScheduledTaskRow.fetchOne(db, key: id.uuidString), let task = Self.task(from: row) else { throw ScheduledExperienceError.missing }
            if enabled, let error = task.validate(now: now) { throw error }
            row.enabled = enabled
            row.nextFireAt = enabled ? ScheduleCalculator.nextFireDate(for: task.schedule, after: now) : nil
            row.updatedAt = now
            try row.update(db)
        }
    }

    /// Enabling the master switch skips the disabled interval. App downtime
    /// while scheduling stays enabled still follows the ordinary grace policy.
    public func resumeFromNow(_ now: Date) async throws {
        try await databaseQueue.maintenanceWrite { db in
            for var row in try ScheduledTaskRow.filter(Column("enabled") == true).fetchAll(db) {
                guard let task = Self.task(from: row) else { continue }
                row.nextFireAt = ScheduleCalculator.nextFireDate(for: task.schedule, after: now)
                if row.nextFireAt == nil { row.enabled = false }
                try row.update(db)
            }
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await databaseQueue.maintenanceWrite { db in
            try ScheduledTaskRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    private static func task(from row: ScheduledTaskRow) -> ScheduledTask? {
        guard let uuid = UUID(uuidString: row.id),
              let scheduleData = row.scheduleJSON.data(using: .utf8),
              let schedule = try? JSONDecoder().decode(ScheduledTaskSchedule.self, from: scheduleData) else {
            HubLogger.shared.warning("Scheduled task row skipped: invalid id or schedule JSON")
            return nil
        }
        let policy = row.notificationJSON
            .data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(ScheduledNotificationPolicy.self, from: $0) }
            ?? .default
        let options: ScheduledTaskOptions?
        if let text = row.optionsJSON {
            guard let value = try? JSONDecoder().decode(ScheduledTaskOptions.self, from: Data(text.utf8)), value.isValid else {
                HubLogger.shared.warning("Scheduled task row skipped: invalid execution options")
                return nil
            }
            options = value
        } else { options = nil }
        return ScheduledTask(
            id: uuid,
            name: row.name,
            enabled: row.enabled,
            prompt: row.prompt,
            schedule: schedule,
            profileVersion: row.profileVersion,
            notificationPolicy: policy,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            nextFireAt: row.nextFireAt,
            lastRunAt: row.lastRunAt,
            lastRunStatus: row.lastRunStatus.flatMap(ScheduledRunStatus.init(rawValue:)),
            options: options
        )
    }
}

// MARK: - Row

private struct ScheduledTaskRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "scheduled_tasks"

    var id: String
    var name: String
    var enabled: Bool
    var prompt: String
    var scheduleJSON: String
    var profileVersion: String
    var notificationJSON: String
    var createdAt: Date
    var updatedAt: Date
    var nextFireAt: Date?
    var lastRunAt: Date?
    var lastRunStatus: String?
    var optionsJSON: String?
}
