import Foundation
import GRDB

extension NoteStore {
    public func package(id: UUID) async throws -> NotePackage {
        guard let note = try await get(id: id) else { throw NoteStoreError.missing }
        let attachments = try await media(noteID: id)
        guard attachments.reduce(0,{ $0 + $1.byteCount }) <= NotePackage.maximumBytes else { throw NoteStoreError.tooLarge }
        var items: [NotePackage.Media] = []
        for item in attachments {
            let data = try await mediaData(noteID: id,id: item.id)
            items.append(.init(id: item.id,name: item.name,data: data,sha256: NoteMediaTranscriber.sourceHash(data)))
        }
        let package = NotePackage(format: "agroom-note-v1",note: note,media: items); try package.validate(); return package
    }
    /// New identities, one transaction, no inherited system reminder authority.
    public func importPackage(_ package: NotePackage) async throws -> WorkNote {
        try package.validate()
        var note = package.note
        note.id = UUID(); note.versionToken = UUID(); note.revision = 1; note.updatedAt = Date()
        for i in note.todos.indices { note.todos[i].reminderID = nil }
        let frozen = note, data = try cipher.encode(note, table: "notes")
        try await queue.maintenanceWrite { db in
            try db.execute(sql: "INSERT INTO notes (id, revision, title, searchText, archived, pinned, updatedAt, contents) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [frozen.id.uuidString, frozen.revision, cipher.enabled ? "" : frozen.title, cipher.enabled ? "" : frozen.searchText, frozen.archived, frozen.pinned, frozen.updatedAt, data])
            for media in package.media {
                try Task.checkCancellation()
                try db.execute(sql: "INSERT INTO note_media (id, noteID, name, contents) VALUES (?, ?, ?, ?)", arguments: [UUID().uuidString, frozen.id.uuidString, media.name, media.data])
            }
        }
        return frozen
    }
    public func removeMedia(noteID: UUID, id: UUID) async throws {
        try await queue.maintenanceWrite { db in
            try db.execute(sql: "DELETE FROM note_media WHERE id = ? AND noteID = ?", arguments: [id.uuidString, noteID.uuidString])
            guard db.changesCount == 1 else { throw NoteStoreError.missing }
        }
    }
}
