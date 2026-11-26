import CryptoKit
import Darwin
import Foundation
import GRDB
import SQLite3
import Synchronization

public enum SpaceSearchKind: String, CaseIterable, Codable, Sendable {
    case conversation, knowledge, memory, agent, skill, app, mail, artifact, task, team, scheduled, job
}

public enum SpaceSearchError: String, Error, Sendable {
    case unavailable, timedOut, changed, missing, invalidScope
}

public struct SpaceSearchHit: Identifiable, Equatable, Sendable {
    public let space: AppSpace
    public let kind: SpaceSearchKind
    public let sourceID: String
    public var id: String { kind.rawValue + ":" + sourceID }
    public let title: String
    public let snippet: String
    public let modifiedAt: Date
    public let parentID: String?
    public let secondaryID: String?
    public let isEnabled: Bool
    public let query: String
    public let rank: Int
}

public struct SpaceSearchPage: Sendable {
    public let hits: [SpaceSearchHit]
    public let hasMore: Bool
    public let unavailableSources: Set<SpaceSearchKind>
}

public struct SpaceSearchPreview: Sendable {
    public let hit: SpaceSearchHit
    public let content: String
    public let truncated: Bool
    public let revision: String
    public var canQuote: Bool { hit.kind != .artifact && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Read-only search of one physical space. Catalogs use that space's actual
/// packages, never the legacy skills table or another space's service.
public struct SpaceSearchService: Sendable {
    public let space: AppSpace
    private let queue: DatabaseQueue
    private let catalogDirectory: URL?
    private let timeout: TimeInterval

    public init(databaseQueue: DatabaseQueue, space: AppSpace, catalogDirectory: URL? = nil) {
        self.init(databaseQueue: databaseQueue, space: space, catalogDirectory: catalogDirectory, timeout: 3)
    }
    init(databaseQueue: DatabaseQueue, space: AppSpace, catalogDirectory: URL? = nil, timeout: TimeInterval) {
        queue = databaseQueue; self.space = space; self.catalogDirectory = catalogDirectory; self.timeout = timeout
    }

    public func search(_ rawQuery: String, kind: SpaceSearchKind? = nil, before: SpaceSearchHit? = nil,
                       limit: Int = 40, includeHidden: Bool = false, language: String = "en") async throws -> SpaceSearchPage {
        let query = String(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard before == nil || (before?.space == space && before?.query == query && (kind == nil || before?.kind == kind)) else { throw SpaceSearchError.invalidScope }
        guard !query.isEmpty else { return .init(hits: [], hasMore: false, unavailableSources: []) }
        try Task.checkCancellation()
        let count = min(100, max(1, limit))
        let database = try await databaseHits(query, kind: kind, before: before, limit: count + 1, includeHidden: includeHidden)
        let catalog = try await catalogs(kind: kind, language: language)
        try Task.checkCancellation()
        let extra = catalog.documents.compactMap { document -> SpaceSearchHit? in
            guard matches(document, query: query) else { return nil }
            let hit = makeHit(document, query: query)
            if let before, !Self.precedes(before, hit) { return nil }
            return hit
        }
        let combined = (database + extra).sorted(by: Self.precedes)
        return .init(hits: Array(combined.prefix(count)), hasMore: combined.count > count, unavailableSources: catalog.unavailable)
    }

    public func preview(_ hit: SpaceSearchHit, includeHidden: Bool = false, language: String = "en") async throws -> SpaceSearchPreview {
        guard hit.space == space else { throw SpaceSearchError.invalidScope }
        try Task.checkCancellation()
        let document: Document
        if hit.kind == .skill || hit.kind == .app {
            let values = try await catalogs(kind: hit.kind, language: language, selectedID: hit.sourceID)
            guard let value = values.documents.first(where: { $0.id == hit.sourceID }) else {
                throw values.unavailable.isEmpty ? SpaceSearchError.missing : .unavailable
            }
            document = value
        } else {
            let checkpoint = Checkpoint(timeout: timeout)
            document = try await withTaskCancellationHandler {
                try await queue.read { db in
                    try Self.withDeadline(db, checkpoint: checkpoint) {
                        let spec = Self.specification(hit.kind, includeHidden: includeHidden)
                        let rows = try Row.fetchAll(db, sql: """
                            WITH source AS (\(spec))
                            SELECT kind,id,substr(title,1,240) AS title,
                              substr(body,max(1,instr(lower(body),lower(?))-1000),12001) AS body,
                              length(body)>12000 AS isExcerpt,modifiedAt,parentID,secondaryID,isEnabled
                            FROM source WHERE id=? AND (? IS NULL OR parentID=?) LIMIT 1
                            """, arguments: [hit.query, hit.sourceID, hit.parentID, hit.parentID])
                        guard let row = rows.first else { throw SpaceSearchError.missing }
                        return try Self.document(row, excerpt: row["isExcerpt"])
                    }
                }
            } onCancel: { checkpoint.cancelled.withLock { $0 = true } }
        }
        try Task.checkCancellation()
        let content = String(document.body.prefix(12_000))
        let resolved = makeHit(document, query: hit.query)
        let stamp = [resolved.id, document.title, content, String(document.modifiedAt.timeIntervalSince1970)]
        let data = try JSONEncoder().encode(stamp)
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(hit: resolved, content: content, truncated: document.truncated || document.body.count > 12_000, revision: revision)
    }

    /// Verify the exact excerpt the user inspected before adding it to a draft.
    public func reference(_ inspected: SpaceSearchPreview, includeHidden: Bool = false, language: String = "en") async throws -> SpaceSearchPreview {
        let current = try await preview(inspected.hit, includeHidden: includeHidden, language: language)
        guard current.revision == inspected.revision else { throw SpaceSearchError.changed }
        return current
    }

    private struct Document: Sendable {
        let kind: SpaceSearchKind
        let id: String
        let title: String
        let body: String
        let modifiedAt: Date
        var parentID: String? = nil
        var secondaryID: String? = nil
        var isEnabled = true
        var truncated = false
    }
    private struct Catalog: Sendable {
        var documents: [Document] = []
        var unavailable: Set<SpaceSearchKind> = []
    }
    private final class Checkpoint: Sendable {
        let cancelled = Mutex(false)
        let end: TimeInterval
        init(timeout: TimeInterval) { end = ProcessInfo.processInfo.systemUptime + timeout }
    }

    private static func withDeadline<T>(_ db: Database, checkpoint: Checkpoint, _ body: () throws -> T) throws -> T {
        if checkpoint.cancelled.withLock({ $0 }) { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < checkpoint.end else { throw SpaceSearchError.timedOut }
        sqlite3_progress_handler(db.sqliteConnection, 1_000, { pointer in
            guard let pointer else { return 1 }
            let value = Unmanaged<Checkpoint>.fromOpaque(pointer).takeUnretainedValue()
            return value.cancelled.withLock({ $0 }) || ProcessInfo.processInfo.systemUptime >= value.end ? 1 : 0
        }, Unmanaged.passUnretained(checkpoint).toOpaque())
        defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil); withExtendedLifetime(checkpoint) {} }
        do {
            let result = try body()
            if checkpoint.cancelled.withLock({ $0 }) { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < checkpoint.end else { throw SpaceSearchError.timedOut }
            return result
        }
        catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            if checkpoint.cancelled.withLock({ $0 }) { throw CancellationError() }
            throw SpaceSearchError.timedOut
        }
    }

    private func databaseHits(_ query: String, kind: SpaceSearchKind?, before: SpaceSearchHit?, limit: Int, includeHidden: Bool) async throws -> [SpaceSearchHit] {
        let kinds = SpaceSearchKind.allCases.filter { $0 != .skill && $0 != .app && (kind == nil || kind == $0) }
        guard !kinds.isEmpty else { return [] }
        let sql = kinds.map { Self.specification($0, includeHidden: includeHidden) }.joined(separator: " UNION ALL ")
        let checkpoint = Checkpoint(timeout: timeout), space = space
        return try await withTaskCancellationHandler {
            try await queue.read { db in
                try Self.withDeadline(db, checkpoint: checkpoint) {
                    var arguments: [DatabaseValue] = [query.databaseValue]
                    var cursor = ""
                    if let before {
                        cursor = "WHERE rank < ? OR (rank=? AND (modifiedAt < ? OR (modifiedAt=? AND itemKey > ?)))"
                        arguments += [before.rank.databaseValue, before.rank.databaseValue, before.modifiedAt.databaseValue,
                            before.modifiedAt.databaseValue, before.id.databaseValue]
                    }
                    arguments.append(limit.databaseValue)
                    return try Row.fetchAll(db, sql: """
                        WITH needle(q) AS (VALUES(?)), source AS (\(sql)), matches AS (
                          SELECT kind,id,substr(title,1,240) AS title,
                            substr(body,max(1,instr(lower(body),lower(q))-100),480) AS snippet,
                            modifiedAt,parentID,secondaryID,isEnabled,kind || ':' || id AS itemKey,
                            CASE WHEN lower(title)=lower(q) THEN 3 WHEN instr(lower(title),lower(q))=1 THEN 2
                              WHEN instr(lower(title),lower(q))>0 THEN 1 ELSE 0 END AS rank
                          FROM source,needle WHERE instr(lower(title),lower(q))>0 OR instr(lower(body),lower(q))>0
                        ) SELECT * FROM matches \(cursor) ORDER BY rank DESC,modifiedAt DESC,itemKey ASC LIMIT ?
                        """, arguments: StatementArguments(arguments)).map { row in
                            let document = try Self.document(row, body: "snippet")
                            return SpaceSearchHit(space: space, kind: document.kind, sourceID: document.id, title: document.title,
                                snippet: document.body, modifiedAt: document.modifiedAt, parentID: document.parentID,
                                secondaryID: document.secondaryID, isEnabled: document.isEnabled, query: query, rank: row["rank"])
                        }
                }
            }
        } onCancel: { checkpoint.cancelled.withLock { $0 = true } }
    }

    private static func document(_ row: Row, body: String = "body", excerpt: Bool = false) throws -> Document {
        guard let kind = SpaceSearchKind(rawValue: row["kind"]), let id: String = row["id"], !id.isEmpty,
              let date: Date = row["modifiedAt"] else { throw SpaceSearchError.unavailable }
        return .init(kind: kind, id: id, title: row["title"], body: row[body], modifiedAt: date,
            parentID: row["parentID"], secondaryID: row["secondaryID"], isEnabled: row["isEnabled"], truncated: excerpt)
    }

    private func makeHit(_ document: Document, query: String) -> SpaceSearchHit {
        let rank = document.title.caseInsensitiveCompare(query) == .orderedSame ? 3 :
            (document.title.lowercased().hasPrefix(query.lowercased()) ? 2 : (document.title.localizedCaseInsensitiveContains(query) ? 1 : 0))
        let range = document.body.range(of: query, options: .caseInsensitive)
        let start = range.map { document.body.index($0.lowerBound, offsetBy: -100, limitedBy: document.body.startIndex) ?? document.body.startIndex } ?? document.body.startIndex
        return .init(space: space, kind: document.kind, sourceID: document.id, title: String(document.title.prefix(240)),
            snippet: String(document.body[start...].prefix(480)), modifiedAt: Date.fromDatabaseValue(document.modifiedAt.databaseValue) ?? document.modifiedAt, parentID: document.parentID,
            secondaryID: document.secondaryID, isEnabled: document.isEnabled, query: query, rank: rank)
    }
    private func matches(_ document: Document, query: String) -> Bool {
        document.title.localizedCaseInsensitiveContains(query) || document.body.localizedCaseInsensitiveContains(query)
    }
    private static func precedes(_ lhs: SpaceSearchHit, _ rhs: SpaceSearchHit) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.id < rhs.id
    }

    private static func specification(_ kind: SpaceSearchKind, includeHidden: Bool) -> String {
        let visible = includeHidden ? "1" : "COALESCE(s.isHidden,0)=0"
        func select(_ id: String, _ title: String, _ body: String, _ date: String, from: String,
                    parent: String = "NULL", secondary: String = "NULL", enabled: String = "1", condition: String = "1") -> String {
            "SELECT '\(kind.rawValue)' AS kind,\(id) AS id,\(title) AS title,COALESCE(\(body),'') AS body,\(date) AS modifiedAt,\(parent) AS parentID,\(secondary) AS secondaryID,\(enabled) AS isEnabled FROM \(from) WHERE \(condition)"
        }
        switch kind {
        case .conversation:
            return select("CASE WHEN json_valid(m.payload) THEN json_extract(m.payload,'$.id') END", "s.title", "CASE WHEN json_valid(m.payload) THEN json_extract(m.payload,'$.content') END", "s.updatedAt",
                from: "chat_messages m JOIN chat_sessions s ON s.id=m.sessionId", parent: "s.id",
                condition: "\(visible) AND json_valid(m.payload) AND CASE WHEN json_valid(m.payload) THEN json_extract(m.payload,'$.id') END IS NOT NULL")
        case .knowledge:
            return select("id", "title", "content", "updatedAt", from: "knowledge_items", parent: "baseId", secondary: "folderId")
        case .memory:
            return select("id", "substr(content,1,80)", "content", "createdAt", from: "memories", enabled: "isEnabled")
        case .agent:
            return select("id", "CASE WHEN nickname<>'' THEN nickname ELSE name END", "name || char(10) || description", "updatedAt", from: "agents", enabled: "isEnabled")
        case .mail:
            return select("m.id", "m.subject", "m.fromName || ' ' || m.fromAddress || char(10) || m.snippet || char(10) || COALESCE(b.textBody,'')",
                "COALESCE(m.date,'1970-01-01 00:00:00.000')", from: "mail_messages m LEFT JOIN mail_bodies b ON b.messageId=m.id", parent: "m.accountId", secondary: "m.folderId")
        case .artifact:
            return select("a.id", "a.logicalPath", "a.path", "a.createdAt", from: "artifact_versions a LEFT JOIN chat_sessions s ON s.id=a.sessionID",
                parent: "a.runID", secondary: "a.sessionID", condition: visible)
        case .task:
            return select("r.id", "r.title", "CASE WHEN json_valid(CAST(r.payload AS TEXT)) THEN COALESCE(json_extract(CAST(r.payload AS TEXT),'$.prompt'),'') || char(10) || COALESCE(json_extract(CAST(r.payload AS TEXT),'$.answer'),'') ELSE r.preview END", "r.startedAt", from: "product_task_runs r LEFT JOIN chat_sessions s ON s.id=r.sessionID",
                parent: "r.sessionID", secondary: "r.messageID", condition: visible)
        case .team:
            return select("id", "goal", "CASE WHEN json_valid(reportJSON) THEN COALESCE(json_extract(reportJSON,'$.verification.summary'),'') || char(10) || COALESCE((SELECT group_concat(json_extract(value,'$.summary'),char(10)) FROM json_each(reportJSON,'$.subtasks') WHERE type='object'),'') || char(10) || COALESCE((SELECT group_concat(value,char(10)) FROM json_each(reportJSON,'$.errors') WHERE type='text'),'') || char(10) || COALESCE((SELECT group_concat(value,char(10)) FROM json_each(reportJSON,'$.openQuestions') WHERE type='text'),'') ELSE '' END", "startedAt", from: "team_tasks")
        case .scheduled:
            return select("id", "taskName", "COALESCE(outputText,'') || char(10) || COALESCE(errorText,'') || char(10) || COALESCE(summary,'')", "COALESCE(startedAt,scheduledFor,finishedAt,'1970-01-01 00:00:00.000')", from: "scheduled_runs", parent: "taskID")
        case .job:
            return select("id", "title", "CASE WHEN json_valid(CAST(payload AS TEXT)) THEN COALESCE(json_extract(CAST(payload AS TEXT),'$.resultText'),'') || char(10) || COALESCE(json_extract(CAST(payload AS TEXT),'$.errorText'),'') ELSE preview END", "startedAt", from: "product_job_runs", parent: "origin")
        case .skill, .app: return ""
        }
    }

    private func catalogs(kind: SpaceSearchKind?, language: String, selectedID: String? = nil) async throws -> Catalog {
        guard kind == nil || kind == .skill || kind == .app else { return Catalog() }
        guard let root = catalogDirectory else { return Catalog(unavailable: Set(kind.map { [$0] } ?? [.skill, .app])) }
        guard root.lastPathComponent == space.rawValue else { throw SpaceSearchError.invalidScope }
        let task = Task.detached { () async throws -> Catalog in
            var result = Catalog()
            if kind == nil || kind == .skill {
                do {
                    let directory = try AppDirectory(url: root.appendingPathComponent("skills"), create: false)
                    let names = try directory.names(limit: 1_024).filter { $0.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil }.sorted()
                    var bytes = 0
                    for name in names where selectedID == nil || selectedID == name {
                        try Task.checkCancellation()
                        do {
                            let folder = try directory.child(name, create: false)
                            guard folder.exists("SKILL.md") else { continue }
                            let data = try folder.read("SKILL.md", limit: SkillStore.maxFileBytes)
                            bytes += data.count
                            guard bytes <= 8 * 1024 * 1024 else { result.unavailable.insert(.skill); break }
                            guard let text = String(data: data, encoding: .utf8) else { throw SpaceSearchError.unavailable }
                            let skill = try SkillDocument.parse(text)
                            var info = stat()
                            guard fstatat(folder.fd, "SKILL.md", &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SpaceSearchError.unavailable }
                            let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                            let body = selectedID == nil ? name + "\n" + skill.description : skill.description + "\n\n" + skill.content
                            result.documents.append(.init(kind: .skill, id: name, title: skill.displayName, body: body,
                                modifiedAt: date, isEnabled: !folder.exists(SkillStore.disabledMarker)))
                        } catch is CancellationError { throw CancellationError() }
                        catch { result.unavailable.insert(.skill) }
                    }
                } catch let error as NativeAppError where error.code == .missing {}
                catch is CancellationError { throw CancellationError() }
                catch { result.unavailable.insert(.skill) }
            }
            if kind == nil || kind == .app {
                do {
                    let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: space)
                    let catalog = try await store.catalog()
                    if !catalog.invalidIDs.isEmpty { result.unavailable.insert(.app) }
                    for app in catalog.apps where selectedID == nil || selectedID == app.id {
                        try Task.checkCancellation()
                        result.documents.append(.init(kind: .app, id: app.id, title: app.name(language: language),
                            body: app.names.values.sorted().joined(separator: " ") + "\n" + app.summary(language: language),
                            modifiedAt: Date(timeIntervalSince1970: Double(app.version))))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { result.unavailable.insert(.app) }
            }
            return result
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
