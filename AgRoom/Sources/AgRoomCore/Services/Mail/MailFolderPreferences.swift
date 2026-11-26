import Foundation
import GRDB

public struct MailFolderPreference: Sendable, Equatable {
    public let folderID: UUID
    public let isFavorite: Bool
    public let lastMovedAt: Date?
    public var isHidden: Bool = false
}

extension MailService {
    static func createFolderPreferenceSchema(_ db: Database) throws {
        try db.create(table: "mail_folder_preferences", ifNotExists: true) { t in
            t.column("folderID", .text).primaryKey().references("mail_folders", onDelete: .cascade)
            t.column("isFavorite", .boolean).notNull().defaults(to: false)
            t.column("lastMovedAt", .datetime)
        }
    }

    static func addFolderVisibilitySchema(_ db: Database) throws {
        if try !db.columns(in: "mail_folder_preferences").contains(where: { $0.name == "isHidden" }) {
            try db.alter(table: "mail_folder_preferences") { $0.add(column: "isHidden", .boolean).notNull().defaults(to: false) }
        }
    }

    public func folderPreferences() async throws -> [MailFolderPreference] {
        try await databaseQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT folderID,isFavorite,lastMovedAt,isHidden FROM mail_folder_preferences ORDER BY folderID").map { row in
                guard let id = UUID(uuidString: row["folderID"]) else { throw MailSearchError.unavailable }
                return .init(folderID: id, isFavorite: row["isFavorite"], lastMovedAt: row["lastMovedAt"], isHidden: row["isHidden"])
            }
        }
    }

    /// Favorites refer to a folder in this service's database, never a global path.
    public func setFolderFavorite(_ favorite: Bool, folderID: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard let folder = try MailFolderRow.fetchOne(db, key: folderID.uuidString), !folder.isContainer else { throw MailSyncError.folderNotFound }
            try db.execute(sql: "INSERT INTO mail_folder_preferences(folderID,isFavorite) VALUES(?,?) ON CONFLICT(folderID) DO UPDATE SET isFavorite=excluded.isFavorite", arguments: [folderID.uuidString, favorite])
            try db.execute(sql: "DELETE FROM mail_folder_preferences WHERE folderID=? AND isFavorite=0 AND lastMovedAt IS NULL AND isHidden=0", arguments: [folderID.uuidString])
        }
    }

    /// Sidebar visibility only. Hiding a container is allowed and never changes mail or sync coverage.
    public func setFolderHidden(_ hidden: Bool, folderID: UUID) async throws {
        try await databaseQueue.maintenanceWrite { db in
            guard try MailFolderRow.fetchOne(db, key: folderID.uuidString) != nil else { throw MailSyncError.folderNotFound }
            try db.execute(sql: "INSERT INTO mail_folder_preferences(folderID,isHidden) VALUES(?,?) ON CONFLICT(folderID) DO UPDATE SET isHidden=excluded.isHidden", arguments: [folderID.uuidString, hidden])
            try db.execute(sql: "DELETE FROM mail_folder_preferences WHERE folderID=? AND isFavorite=0 AND lastMovedAt IS NULL AND isHidden=0", arguments: [folderID.uuidString])
        }
    }

    /// Call only after an explicitly chosen destination has a successful move receipt.
    public func recordMoveDestination(_ folderID: UUID, at date: Date = Date()) async throws {
        guard date.timeIntervalSince1970.isFinite else { throw MailSearchError.invalidFilter }
        try await databaseQueue.maintenanceWrite { db in
            guard let folder = try MailFolderRow.fetchOne(db, key: folderID.uuidString), !folder.isContainer else { throw MailSyncError.folderNotFound }
            try db.execute(sql: "INSERT INTO mail_folder_preferences(folderID,isFavorite,lastMovedAt) VALUES(?,0,?) ON CONFLICT(folderID) DO UPDATE SET lastMovedAt=CASE WHEN lastMovedAt IS NULL OR lastMovedAt<excluded.lastMovedAt THEN excluded.lastMovedAt ELSE lastMovedAt END", arguments: [folderID.uuidString, date])
            // Keep a bounded recent list per account while preserving every favorite.
            try db.execute(sql: "UPDATE mail_folder_preferences SET lastMovedAt=NULL WHERE folderID IN (SELECT p.folderID FROM mail_folder_preferences p JOIN mail_folders f ON f.id=p.folderID WHERE f.accountId=? AND p.lastMovedAt IS NOT NULL ORDER BY p.lastMovedAt DESC,p.folderID LIMIT -1 OFFSET 10)", arguments: [folder.accountId])
            try db.execute(sql: "DELETE FROM mail_folder_preferences WHERE isFavorite=0 AND lastMovedAt IS NULL AND isHidden=0")
        }
    }
}
