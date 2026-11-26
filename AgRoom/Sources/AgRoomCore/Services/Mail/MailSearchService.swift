import Foundation
import GRDB

extension MailService {
    static func searchableBody(text: String?, html: String?) -> String {
        guard let readable = MailAIContextService.htmlToText(html), readable != text else { return "" }
        return readable
    }

    static func createSearchSchema(_ db: Database) throws {
        if try !db.columns(in: "mail_bodies").contains(where: { $0.name == "searchText" }) {
            try db.alter(table: "mail_bodies") { $0.add(column: "searchText", .text) }
        }
        // Read one body at a time; a long-lived archive may contain many large originals.
        var after = ""
        while var row = try MailBodyRow.fetchOne(db, sql: "SELECT * FROM mail_bodies WHERE messageId>? ORDER BY messageId LIMIT 1", arguments: [after]) {
            after = row.messageId
            row.searchText = searchableBody(text: row.textBody, html: row.htmlBody)
            try row.update(db)
        }
        try trimBodyCache(in: db, maxBytes: bodyCacheByteLimit)
        try db.create(table: "mail_saved_searches", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("payload", .blob).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    static func validateSearchFilter(_ value: MailListFilter) throws {
        let texts = [value.query, value.sender, value.recipient, value.attachmentName]
        guard texts.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              value.minBytes.map({ $0 >= 0 }) ?? true, value.maxBytes.map({ $0 > 0 }) ?? true,
              value.after.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              value.before.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw MailSearchError.invalidFilter }
        if let lower = value.minBytes, let upper = value.maxBytes, lower > upper { throw MailSearchError.invalidFilter }
        if let after = value.after, let before = value.before, after >= before { throw MailSearchError.invalidFilter }
    }

    public func searchContext(for location: MailQueryLocation) async throws -> (accountID: UUID?, folderID: UUID?) {
        try await databaseQueue.read { db in try Self.searchContext(for: location, db: db) }
    }

    private static func searchContext(for location: MailQueryLocation, db: Database) throws -> (accountID: UUID?, folderID: UUID?) {
        switch location {
        case .space, .inbox: return (nil, nil)
        case .importBatch(let archiveID, let batchID):
            guard try MailAccountRow.fetchOne(db, key: archiveID.uuidString)?.sourceKind == MailAccountSource.localArchive.rawValue,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_import_batches WHERE id=? AND accountID=?)", arguments: [batchID.uuidString, archiveID.uuidString]) == true else { throw MailSearchError.unavailable }
            return (archiveID, nil)
        case .account(let id):
            guard try MailAccountRow.fetchOne(db, key: id.uuidString) != nil else { throw MailSearchError.unavailable }
            return (id, nil)
        case .folder(let id):
            guard let folder = try MailFolderRow.fetchOne(db, key: id.uuidString), !folder.isContainer,
                  let owner = UUID(uuidString: folder.accountId),
                  try MailAccountRow.fetchOne(db, key: owner.uuidString) != nil else { throw MailSearchError.unavailable }
            return (owner, id)
        }
    }

    public func savedSearches() async throws -> [MailSavedSearch] {
        try await databaseQueue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM mail_saved_searches ORDER BY updatedAt DESC,id").map {
                do { return try JSONDecoder().decode(MailSavedSearch.self, from: $0) }
                catch { throw MailSearchError.invalidFilter }
            }
        }
    }

    public func saveSearch(_ value: MailSavedSearch, replacing previous: MailSavedSearch? = nil) async throws {
        var saved = value; saved.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.name.isEmpty, saved.name.utf8.count <= 120,
              saved.name.rangeOfCharacter(from: .controlCharacters) == nil else { throw MailSearchError.invalidName }
        try Self.validateSearchFilter(saved.filter)
        let snapshot = saved
        try await databaseQueue.maintenanceWrite { db in
            if let previous {
                guard previous.id == snapshot.id,
                      let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_saved_searches WHERE id=?", arguments: [previous.id.uuidString]),
                      try JSONDecoder().decode(MailSavedSearch.self, from: data) == previous else { throw MailSearchError.changed }
            }
            if previous?.location != snapshot.location || previous?.filter != snapshot.filter {
                _ = try Self.searchContext(for: snapshot.location, db: db)
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_saved_searches WHERE name=? COLLATE NOCASE AND id<>?)", arguments: [snapshot.name, snapshot.id.uuidString]) != true else { throw MailSearchError.duplicateName }
            let existing = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mail_saved_searches WHERE id=?)", arguments: [snapshot.id.uuidString]) == true
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_saved_searches") ?? 0
            guard existing || count < 100 else { throw MailSearchError.capacity }
            try db.execute(sql: "INSERT INTO mail_saved_searches(id,name,payload,updatedAt) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,payload=excluded.payload,updatedAt=excluded.updatedAt",
                arguments: [snapshot.id.uuidString, snapshot.name, try JSONEncoder().encode(snapshot), snapshot.updatedAt])
        }
    }

    public func deleteSearch(id: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in try db.execute(sql: "DELETE FROM mail_saved_searches WHERE id=?", arguments: [id.uuidString]) }
    }

    public func allFolders() async throws -> [MailFolder] {
        try await databaseQueue.read { db in
            let local = Set(try String.fetchAll(db, sql: "SELECT id FROM mail_accounts WHERE sourceKind=?", arguments: [MailAccountSource.localArchive.rawValue]))
            return try MailFolderRow.order(Column("path")).fetchAll(db).compactMap { row in
                guard var folder = row.toFolder() else { return nil }
                if local.contains(row.accountId) {
                    folder.totalCount = try MailMessageRow.filter(Column("folderId") == row.id).fetchCount(db)
                    folder.unreadCount = try MailMessageRow.filter(Column("folderId") == row.id).filter(Column("isRead") == false).fetchCount(db)
                }
                return folder
            }
        }
    }
}
