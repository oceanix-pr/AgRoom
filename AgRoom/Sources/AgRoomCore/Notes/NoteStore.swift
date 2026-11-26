import Foundation
import GRDB

public struct NoteTodo: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var completed = false
    public var dueDate: Date?
    public var reminderID: String?
    public var notes: String?
    public var owner: String?
    public var priority: Int?
    public var url: String?
    public var alarmOffsetMinutes: Int?
    public var evidenceQuote: String?
    public var sourceTimestamp: Double?
    public init(title: String) { self.title = title }
}

public struct NoteSegment: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var timestamp: TimeInterval
    public var endTimestamp: TimeInterval?
    public var speaker: String
    public var text: String
    public init(timestamp: TimeInterval, endTimestamp: TimeInterval? = nil, speaker: String = "", text: String) {
        self.timestamp = timestamp; self.endTimestamp = endTimestamp; self.speaker = speaker; self.text = text
    }
}

public struct NoteSummary: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var text: String
    public init(text: String) { self.text = text }
}

/// Private note content belongs exclusively to the database passed to NoteStore.
public struct WorkNote: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var revision = 0
    public var versionToken: UUID? = UUID()
    public var title: String
    public var text = ""
    public var transcript = ""
    public var visualNotes: String?
    public var visualMediaID: UUID?
    public var segments: [NoteSegment] = []
    public var summaries: [NoteSummary] = []
    public var todos: [NoteTodo] = []
    public var tags = ""
    public var archived = false
    public var pinned = false
    public var createdAt = Date()
    public var updatedAt = Date()
    public init(title: String) { self.title = title }
    public var searchText: String { ([title, text, transcript, visualNotes ?? "", tags] + summaries.map(\.text) + todos.flatMap { [$0.title, $0.owner ?? "", $0.notes ?? "", $0.evidenceQuote ?? ""] }).joined(separator: "\n") }
    public var sourceText: String { [text, transcript, visualNotes ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n") }
    public var markdown: String {
        var parts = ["# " + title, text, transcript, visualNotes ?? ""]
        parts += summaries.suffix(1).map(\.text)
        parts += todos.map { todo in
            (["- [\(todo.completed ? "x" : " ")] \(todo.title)"] + [todo.owner, todo.notes, todo.url, todo.evidenceQuote].compactMap { $0 }.map { "  " + $0 }).joined(separator: "\n")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public struct NoteMedia: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let byteCount: Int
}

public enum NoteStoreError: Error, Sendable, Equatable { case conflict, invalidContent, tooLarge, missing }

/// JSON text plus media bytes are committed transactionally and included in space backups.
/// No paths from a note or imported archive are ever used as filesystem authority.
public final class NoteStore: Sendable {
    public static let maximumMediaBytes = 128 * 1024 * 1024
    public static let maximumContentBytes = 4 * 1024 * 1024
    public static let maximumFileBytes = 64 * 1024 * 1024 * 1024
    let queue: DatabaseQueue
    public var isInMemory: Bool { queue.path == ":memory:" }
    let cipher: NoteContentCipher
    public init(databaseQueue: DatabaseQueue, cipher: NoteContentCipher = .plaintext) { queue = databaseQueue; self.cipher = cipher }

    static func createSchema(_ db: Database) throws {
        try db.create(table: "notes", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("revision", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("searchText", .text).notNull()
            t.column("archived", .boolean).notNull()
            t.column("pinned", .boolean).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("contents", .blob).notNull()
        }
        try db.create(table: "note_media", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("noteID", .text).notNull().references("notes", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("contents", .blob).notNull()
        }
        try db.create(index: "notes_order", on: "notes", columns: ["archived", "pinned", "updatedAt"], ifNotExists: true)
    }

    public func storageSummary() async throws -> (notes: Int, media: Int, bytes: Int64) {
        try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM note_media") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT (SELECT coalesce(sum(length(contents)),0) FROM notes) + (SELECT coalesce(sum(coalesce(byteCount,length(contents))),0) FROM note_media WHERE isReady = 1)") ?? 0)
        }
    }

    public func get(id: UUID) async throws -> WorkNote? {
        try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT contents FROM notes WHERE id = ?", arguments: [id.uuidString]).map { try cipher.decode(WorkNote.self, from: $0, table: "notes") }
        }
    }

    public struct PageCursor: Sendable, Equatable {
        let pinned: Bool
        // Keep the exact SQLite sort value, including its persisted timestamp precision.
        let updatedAt: String
        let id: String
    }

    public struct Page: Sendable {
        public let notes: [WorkNote]
        public let next: PageCursor?
    }

    public func page(search: String = "", archived: Bool = false, after: PageCursor? = nil) async throws -> Page {
        try await readPage(search: search, archived: archived, after: after, offset: 0)
    }

    public func list(search: String = "", archived: Bool = false, offset: Int = 0) async throws -> [WorkNote] {
        try await readPage(search: search, archived: archived, after: nil, offset: max(0, offset)).notes
    }

    private func readPage(search: String, archived: Bool, after: PageCursor?, offset: Int) async throws -> Page {
        try await queue.read { db in
            var sql = "SELECT id, pinned, updatedAt, contents FROM notes WHERE archived = ? AND NOT EXISTS (SELECT 1 FROM note_import_staging WHERE noteID = notes.id)"
            var args: StatementArguments = [archived]
            if let after {
                sql += " AND (pinned < ? OR (pinned = ? AND (updatedAt < ? OR (updatedAt = ? AND id > ?))))"
                args += [after.pinned, after.pinned, after.updatedAt, after.updatedAt, after.id]
            }
            let decryptToMatch = cipher.enabled && !search.isEmpty
            if !cipher.enabled && !search.isEmpty {
                sql += " AND instr(lower(searchText), lower(?)) > 0"
                args += [search]
            }
            sql += " ORDER BY pinned DESC, updatedAt DESC, id"
            var skip = decryptToMatch ? offset : 0
            if !decryptToMatch {
                sql += " LIMIT 101 OFFSET ?"
                args += [offset]
            }
            var notes: [WorkNote] = [], last: PageCursor?
            let rows = try Row.fetchCursor(db, sql: sql, arguments: args)
            while let row = try rows.next() {
                try Task.checkCancellation()
                let note = try cipher.decode(WorkNote.self, from: row["contents"], table: "notes")
                if !decryptToMatch || note.searchText.localizedCaseInsensitiveContains(search) {
                    if notes.count == 100 { return Page(notes: notes, next: last) }
                    if skip > 0 { skip -= 1 } else { notes.append(note) }
                }
                // Resume past nonmatches already inspected while looking for the next matching row.
                last = PageCursor(pinned: row["pinned"], updatedAt: row["updatedAt"], id: row["id"])
            }
            return Page(notes: notes, next: nil)
        }
    }

    @discardableResult
    public func save(_ note: WorkNote) async throws -> WorkNote {
        var next = note
        next.revision += 1; next.updatedAt = Date(); next.versionToken = UUID()
        guard !next.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              next.summaries.count <= 100, next.todos.count <= 1000 else { throw NoteStoreError.invalidContent }
        let plain = try JSONEncoder().encode(next)
        guard plain.count <= Self.maximumContentBytes else { throw NoteStoreError.tooLarge }
        let data = try cipher.seal(plain, table: "notes")
        let frozen = next
        try await queue.maintenanceWrite { db in
            if let row = try Row.fetchOne(db, sql: "SELECT revision, contents FROM notes WHERE id = ?", arguments: [note.id.uuidString]) {
                let current = try cipher.decode(WorkNote.self, from: row["contents"], table: "notes")
                guard current.revision == note.revision, current.versionToken == note.versionToken else { throw NoteStoreError.conflict }
            } else if note.revision != 0 { throw NoteStoreError.conflict }
            try db.execute(sql: "INSERT INTO notes (id, revision, title, searchText, archived, pinned, updatedAt, contents) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, title=excluded.title, searchText=excluded.searchText, archived=excluded.archived, pinned=excluded.pinned, updatedAt=excluded.updatedAt, contents=excluded.contents", arguments: [frozen.id.uuidString, frozen.revision, cipher.enabled ? "" : frozen.title, cipher.enabled ? "" : frozen.searchText, frozen.archived, frozen.pinned, frozen.updatedAt, data])
        }
        return frozen
    }

    public func delete(_ note: WorkNote) async throws {
        try await queue.maintenanceWrite { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT contents FROM notes WHERE id = ?", arguments: [note.id.uuidString]),
                  try cipher.decode(WorkNote.self, from: data, table: "notes").versionToken == note.versionToken else { throw NoteStoreError.conflict }
            try db.execute(sql: "DELETE FROM notes WHERE id = ? AND revision = ?", arguments: [note.id.uuidString, note.revision])
            guard db.changesCount == 1 else { throw NoteStoreError.conflict }
        }
    }

    public func media(noteID: UUID) async throws -> [NoteMedia] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, coalesce(byteCount, length(contents)) AS size FROM note_media WHERE noteID = ? AND isReady = 1 AND sourceRemoved = 0 ORDER BY name, id", arguments: [noteID.uuidString]).map { row in
                guard let id = UUID(uuidString: row["id"]) else { throw NoteStoreError.invalidContent }
                return NoteMedia(id: id, name: row["name"], byteCount: row["size"])
            }
        }
    }

    public func addMedia(id: UUID = UUID(), noteID: UUID, name: String, data: Data) async throws {
        guard !data.isEmpty, data.count <= Self.maximumMediaBytes else { throw NoteStoreError.tooLarge }
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty else { throw NoteStoreError.invalidContent }
        try await queue.maintenanceWrite { db in
            if let row = try Row.fetchOne(db, sql: "SELECT noteID, name, contents FROM note_media WHERE id = ?", arguments: [id.uuidString]) {
                guard row["noteID"] as String == noteID.uuidString, row["name"] as String == safeName, row["contents"] as Data == data else { throw NoteStoreError.conflict }
                return
            }
            try db.execute(sql: "INSERT INTO note_media (id, noteID, name, contents, sha256) VALUES (?, ?, ?, ?, ?)", arguments: [id.uuidString, noteID.uuidString, safeName, data, Self.sourceDigest(data)])
        }
    }

    private static func sourceDigest(_ data: Data) -> String { NoteMediaTranscriber.sourceHash(data) }

    public func mediaData(noteID: UUID, id: UUID) async throws -> Data {
        try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT contents,coalesce(byteCount,length(contents)) AS size FROM note_media WHERE noteID = ? AND id = ? AND isReady = 1 AND sourceRemoved = 0", arguments: [noteID.uuidString,id.uuidString]) else { throw NoteStoreError.missing }
            let size: Int = row["size"]
            guard size > 0, size <= Self.maximumMediaBytes else { throw NoteStoreError.tooLarge }
            let inline: Data = row["contents"]
            if !inline.isEmpty { return inline }
            var result = Data(), expected = 0
            let cursor = try Row.fetchCursor(db, sql: "SELECT sequence,contents FROM note_media_chunks WHERE mediaID = ? ORDER BY sequence", arguments: [id.uuidString])
            while let chunk = try cursor.next() {
                try Task.checkCancellation()
                let data: Data = chunk["contents"], sequence: Int = chunk["sequence"]
                guard sequence == expected, !data.isEmpty, result.count + data.count <= size else { throw NoteStoreError.invalidContent }
                result.append(data); expected += 1
            }
            guard result.count == size else { throw NoteStoreError.invalidContent }
            return result
        }
    }
}
