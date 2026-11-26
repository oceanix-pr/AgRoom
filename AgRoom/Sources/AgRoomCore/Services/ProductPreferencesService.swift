import Foundation
import GRDB

/// Restores setup intent only. Names are informational; file URLs, bookmarks and
/// successful connection probes never become durable authority.
public struct FirstResultSetupDraft: Codable, Equatable, Sendable {
    public var template: String
    public var providerID: UUID?
    public var useSample: Bool
    public var sourceNames: [String]
    public var startedAt: Date

    public init(template: String = "organize", providerID: UUID? = nil, useSample: Bool = true,
                sourceNames: [String] = [], startedAt: Date = Date()) {
        self.template = template
        self.providerID = providerID
        self.useSample = useSample
        self.sourceNames = sourceNames
        self.startedAt = startedAt
    }
}

public struct FirstResultProgress: Codable, Equatable, Sendable {
    public var template: String
    public var startedAt: Date
    public var sessionID: UUID
    public var verifiedAt: Date?

    public init(template: String, sessionID: UUID, startedAt: Date = Date()) {
        self.template = template
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}

public struct FirstTaskGuidanceState: Equatable, Sendable {
    public let isHidden: Bool
    public let progress: FirstResultProgress?
    public var shouldOfferNewTask: Bool { !isHidden && progress == nil }
}

public enum ProductEventKind: String, Codable, Sendable {
    case taskStarted, taskCompleted, artifactProduced, artifactUsed, manualIntervention
    case firstResultVerified, restoreAttempted, restoreVerified
}

public struct ProductMetricsSummary: Equatable, Sendable {
    public var tasksStarted: Int
    public var tasksCompleted: Int
    public var tasksWithArtifacts: Int
    public var reusedArtifactTasks: Int
    public var manualInterventions: Int
    public var firstResultSeconds: Double?
    public var restoresAttempted: Int
    public var restoresVerified: Int
    public var measuredSince: Date? = nil
}

/// User-authored and model-derived preferences belong to one physical space database.
/// No current-space lookup or shared service cache is permitted here.
public final class ProductPreferencesService: Sendable {
    public static let didChange = Notification.Name("agroom.product.preferencesChanged")
    private let databaseQueue: DatabaseQueue
    public static let quickPromptsLimit = 20
    static let metricsSinceKey = "metrics.since"
    private static let firstTaskHiddenKey = "first-task.hidden"

    public init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "product_preferences", ifNotExists: true) { table in
            table.column("key", .text).primaryKey()
            table.column("value", .blob).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
    }

    static func createMetricsSchema(_ db: Database) throws {
        try db.create(table: "product_events", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("kind", .text).notNull()
            table.column("taskID", .text)
            table.column("elapsedSeconds", .double)
            table.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "idx_product_events_kind", on: "product_events", columns: ["kind"], ifNotExists: true)
    }

