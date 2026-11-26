import Foundation
import GRDB

public struct MailConversationCursor: Sendable, Equatable {
    public let date: Date?
    public let id: UUID
    public init(date: Date?, id: UUID) { self.date = date; self.id = id }
}

extension MailService {
    static func installConversationFunction(_ db: Database) {
        db.add(function: DatabaseFunction("mail_thread_tokens", argumentCount: 2, pure: true) { values in
            let own = String.fromDatabaseValue(values[0]), references = String.fromDatabaseValue(values[1])
            return String(decoding: try JSONEncoder().encode(conversationTokens(own: own, references: references)), as: UTF8.self)
        })
        db.add(function: DatabaseFunction("mail_thread_from_raw", argumentCount: 2, pure: true) { values in
            let existing = String.fromDatabaseValue(values[1])
            guard let data = Data.fromDatabaseValue(values[0]) else { return existing }
            return mergeKnownReferences(existing, MailFoundationAdapter.threadReferences(in: data))
        })
    }

    static func mergeKnownReferences(_ existing: String?, _ incoming: String?) -> String? {
        guard let incoming, !incoming.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return incoming }
        let known = Set(conversationTokens(own: nil, references: existing))
        let missing = conversationTokens(own: nil, references: incoming).filter { !known.contains($0) }
        return missing.isEmpty ? existing : existing + " " + missing.map { "<" + $0 + ">" }.joined(separator: " ")
    }

    static func canonicalMessageID(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 1024 else { return nil }
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("<"), !value.contains(">") else { return nil }
        return value
    }

    /// Keep the root and recent ancestors of long References chains, plus the
    /// mail's own identity. No subject-based grouping or wildcard matching.
    static func conversationTokens(own: String?, references: String?) -> [String] {
        let bytes = Array((references ?? "").utf8.prefix(64 * 1024))
        var tokens: [String] = [], start: Int?
        for index in bytes.indices {
            if bytes[index] == 60 { start = index + 1 }
            else if bytes[index] == 62, let from = start {
                if index - from <= 1024, let token = canonicalMessageID(String(decoding: bytes[from..<index], as: UTF8.self)) { tokens.append(token) }
                start = nil
            }
        }
        if tokens.isEmpty, let token = canonicalMessageID(references) { tokens.append(token) }
        if tokens.count > 128 { tokens = [tokens[0]] + Array(tokens.suffix(127)) }
        if let token = canonicalMessageID(own) { tokens.append(token) }
        return Set(tokens).sorted()
    }

    static func createConversationSchema(_ db: Database) throws {
        try db.create(table: "mail_thread_links", ifNotExists: true) { t in
            t.column("messageID", .text).notNull().references("mail_messages", onDelete: .cascade)
            t.column("accountID", .text).notNull()
            t.column("token", .text).notNull()
            t.primaryKey(["messageID", "token"])
        }
        try db.create(index: "mail_thread_token_account", on: "mail_thread_links", columns: ["accountID", "token", "messageID"], options: .ifNotExists)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS mail_thread_insert AFTER INSERT ON mail_messages BEGIN
              INSERT INTO mail_thread_links(messageID,accountID,token)
              SELECT NEW.id,NEW.accountId,value FROM json_each(mail_thread_tokens(NEW.messageId,NEW."references"));
            END;
            CREATE TRIGGER IF NOT EXISTS mail_thread_update AFTER UPDATE OF accountId,messageId,"references" ON mail_messages
            WHEN OLD.accountId IS NOT NEW.accountId OR OLD.messageId IS NOT NEW.messageId OR OLD."references" IS NOT NEW."references" BEGIN
              DELETE FROM mail_thread_links WHERE messageID=OLD.id;
              INSERT INTO mail_thread_links(messageID,accountID,token)
              SELECT NEW.id,NEW.accountId,value FROM json_each(mail_thread_tokens(NEW.messageId,NEW."references"));
            END;
            CREATE TRIGGER IF NOT EXISTS mail_thread_raw_insert AFTER INSERT ON mail_raw_messages BEGIN
              UPDATE mail_messages SET "references"=mail_thread_from_raw(substr(NEW.data,1,262144),"references") WHERE id=NEW.messageID;
            END;
            CREATE TRIGGER IF NOT EXISTS mail_thread_raw_update AFTER UPDATE OF data ON mail_raw_messages BEGIN
              UPDATE mail_messages SET "references"=mail_thread_from_raw(substr(NEW.data,1,262144),"references") WHERE id=NEW.messageID;
            END;
            UPDATE mail_messages SET "references"=mail_thread_from_raw((SELECT substr(data,1,262144) FROM mail_raw_messages r WHERE r.messageID=mail_messages.id),"references")
            WHERE EXISTS(SELECT 1 FROM mail_raw_messages r WHERE r.messageID=mail_messages.id);
            INSERT OR IGNORE INTO mail_thread_links(messageID,accountID,token)
            SELECT m.id,m.accountId,t.value FROM mail_messages m,json_each(mail_thread_tokens(m.messageId,m."references")) t;
            """)
    }

    /// A transitive connected component of exact header identities, in this
    /// account and space. The final metadata result uses chronological keyset paging.
    public func conversationMessages(accountID: UUID, anchorID: UUID, after cursor: MailConversationCursor? = nil,
                                     limit: Int = 50, excludingAnchor: Bool = false) async throws -> [MailMessage] {
        guard limit > 0 else { return [] }
        return try await databaseQueue.read { db in
            guard let anchor = try MailMessageRow.fetchOne(db, key: anchorID.uuidString), anchor.accountId == accountID.uuidString else { throw MailSearchError.unavailable }
            var args: [DatabaseValueConvertible?] = [anchorID.uuidString, accountID.uuidString]
            var condition = excludingAnchor ? " AND m.id<>?" : ""
            if excludingAnchor { args.append(anchorID.uuidString) }
            if let cursor {
                if let date = cursor.date { condition += " AND (m.date>? OR (m.date=? AND m.id>?))"; args += [date, date, cursor.id.uuidString] }
                else { condition += " AND (m.date IS NOT NULL OR (m.date IS NULL AND m.id>?))"; args.append(cursor.id.uuidString) }
            }
            args.append(limit)
            return try MailMessageRow.fetchAll(db, sql: """
                WITH RECURSIVE component(id) AS (
                  VALUES(?)
                  UNION
                  SELECT target.messageID FROM component c
                  JOIN mail_thread_links source ON source.messageID=c.id
                  JOIN mail_thread_links target ON target.accountID=source.accountID AND target.token=source.token
                  WHERE target.accountID=?
                )
                SELECT m.* FROM mail_messages m JOIN component c ON c.id=m.id
                WHERE 1=1 \(condition) ORDER BY m.date ASC,m.id ASC LIMIT ?
                """, arguments: StatementArguments(args)).compactMap { $0.toMessage() }
        }
    }
}
