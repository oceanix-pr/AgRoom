import Foundation
import AVFoundation
import GRDB

public struct NoteSourceCleanupPlan: Sendable, Identifiable {
    public let id = UUID()
    public struct Item: Sendable { public let note: WorkNote; public let media: [NoteMedia] }
    public let items: [Item]
    public var bytes: Int { items.flatMap(\.media).reduce(0) { $0 + $1.byteCount } }
}
public struct NoteRecordingMergePlan: Sendable, Identifiable {
    public let id = UUID()
    public struct Item: Sendable { public let note: WorkNote; public let media: [NoteMedia]; public let source: NoteMedia; public let duration: Double }
    public let items: [Item]
    public var duration: Double { items.reduce(0) { $0 + $1.duration } }
}

extension NoteStore {
    public func planSourceCleanup(ids: [UUID]) async throws -> NoteSourceCleanupPlan {
        guard !ids.isEmpty, ids.count <= 1000, Set(ids).count == ids.count else { throw NoteStoreError.invalidContent }
        var items: [NoteSourceCleanupPlan.Item] = []
        let allowed: Set<String> = ["m4a","mp3","wav","aiff","aif","aac","caf","flac","ogg","mp4","mov","m4v","png","jpg","jpeg","heic","tiff","gif","webp"]
        for id in ids {
            guard let note = try await get(id: id) else { throw NoteStoreError.missing }
            let media = try await media(noteID: id).filter { allowed.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
            for file in media where ["mp4","mov","m4v"].contains(URL(fileURLWithPath: file.name).pathExtension.lowercased()) {
                guard note.visualNotes?.isEmpty == false, try await !visualFrames(mediaID: file.id).isEmpty else { throw NoteStoreError.invalidContent }
            }
            items.append(.init(note: note,media: media))
        }
        return .init(items: items)
    }
    public func applySourceCleanup(_ plan: NoteSourceCleanupPlan) async throws {
        try await queue.maintenanceWrite { db in
            for item in plan.items {
                try Task.checkCancellation()
                guard let data = try Data.fetchOne(db,sql: "SELECT contents FROM notes WHERE id = ?",arguments: [item.note.id.uuidString]), try cipher.decode(WorkNote.self,from: data,table: "notes") == item.note else { throw NoteStoreError.conflict }
                for file in item.media {
                    guard let row = try Row.fetchOne(db,sql: "SELECT name,coalesce(byteCount,length(contents)) AS size FROM note_media WHERE id = ? AND noteID = ? AND isReady = 1 AND sourceRemoved = 0",arguments: [file.id.uuidString,item.note.id.uuidString]), row["name"] as String == file.name, row["size"] as Int == file.byteCount else { throw NoteStoreError.conflict }
                    try db.execute(sql: "DELETE FROM note_media_chunks WHERE mediaID = ?",arguments: [file.id.uuidString])
                    // Retain identity and frame cache; only the source bytes are removed.
                    try db.execute(sql: "UPDATE note_media SET contents = X'', byteCount = 0, sourceRemoved = 1 WHERE id = ?",arguments: [file.id.uuidString])
                }
                var note = item.note; note.revision += 1; note.versionToken = UUID(); note.updatedAt = Date()
                try db.execute(sql: "UPDATE notes SET revision = ?,updatedAt = ?,contents = ? WHERE id = ?",arguments: [note.revision,note.updatedAt,try cipher.encode(note,table: "notes"),note.id.uuidString])
            }
        }
    }
    public func planRecordingMerge(ids: [UUID]) async throws -> NoteRecordingMergePlan {
        guard (2...100).contains(ids.count), Set(ids).count == ids.count else { throw NoteStoreError.invalidContent }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var items: [NoteRecordingMergePlan.Item] = []
        for id in ids {
            guard let note = try await get(id: id) else { throw NoteStoreError.missing }
            let media = try await media(noteID: id)
            let audio = media.filter { ["m4a","mp3","wav","aiff","aif","aac","caf","flac"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
            guard !media.contains(where: { ["mp4","mov","m4v"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }),
                  media.allSatisfy({ audio.contains($0) || $0.name.hasSuffix(".json") }),
                  let source = audio.first(where: { $0.name == "meeting.m4a" }) ?? (audio.count == 1 ? audio.first : nil) else { throw NoteStoreError.invalidContent }
            let file = root.appendingPathComponent(source.id.uuidString + "." + URL(fileURLWithPath: source.name).pathExtension)
            try await writeMedia(noteID: id,id: source.id,to: file)
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 28_800 else { throw NoteStoreError.invalidContent }
            items.append(.init(note: note,media: media,source: source,duration: duration))
        }
        items.sort { $0.note.createdAt == $1.note.createdAt ? $0.note.id.uuidString < $1.note.id.uuidString : $0.note.createdAt < $1.note.createdAt }
        guard items.reduce(0,{ $0 + $1.duration }) <= 28_800 else { throw NoteStoreError.tooLarge }
        return .init(items: items)
    }
    public func applyRecordingMerge(_ plan: NoteRecordingMergePlan) async throws -> WorkNote {
        guard let newest = plan.items.last else { throw NoteStoreError.invalidContent }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var parts: [NoteAudioPart] = [], offset = 0.0, note = newest.note
        note.segments = []; note.text = ""; note.transcript = ""; note.summaries = []; note.todos = []
        var todoIDs = Set<UUID>()
        for item in plan.items {
            try Task.checkCancellation()
            guard try await get(id: item.note.id) == item.note, try await media(noteID: item.note.id) == item.media else { throw NoteStoreError.conflict }
            let file = root.appendingPathComponent(item.source.id.uuidString + "." + URL(fileURLWithPath: item.source.name).pathExtension)
            try await writeMedia(noteID: item.note.id,id: item.source.id,to: file)
            parts.append(.init(url: file,offset: offset,source: "merged"))
            note.text += (note.text.isEmpty || item.note.text.isEmpty ? "" : "\n\n") + item.note.text
            note.transcript += (note.transcript.isEmpty || item.note.transcript.isEmpty ? "" : "\n") + item.note.transcript
            note.segments += item.note.segments.map { .init(timestamp: $0.timestamp + offset,endTimestamp: $0.endTimestamp.map { $0 + offset },speaker: $0.speaker,text: $0.text) }
            note.summaries += item.note.summaries
            note.todos += item.note.todos.map { todo in var value = todo; if !todoIDs.insert(value.id).inserted { value.id = UUID() }; value.sourceTimestamp = value.sourceTimestamp.map { $0 + offset }; return value }
            offset += item.duration
        }
        guard try JSONEncoder().encode(note).count <= Self.maximumContentBytes, note.todos.count <= 1000, note.summaries.count <= 100 else { throw NoteStoreError.tooLarge }
        let merged = root.appendingPathComponent("meeting.m4a")
        try await NoteAudioAssembler.assemble(parts,to: merged)
        let mediaID = UUID()
        try await addMediaFile(id: mediaID,noteID: note.id,name: "meeting.m4a",file: merged,publish: false)
        note.revision += 1; note.versionToken = UUID(); note.updatedAt = Date()
        let saved = note
        do {
            try await queue.maintenanceWrite { db in
                for item in plan.items {
                    guard let data = try Data.fetchOne(db,sql: "SELECT contents FROM notes WHERE id = ?",arguments: [item.note.id.uuidString]), try cipher.decode(WorkNote.self,from: data,table: "notes") == item.note else { throw NoteStoreError.conflict }
                    let ids = try String.fetchAll(db,sql: "SELECT id FROM note_media WHERE noteID = ? AND isReady = 1 AND sourceRemoved = 0 ORDER BY name,id",arguments: [item.note.id.uuidString])
                    guard ids == item.media.map({ $0.id.uuidString }) else { throw NoteStoreError.conflict }
                }
                try db.execute(sql: "UPDATE notes SET revision = ?,updatedAt = ?,contents = ?,title = ?,searchText = ? WHERE id = ?",arguments: [saved.revision,saved.updatedAt,try cipher.encode(saved,table: "notes"),cipher.enabled ? "" : saved.title,cipher.enabled ? "" : saved.searchText,saved.id.uuidString])
                try db.execute(sql: "UPDATE note_media SET name = 'original-' || name WHERE id = ?",arguments: [newest.source.id.uuidString])
                try db.execute(sql: "UPDATE note_media SET isReady = 1 WHERE id = ?",arguments: [mediaID.uuidString])
                for item in plan.items where item.note.id != saved.id { try db.execute(sql: "DELETE FROM notes WHERE id = ?",arguments: [item.note.id.uuidString]) }
            }
            return saved
        } catch {
            if let current = try? await Task.detached(operation: { try await self.get(id: saved.id) }).value, current.versionToken == saved.versionToken { return current }
            _ = try? await Task.detached { [queue] in
                try await queue.maintenanceWrite { db in try db.execute(sql: "DELETE FROM note_media WHERE id = ? AND isReady = 0",arguments: [mediaID.uuidString]) }
            }.value
            throw error
        }
    }
}