    /// Local counters contain no prompt, file path, model output or network destination.
    public func record(_ kind: ProductEventKind, id: String = UUID().uuidString, taskID: UUID? = nil, elapsedSeconds: Double? = nil) async throws {
        guard elapsedSeconds?.isFinite != false else { throw SpaceServiceError.encodingFailed }
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(sql: "INSERT OR IGNORE INTO product_events (id, kind, taskID, elapsedSeconds, createdAt) VALUES (?, ?, ?, ?, ?)", arguments: [id, kind.rawValue, taskID?.uuidString, elapsedSeconds.map { max(0, $0) }, Date()])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    public func metrics() async throws -> ProductMetricsSummary {
        try await databaseQueue.read { db in
            let since = try Self.metricsSince(in: db)
            func count(_ kind: ProductEventKind, distinctTasks: Bool = false) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(\(distinctTasks ? "DISTINCT taskID" : "*")) FROM product_events WHERE kind = ? AND (? IS NULL OR createdAt >= ?)", arguments: [kind.rawValue, since, since]) ?? 0
            }
            return try ProductMetricsSummary(tasksStarted: count(.taskStarted), tasksCompleted: count(.taskCompleted),
                tasksWithArtifacts: count(.artifactProduced, distinctTasks: true), reusedArtifactTasks: Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT used.taskID) FROM product_events used
                    WHERE used.kind = ? AND (? IS NULL OR used.createdAt >= ?)
                    AND EXISTS (SELECT 1 FROM product_events produced WHERE produced.kind = ? AND produced.taskID = used.taskID
                        AND (? IS NULL OR produced.createdAt >= ?))
                    """, arguments: [ProductEventKind.artifactUsed.rawValue, since, since, ProductEventKind.artifactProduced.rawValue, since, since]) ?? 0,
                manualInterventions: count(.manualIntervention),
                firstResultSeconds: Double.fetchOne(db, sql: "SELECT elapsedSeconds FROM product_events WHERE kind = ? AND (? IS NULL OR createdAt >= ?) ORDER BY createdAt, id LIMIT 1", arguments: [ProductEventKind.firstResultVerified.rawValue, since, since]),
                restoresAttempted: count(.restoreAttempted), restoresVerified: count(.restoreVerified), measuredSince: since)
        }
    }

    public func clearMetrics() async throws {
        try await databaseQueue.maintenanceWrite { db in
            let now = Date()
            try db.execute(sql: "DELETE FROM product_events")
            try db.execute(sql: "INSERT INTO product_preferences(key,value,updatedAt) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt",
                arguments: [Self.metricsSinceKey, try JSONEncoder().encode(now), now])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    static func metricsSince(in db: Database) throws -> Date? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key=?", arguments: [metricsSinceKey]) else { return nil }
        let date = try JSONDecoder().decode(Date.self, from: data)
        guard date.timeIntervalSince1970.isFinite else { throw SpaceServiceError.encodingFailed }
        return date
    }

    public func verifyFirstResult(sessionID: UUID, at date: Date = Date()) async throws -> FirstResultProgress {
        let verified = try await databaseQueue.maintenanceWrite { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key = 'first-result.progress'") else { throw SpaceServiceError.encodingFailed }
            var progress = try JSONDecoder().decode(FirstResultProgress.self, from: data)
            guard progress.sessionID == sessionID else { throw SpaceServiceError.encodingFailed }
            guard progress.verifiedAt == nil else { return progress }
            progress.verifiedAt = date
            try db.execute(sql: "UPDATE product_preferences SET value = ?, updatedAt = ? WHERE key = 'first-result.progress'", arguments: [try JSONEncoder().encode(progress), date])
            try Self.hideFirstTaskGuidance(in: db)
            if try Self.metricsSince(in: db).map({ progress.startedAt >= $0 }) ?? true {
                try db.execute(sql: "INSERT OR IGNORE INTO product_events (id, kind, taskID, elapsedSeconds, createdAt) VALUES (?, ?, ?, ?, ?)", arguments: ["first-result:\(sessionID)", ProductEventKind.firstResultVerified.rawValue, sessionID.uuidString, max(0, date.timeIntervalSince(progress.startedAt)), date])
            }
            return progress
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return verified
    }

    public func beginFirstResult(_ progress: FirstResultProgress) async throws {
        let data = try JSONEncoder().encode(progress)
        try await databaseQueue.maintenanceWrite { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=?)", arguments: [progress.sessionID.uuidString]) == true else { throw SpaceServiceError.encodingFailed }
            try db.execute(sql: "INSERT INTO product_preferences(key,value,updatedAt) VALUES('first-result.progress',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt", arguments: [data, Date()])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Old interrupted versions may have saved a pointer without its session.
    /// Such progress must not trap the user behind an unavailable Resume action.
    public func firstResultProgress() async throws -> FirstResultProgress? {
        try await databaseQueue.read { db in
            try Self.firstResultProgress(in: db)
        }
    }

    /// A space-local, sticky preference: deleting a conversation or clearing metrics
    /// must not make an experienced user a first-time user again. Startup reads
    /// do not take a write lease, so automatic backup cannot block this query.
    public func firstTaskGuidance() async throws -> FirstTaskGuidanceState {
        try await databaseQueue.read { db in
            let progress = try Self.firstResultProgress(in: db)
            let saved = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key=?", arguments: [Self.firstTaskHiddenKey])
            let hidden = try saved.map { try JSONDecoder().decode(Bool.self, from: $0) } ?? false
            if hidden { return FirstTaskGuidanceState(isHidden: true, progress: progress) }
            let hasSucceeded = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM product_task_runs WHERE status=? LIMIT 1)", arguments: [TaskRunStatus.succeeded.rawValue]) == true
            let shouldHide = progress?.verifiedAt != nil || hasSucceeded
            return FirstTaskGuidanceState(isHidden: shouldHide, progress: progress)
        }
    }

    /// Upgrade and restore persist historical success before it can be deleted;
    /// ordinary state reads remain read-only.
    static func backfillFirstTaskGuidance(_ db: Database) throws {
        guard try db.tableExists("product_preferences"), try db.tableExists("product_task_runs") else { return }
        let hasSucceeded = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM product_task_runs WHERE status=? LIMIT 1)", arguments: [TaskRunStatus.succeeded.rawValue]) == true
        if hasSucceeded { try hideFirstTaskGuidance(in: db) }
    }

    public func hideFirstTaskGuidance() async throws {
        try await databaseQueue.maintenanceWrite { try Self.hideFirstTaskGuidance(in: $0) }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    static func hideFirstTaskGuidance(in db: Database) throws {
        let data = try JSONEncoder().encode(true)
        try db.execute(sql: """
            INSERT INTO product_preferences(key,value,updatedAt) VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt
            WHERE product_preferences.value != excluded.value
            """, arguments: [firstTaskHiddenKey, data, Date()])
    }

    private static func firstResultProgress(in db: Database) throws -> FirstResultProgress? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key='first-result.progress'") else { return nil }
        let value = try JSONDecoder().decode(FirstResultProgress.self, from: data)
        if value.verifiedAt == nil {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=?)", arguments: [value.sessionID.uuidString]) == true else { return nil }
        }
        return value
    }

    public func load<Value: Decodable & Sendable>(_ type: Value.Type, key: String) async throws -> Value? {
        try await databaseQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key = ?", arguments: [key]) else { return nil }
            return try JSONDecoder().decode(type, from: data)
        }
    }

    public func save<Value: Encodable & Sendable>(_ value: Value, key: String) async throws {
        let data = try JSONEncoder().encode(value)
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(sql: "INSERT INTO product_preferences (key, value, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt", arguments: [key, data, Date()])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Rates and dismissed rows are one space-bound snapshot, including when no
    /// rate has ever been saved for a historical model.
    public func loadModelPrices() async throws -> (prices: [ProductModelPrice], dismissedIDs: Set<String>) {
        try await databaseQueue.read { db in try Self.modelPrices(in: db) }
    }

    /// A background lookup must not replace another view's manual edit or restore
    /// a deleted row. Compare and write both values in the same transaction.
    public func saveModelPrices(_ prices: [ProductModelPrice], replacing expected: [ProductModelPrice],
                                dismissedIDs: Set<String> = [], replacingDismissedIDs expectedDismissed: Set<String> = []) async throws {
        let ids = Set(prices.map(\.id))
        guard prices.allSatisfy(\.isValid), ids.count == prices.count, ids.isDisjoint(with: dismissedIDs) else {
            throw SpaceServiceError.encodingFailed
        }
        let data = try JSONEncoder().encode(prices)
        let dismissedData = try JSONEncoder().encode(dismissedIDs.sorted())
        try Task.checkCancellation()
        try await databaseQueue.maintenanceWrite { db in
            let current = try Self.modelPrices(in: db)
            guard current.prices == expected, current.dismissedIDs == expectedDismissed else { throw ModelPriceConflict.changed }
            let now = Date()
            try db.execute(sql: "INSERT INTO product_preferences (key, value, updatedAt) VALUES ('model-prices', ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt", arguments: [data, now])
            try db.execute(sql: "INSERT INTO product_preferences (key, value, updatedAt) VALUES ('model-price-dismissed-ids', ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt", arguments: [dismissedData, now])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private static func modelPrices(in db: Database) throws -> (prices: [ProductModelPrice], dismissedIDs: Set<String>) {
        let prices = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key = 'model-prices'")
        let dismissed = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key = 'model-price-dismissed-ids'")
        return (try prices.map { try JSONDecoder().decode([ProductModelPrice].self, from: $0) } ?? [],
                try dismissed.map { try JSONDecoder().decode(Set<String>.self, from: $0) } ?? [])
    }

    public func quickPrompts() async throws -> [String] {
        try await load([String].self, key: "quick-prompts") ?? []
    }

    public func saveQuickPrompts(_ prompts: [String]) async throws {
        var seen = Set<String>()
        let normalized = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        try await save(Array(normalized.prefix(Self.quickPromptsLimit)), key: "quick-prompts")
    }
}

public enum ModelPriceConflict: Error {
    case changed
}

/// Old preferences did not record their source space. Never guess ownership on upgrade.
@MainActor
public enum LegacyQuickPromptMigration {
    public static let key = "agroom.quickPrompts"
    private static var migrating = false

    public static func isAvailable(in preferences: UserDefaults = .standard) -> Bool {
        preferences.data(forKey: key) != nil
    }

    public static func migrate(to service: ProductPreferencesService, preferences: UserDefaults = .standard) async throws {
        guard !migrating else { throw SpaceServiceError.encodingFailed }
        guard let data = preferences.data(forKey: key) else { return }
        migrating = true
        defer { migrating = false }
        let old = try JSONDecoder().decode([String].self, from: data)
        let current = try await service.quickPrompts()
        var seen = Set<String>()
        let merged = (current + old).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // Retain the legacy copy on capacity or storage failure; no silent truncation.
        guard merged.count <= ProductPreferencesService.quickPromptsLimit else { throw SpaceServiceError.encodingFailed }
        try await service.saveQuickPrompts(merged)
        if preferences.data(forKey: key) == data { preferences.removeObject(forKey: key) }
    }
}
