import Foundation
import Testing
import GRDB
@testable import AgRoomCore

struct NoteStoreTests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test func revisionsAndIsolation() async throws {
        let first = NoteStore(databaseQueue: try database())
        let second = NoteStore(databaseQueue: try database())
        var note = WorkNote(title: "Meeting")
        note.text = "決策 alpha"; note.tags = "project"
        let saved = try await first.save(note)
        #expect(saved.revision == 1)
        #expect(try await first.list(search: "alpha").count == 1)
        #expect(try await second.list().isEmpty)
        await #expect(throws: NoteStoreError.conflict) { try await first.save(note) }
        var edited = saved; edited.archived = true
        let archived = try await first.save(edited)
        #expect(try await first.list().isEmpty)
        #expect(try await first.list(archived: true).first?.id == archived.id)
        await #expect(throws: NoteStoreError.conflict) { try await first.delete(saved) }
    }

    @Test func mediaCascadeAndBackupRestore() async throws {
        let source = try database(), destination = try database()
        let store = NoteStore(databaseQueue: source)
        var draft = WorkNote(title: "Synthetic meeting")
        draft.transcript = "Decision: ship"
        draft.segments = [NoteSegment(timestamp: 3, text: "Decision: ship")]
        draft.todos = [NoteTodo(title: "Ship")]
        draft.summaries = [NoteSummary(text: "Ship")]
        let note = try await store.save(draft)
        let bytes = Data([0, 1, 255, 42])
        try await store.addMedia(noteID: note.id, name: "sample.wav", data: bytes)
        let media = try #require(try await store.media(noteID: note.id).first)
        #expect(try await store.mediaData(noteID: note.id, id: media.id) == bytes)
        let exporter = SpaceDatabaseBackupStore(queue: source, space: "work")
        let backup = try await exporter.export()
        #expect(backup.count("notes") == 1)
        #expect(backup.count("note_media") == 1)
        let target = SpaceDatabaseBackupStore(queue: destination, space: "personal")
        let plan = try await target.plan(backup, sourceSpace: "work", pathMappings: [:], workspaceMappings: [:])
        _ = try await target.apply(plan, willCommit: { _ in })
        let restored = NoteStore(databaseQueue: destination)
        let recovered = try #require(try await restored.list().first)
        #expect(recovered.id == note.id)
        #expect(recovered.transcript == note.transcript)
        #expect(recovered.versionToken != note.versionToken)
        await #expect(throws: NoteStoreError.conflict) { try await restored.save(note) }
        #expect(try await restored.mediaData(noteID: note.id, id: media.id) == bytes)
        try await store.delete(note)
        #expect(try await store.media(noteID: note.id).isEmpty)
        #expect(try await restored.media(noteID: note.id).count == 1)
    }

    @Test func invalidAndBoundedData() async throws {
        let store = NoteStore(databaseQueue: try database())
        await #expect(throws: NoteStoreError.invalidContent) { try await store.save(WorkNote(title: "  ")) }
        let note = try await store.save(WorkNote(title: "Note"))
        await #expect(throws: NoteStoreError.tooLarge) { try await store.addMedia(noteID: note.id, name: "empty.wav", data: Data()) }
        var huge = note; huge.text = String(repeating: "x", count: NoteStore.maximumContentBytes)
        await #expect(throws: NoteStoreError.tooLarge) { try await store.save(huge) }
        #expect(try await store.list().first == note)
    }
    @Test func pagingAndBinaryBackup() async throws {
        let source = try database(), destination = try database()
        let store = NoteStore(databaseQueue: source)
        for index in 0..<101 {
            _ = try await store.save(WorkNote(title: "Page \(index)"))
        }
        let first = try await store.list()
        let second = try await store.list(offset: 100)
        #expect(first.count == 100)
        #expect(second.count == 1)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        let note = try #require(first.first)
        try await store.addMedia(noteID: note.id, name: "audio.wav", data: Data([1, 2, 3]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = SpaceBackupBlobs(root: root)
        let backup = try await SpaceDatabaseBackupStore(queue: source, space: "work", blobs: blobs).export()
        #expect(!backup.blobReferences.isEmpty)
        let target = SpaceDatabaseBackupStore(queue: destination, space: "work", blobs: blobs)
        let plan = try await target.plan(backup, sourceSpace: "work")
        _ = try await target.apply(plan, willCommit: { _ in })
        let restored = NoteStore(databaseQueue: destination)
        let media = try #require(try await restored.media(noteID: note.id).first)
        #expect(try await restored.mediaData(noteID: note.id, id: media.id) == Data([1, 2, 3]))
    }

}
