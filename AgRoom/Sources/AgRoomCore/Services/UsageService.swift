import Foundation
import GRDB

/// Only request metadata and provider-reported counts; never prompts, responses or credentials.
public struct ProviderUsageRecorder: Sendable {
    let service: UsageService
    let source: String
    let sessionID: UUID?
    public init(service: UsageService, source: String, sessionID: UUID? = nil) {
        self.service = service; self.source = source; self.sessionID = sessionID
    }
    func begin(providerID: UUID, model: String, providerName: String? = nil) async -> UUID {
        let id = UUID()
        do {
            try await service.begin(id: id, providerID: providerID, model: model, source: source, sessionID: sessionID,
                providerName: providerName, request: ProviderRequestContext.current)
        } catch { HubLogger.shared.warning("Usage request receipt could not be saved") }
        return id
    }
    func finish(id: UUID, input: Int?, output: Int?, status: String, details: ProviderTokenUsage = .init()) async {
        do { try await Task.detached { try await service.finish(id: id, input: input, output: output, status: status, details: details) }.value }
        catch { HubLogger.shared.warning("Usage result receipt could not be saved") }
    }
}

/// Counts already observed from a stream remain usable even when the connection ends early.
final class ProviderUsageProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var usage = ProviderTokenUsage()
    func update(input: Int?, output: Int?) {
        lock.withLock {
            if let input, input >= 0 { self.usage.input = input }
            if let output, output >= 0 { self.usage.output = output }
        }
    }
    func observe(_ json: [String: Any], anthropic: Bool) {
        let message = json["message"] as? [String: Any]
        var incoming = ProviderTokenUsage.decode(message?["usage"] as? [String: Any] ?? json["usage"] as? [String: Any], anthropic: anthropic)
        incoming.reportedModel = (message?["model"] as? String ?? json["model"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        lock.withLock { usage.merge(incoming, anthropic: anthropic) }
    }
    func merge(_ incoming: ProviderTokenUsage, anthropic: Bool) {
        lock.withLock { usage.merge(incoming, anthropic: anthropic) }
    }
    var snapshot: ProviderTokenUsage { lock.withLock { usage } }
}

/// Bound to one space database. Receipts outlive display edits and conversation deletion.
public final class UsageService: Sendable {
    public static let didChange = Notification.Name("agroom.usage.didChange")
    private let databaseQueue: DatabaseQueue
    public init(databaseQueue: DatabaseQueue) { self.databaseQueue = databaseQueue }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "provider_usage", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("sessionId", .text) // No cascading foreign key: deleting a chat does not undo a request.
            t.column("providerId", .text)
            t.column("model", .text).notNull().defaults(to: "")
            t.column("source", .text).notNull()
            t.column("startedAt", .datetime).notNull().indexed()
            t.column("finishedAt", .datetime)
            t.column("inputTokens", .integer)
            t.column("outputTokens", .integer)
            t.column("status", .text).notNull()
        }
        try addBreakdownColumns(db)
    }

    static func addBreakdownColumns(_ db: Database) throws {
        let columns = Set(try db.columns(in: "provider_usage").map(\.name))
        for name in ["providerName", "reportedModel", "requestContextJSON"] where !columns.contains(name) {
            try db.alter(table: "provider_usage") { $0.add(column: name, .text) }
        }
        for name in ["cacheReadTokens", "cacheWriteTokens", "ordinaryInputTokens", "reasoningTokens", "inputTextTokens", "inputImageTokens", "outputImageTokens"] where !columns.contains(name) {
            try db.alter(table: "provider_usage") { $0.add(column: name, .integer) }
        }
        try db.create(index: "idx_usage_model_date", on: "provider_usage", columns: ["providerId", "model", "startedAt"], ifNotExists: true)
    }

    func begin(id: UUID, providerID: UUID, model: String, source: String, sessionID: UUID?, at: Date = Date(), providerName: String? = nil,
               request: ProviderRequestMetadata? = nil) async throws {
        let contextJSON = try request.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await databaseQueue.maintenanceWrite { db in
            try db.execute(sql: "INSERT INTO provider_usage (id, sessionId, providerId, model, source, startedAt, status, providerName, requestContextJSON) VALUES (?, ?, ?, ?, ?, ?, 'started', ?, ?)",
                arguments: [id.uuidString, sessionID?.uuidString, providerID.uuidString, model, source, at, providerName, contextJSON])
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func finish(id: UUID, input: Int?, output: Int?, status: String, details: ProviderTokenUsage = .init()) async throws {
        let input = input.flatMap { $0 >= 0 ? $0 : nil }, output = output.flatMap { $0 >= 0 ? $0 : nil }
        try await databaseQueue.maintenanceWrite { db in
            // Idempotent finalization; delayed callbacks cannot change an already committed receipt.
            try db.execute(sql: "UPDATE provider_usage SET inputTokens = ?, outputTokens = ?, status = ?, finishedAt = ?, reportedModel = ?, cacheReadTokens = ?, cacheWriteTokens = ?, ordinaryInputTokens = ?, reasoningTokens = ?, inputTextTokens = ?, inputImageTokens = ?, outputImageTokens = ? WHERE id = ? AND status = 'started'",
                arguments: [input, output, status, Date(), details.reportedModel, details.cacheRead, details.cacheWrite, details.ordinaryInput, details.reasoning, details.inputText, details.inputImage, details.outputImage, id.uuidString])
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func getStats(in interval: DateInterval? = nil, calendar: Calendar = .current) async throws -> UsageStats {
        try await databaseQueue.read { db in
            let predicate = Self.predicate(interval: interval, filter: .all)
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT u.*, s.title AS sessionTitle FROM provider_usage u
                LEFT JOIN chat_sessions s ON s.id = u.sessionId
                \(predicate.sql) ORDER BY u.startedAt DESC, u.id DESC
                """, arguments: predicate.arguments)
            var stats = UsageStats()
            var sessions: [String: UsageStats.SessionUsage] = [:]
            var models: [String: UsageModelSummary] = [:]
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            while let row = try cursor.next() {
                let input: Int? = row["inputTokens"], output: Int? = row["outputTokens"]
                let date: Date = row["startedAt"], source: String = row["source"], status: String = row["status"]
                let i = input ?? 0, o = output ?? 0
                stats.totalInputTokens += i; stats.totalOutputTokens += o; stats.totalTurns += 1
                if input != nil { stats.reportedInputRecords += 1 }
                if output != nil { stats.reportedOutputRecords += 1 }
                if source == "legacy" { stats.legacyTurns += 1 }
                else {
                    stats.totalRequests += 1
                    if input == nil || output == nil { stats.unreportedRequests += 1 }
                    if status == "failed" || status == "cancelled" { stats.failedRequests += 1 }
                    if status == "started" { stats.unfinishedRequests += 1 }
                }
                let record = Self.record(row)
                let model = record.usage.reportedModel ?? record.requestedModel
                let groupID = "\(record.providerID ?? "legacy"):\(record.usage.reportedModel != nil):\(model)"
                var group = models[groupID] ?? UsageModelSummary(id: groupID, model: model, providerName: record.providerName,
                    isReportedModel: record.usage.reportedModel != nil, providerID: record.providerID)
                if record.usage.hasCompleteImageTokenCounts {
                    group.completeImageRecords += 1
                    group.imageInputText += record.usage.inputText ?? 0
                    group.imageInputImage += record.usage.inputImage ?? 0
                    group.imageOutputImage += record.usage.outputImage ?? 0
                }
                group.input += i; group.output += o; group.requests += 1
                group.cacheRead += record.usage.cacheRead ?? 0; group.cacheWrite += record.usage.cacheWrite ?? 0
                if input != nil { group.reportedInputRecords += 1 }
                if output != nil { group.reportedOutputRecords += 1 }
                if record.usage.cacheRead != nil { group.reportedCacheReadRecords += 1; stats.reportedCacheReadRecords += 1 }
                if record.usage.cacheWrite != nil { group.reportedCacheWriteRecords += 1; stats.reportedCacheWriteRecords += 1 }
                if record.usage.cacheRead == nil || record.usage.cacheWrite == nil { group.unknownCacheRequests += 1 }
                models[groupID] = group
                stats.totalCacheReadTokens += record.usage.cacheRead ?? 0
                stats.totalCacheWriteTokens += record.usage.cacheWrite ?? 0
                if record.usage.cacheRead == nil || record.usage.cacheWrite == nil { stats.unknownCacheRequests += 1 }
                let key = formatter.string(from: date)
                var day = stats.byDay[key] ?? (input: 0, output: 0, turns: 0)
                day.input += i; day.output += o; day.turns += 1; stats.byDay[key] = day
                // Auxiliary requests without a chat remain visible in the same-space totals.
                let sessionID: String? = row["sessionId"]
                let id = sessionID ?? "auxiliary"
                let title: String? = row["sessionTitle"]
                let previous = sessions[id]
                let inputTokens = (previous?.inputTokens ?? 0) + i
                let outputTokens = (previous?.outputTokens ?? 0) + o
                let turns = (previous?.turns ?? 0) + 1
                let updatedAt = max(previous?.updatedAt ?? date, date)
                sessions[id] = UsageStats.SessionUsage(
                    id: id, title: title ?? "", inputTokens: inputTokens, outputTokens: outputTokens,
                    turns: turns, updatedAt: updatedAt, isDeleted: sessionID != nil && title == nil
                )
            }
            stats.byModel = models.values.sorted { $0.input + $0.output > $1.input + $1.output }
            stats.bySession = sessions.values.sorted { $0.updatedAt > $1.updatedAt }
            return stats
        }
    }

    static func record(_ row: Row) -> ProviderUsageRecord {
        ProviderUsageRecord(id: row["id"], sessionID: row["sessionId"], providerID: row["providerId"], providerName: row["providerName"],
            requestedModel: row["model"], source: row["source"], startedAt: row["startedAt"], finishedAt: row["finishedAt"], status: row["status"],
            usage: .init(input: row["inputTokens"], output: row["outputTokens"], cacheRead: row["cacheReadTokens"], cacheWrite: row["cacheWriteTokens"],
                         ordinaryInput: row["ordinaryInputTokens"], reasoning: row["reasoningTokens"], reportedModel: row["reportedModel"],
                         inputText: row["inputTextTokens"], inputImage: row["inputImageTokens"], outputImage: row["outputImageTokens"]),
            sessionTitle: row.hasColumn("sessionTitle") ? row["sessionTitle"] : nil,
            sessionDeleted: row.hasColumn("sessionTitle") && (row["sessionId"] as String?) != nil && (row["sessionTitle"] as String?) == nil,
            request: (row["requestContextJSON"] as String?).flatMap { try? JSONDecoder().decode(ProviderRequestMetadata.self, from: Data($0.utf8)) })
    }

    private static let costCheckpointKey = "cost-checkpoint"

    /// Reads the baseline and its costs in one transaction. Date filtering affects
    /// consumption only; provider account balances retain their observation time.
    public func costAccounting(prices: [ProductModelPrice], providers: [LLMProviderConfig],
                               in interval: DateInterval? = nil) async throws -> ProductCostAccountingSnapshot {
        try await databaseQueue.read { db in
            let checkpoint = try Self.costCheckpoint(in: db)
            var predicate = Self.predicate(interval: interval, filter: .all)
            if let checkpoint {
                predicate.sql += predicate.sql.isEmpty ? " WHERE " : " AND "
                predicate.sql += "u.startedAt >= ?"
                predicate.arguments += [checkpoint.startedAt]
                if let ids = checkpoint.excludedBoundaryRequestIDs, !ids.isEmpty {
                    predicate.sql += " AND u.id NOT IN (SELECT value FROM json_each(?))"
                    predicate.arguments += [String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)]
                }
            }
            let groups = try Row.fetchAll(db, sql: """
                SELECT u.providerId, COALESCE(u.reportedModel, u.model) AS costModel,
                    COUNT(*) AS records, COUNT(u.inputTokens) AS reportedInput, COUNT(u.outputTokens) AS reportedOutput,
                    SUM(u.inputTokens) AS input, SUM(u.outputTokens) AS output,
                    SUM(u.inputTextTokens) AS inputText, SUM(u.inputImageTokens) AS inputImage, SUM(u.outputImageTokens) AS outputImage,
                    SUM(CASE WHEN u.inputTextTokens >= 0 AND u.inputImageTokens >= 0 AND u.outputImageTokens >= 0
                        AND u.inputTextTokens + u.inputImageTokens = u.inputTokens AND u.outputImageTokens = u.outputTokens THEN 1 ELSE 0 END) AS completeImages
                FROM provider_usage u \(predicate.sql)
                GROUP BY u.providerId, u.reportedModel IS NOT NULL, COALESCE(u.reportedModel, u.model)
                """, arguments: predicate.arguments)
            let configs = providers.reduce(into: [UUID: LLMProviderConfig]()) { $0[$1.id] = $1 }
            var snapshot = ProductCostAccountingSnapshot(checkpoint: checkpoint)
            for group in groups {
                let count: Int = group["records"]
                let rawID: String? = group["providerId"], model: String = group["costModel"]
                snapshot.requests += count
                guard let providerID = rawID.flatMap(UUID.init(uuidString:)),
                      let price = prices.first(where: { $0.providerID == providerID && $0.model == model }),
                      configs[providerID].map({ price.applies(to: $0) }) != false,
                      group["reportedInput"] as Int == count, group["reportedOutput"] as Int == count,
                      let amount = price.estimate(usage: .init(input: group["input"], output: group["output"],
                        inputText: group["completeImages"] as Int == count ? group["inputText"] : nil,
                        inputImage: group["completeImages"] as Int == count ? group["inputImage"] : nil,
                        outputImage: group["completeImages"] as Int == count ? group["outputImage"] : nil)) else {
                    snapshot.unknownGroups += 1; continue
                }
                snapshot.amounts[price.currency, default: 0] += amount
            }
            if checkpoint != nil, snapshot.requests == 0 {
                let currencies = Set(prices.filter { price in configs[price.providerID].map { price.applies(to: $0) } != false }.map(\.currency))
                for currency in currencies.isEmpty ? [ProductModelPrice.defaultCurrency] : currencies.sorted() {
                    snapshot.amounts[currency] = 0
                }
            }
            return snapshot
        }
    }

    /// Both balances and the new start time commit together. Competing windows
    /// cannot silently reset one another, and no usage records are deleted.
    public func recountCosts(balances: [ProductCostBalance], replacing expectedID: UUID?, at date: Date = Date()) async throws -> ProductCostCheckpoint {
        guard date.timeIntervalSince1970.isFinite, balances.allSatisfy(\.isValid), Set(balances.map(\.id)).count == balances.count else {
            throw ProductCostAccountingError.invalidBalance
        }
        try Task.checkCancellation()
        let checkpoint = try await databaseQueue.maintenanceWrite { db in
            guard try Self.costCheckpoint(in: db)?.id == expectedID else { throw ProductCostAccountingError.changed }
            let boundaryIDs = try String.fetchAll(db, sql: "SELECT id FROM provider_usage WHERE startedAt = ?", arguments: [date])
            let value = ProductCostCheckpoint(startedAt: date, balances: balances, excludedBoundaryRequestIDs: boundaryIDs)
            try Self.saveCostCheckpoint(value, in: db)
            return value
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return checkpoint
    }

    /// A balance refresh does not move the spending baseline. A late reply cannot
    /// overwrite balances from a newer lookup or a later recount.
    public func updateCostBalances(_ balances: [ProductCostBalance], checkpointID: UUID) async throws {
        guard balances.allSatisfy(\.isValid), Set(balances.map(\.id)).count == balances.count else {
            throw ProductCostAccountingError.invalidBalance
        }
        try Task.checkCancellation()
        try await databaseQueue.maintenanceWrite { db in
            guard var checkpoint = try Self.costCheckpoint(in: db), checkpoint.id == checkpointID else {
                throw ProductCostAccountingError.changed
            }
            var merged = checkpoint.balances.reduce(into: [String: ProductCostBalance]()) { $0[$1.id] = $1 }
            for (providerID, values) in Dictionary(grouping: balances, by: \.providerID) {
                let incoming = values.map(\.observedAt).min() ?? .distantPast
                let previous = merged.values.filter { $0.providerID == providerID }.map(\.observedAt).max() ?? .distantPast
                guard incoming >= previous else { continue }
                merged = merged.filter { $0.value.providerID != providerID }
                for value in values { merged[value.id] = value }
            }
            checkpoint.balances = merged.values.sorted { $0.id < $1.id }
            try Self.saveCostCheckpoint(checkpoint, in: db)
        }
    }

    private static func costCheckpoint(in db: Database) throws -> ProductCostCheckpoint? {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM product_preferences WHERE key = ?", arguments: [costCheckpointKey]) else { return nil }
        let checkpoint = try JSONDecoder().decode(ProductCostCheckpoint.self, from: data)
        guard checkpoint.startedAt.timeIntervalSince1970.isFinite, checkpoint.balances.allSatisfy(\.isValid),
              Set(checkpoint.balances.map(\.id)).count == checkpoint.balances.count else {
            throw ProductCostAccountingError.invalidBalance
        }
        return checkpoint
    }

    private static func saveCostCheckpoint(_ checkpoint: ProductCostCheckpoint, in db: Database) throws {
        try db.execute(sql: "INSERT INTO product_preferences (key, value, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt",
            arguments: [costCheckpointKey, try JSONEncoder().encode(checkpoint), Date()])
    }

    public func getRecords(in interval: DateInterval? = nil, filter: UsageRequestFilter = .all,
                           before: ProviderUsageRecord? = nil, limit: Int = 50) async throws -> [ProviderUsageRecord] {
        let limit = min(max(limit, 1), 500)
        return try await databaseQueue.read { db in
            var sql = "SELECT u.*, s.title AS sessionTitle FROM provider_usage u LEFT JOIN chat_sessions s ON s.id = u.sessionId"
            let predicate = Self.predicate(interval: interval, filter: filter)
            sql += predicate.sql
            var arguments = predicate.arguments
            if let before {
                sql += predicate.sql.isEmpty ? " WHERE " : " AND "
                sql += "(u.startedAt < ? OR (u.startedAt = ? AND u.id < ?))"
                arguments += [before.startedAt, before.startedAt, before.id]
            }
            sql += " ORDER BY u.startedAt DESC, u.id DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.record)
        }
    }

    private static func predicate(interval: DateInterval?, filter: UsageRequestFilter) -> (sql: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let interval {
            conditions.append("u.startedAt >= ? AND u.startedAt < ?")
            arguments += [interval.start, interval.end]
        }
        switch filter {
        case .all: break
        case .failedOrCancelled: conditions.append("u.status IN ('failed', 'cancelled')")
        case .failed: conditions.append("u.status = 'failed'")
        case .cancelled: conditions.append("u.status = 'cancelled'")
        case .unreported: conditions.append("u.source != 'legacy' AND (u.inputTokens IS NULL OR u.outputTokens IS NULL)")
        case .incompleteCache: conditions.append("(u.cacheReadTokens IS NULL OR u.cacheWriteTokens IS NULL)")
        case .unfinished: conditions.append("u.status = 'started'")
        }
        return (conditions.isEmpty ? "" : " WHERE " + conditions.map { "(\($0))" }.joined(separator: " AND "), arguments)
    }

    public func exportRecords() async throws -> [ProviderUsageRecord] {
        try await databaseQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM provider_usage ORDER BY startedAt, id").map(Self.record)
        }
    }

    public func importRecords(_ records: [ProviderUsageRecord]) async throws {
        try await databaseQueue.maintenanceWrite { db in
            for record in records {
                guard !record.id.isEmpty, record.id.count <= 300,
                      [record.usage.input, record.usage.output, record.usage.cacheRead, record.usage.cacheWrite,
                       record.usage.ordinaryInput, record.usage.reasoning, record.usage.inputText, record.usage.inputImage, record.usage.outputImage].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
                      record.request?.estimate?.isValid != false else {
                    throw LLMError.configurationError(reason: "Invalid usage receipt")
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO provider_usage
                    (id,sessionId,providerId,providerName,model,source,startedAt,finishedAt,status,inputTokens,outputTokens,
                     reportedModel,cacheReadTokens,cacheWriteTokens,ordinaryInputTokens,reasoningTokens,inputTextTokens,inputImageTokens,outputImageTokens,requestContextJSON)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [record.id, record.sessionID, record.providerID, record.providerName, record.requestedModel,
                        record.source, record.startedAt, record.finishedAt, record.status, record.usage.input, record.usage.output,
                        record.usage.reportedModel, record.usage.cacheRead, record.usage.cacheWrite, record.usage.ordinaryInput, record.usage.reasoning, record.usage.inputText, record.usage.inputImage, record.usage.outputImage,
                        try record.request.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }])
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func missingIDs(_ ids: [String]) async throws -> [String] {
        try await databaseQueue.read { db in
            let existing = Set(try String.fetchAll(db, sql: "SELECT id FROM provider_usage"))
            return ids.filter { !existing.contains($0) }
        }
    }

    /// Restore recovery only; ordinary conversation deletion never calls this method.
    func removeRestoredRecords(_ ids: [String]) async throws {
        try await databaseQueue.maintenanceWrite { db in
            for id in ids { try db.execute(sql: "DELETE FROM provider_usage WHERE id = ?", arguments: [id]) }
        }
    }
}
