import Foundation
import Testing
import AVFoundation
import CryptoKit
import GRDB
@testable import AgRoomCore

struct NoteCompletionTests {
    private func store() throws -> NoteStore {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return NoteStore(databaseQueue: queue)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func portablePackageIntegrityNewIdentitiesAndDeletion() async throws {
        let source = try store(), target = try store()
        var note = WorkNote(title: "Portable")
        var todo = NoteTodo(title: "Action"); todo.dueDate = Date(timeIntervalSince1970: 1234); todo.reminderID = "old-system-id"
        note.todos = [todo]; note.summaries = [NoteSummary(text: "Searchable summary")]
        let saved = try await source.save(note)
        try await source.addMedia(noteID: saved.id, name: "image.png", data: Data([1, 2, 3]))
        let package = try await source.package(id: saved.id)
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("note.zwnote")
        try package.write(to: location)
        let read = try NotePackage.read(from: location)
        let imported = try await target.importPackage(read)
        #expect(imported.id != saved.id)
        #expect(imported.todos.first?.reminderID == nil)
        #expect(imported.todos.first?.dueDate == todo.dueDate)
        #expect(try await target.list(search: "Searchable").count == 1)
        let media = try #require(try await target.media(noteID: imported.id).first)
        try await target.removeMedia(noteID: imported.id, id: media.id)
        #expect(try await target.media(noteID: imported.id).isEmpty)
        #expect(try await source.media(noteID: saved.id).count == 1)
        try Data([9]).write(to: location.appendingPathComponent(package.media[0].id.uuidString + ".bin"))
        #expect(throws: NoteStoreError.self) { try NotePackage.read(from: location) }
    }
    @Test func encryptedLegacyImportIsReadOnlyAndFailsClosed() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"title\":\"Legacy\"}".utf8).write(to: directory.appendingPathComponent("meta.json"))
        try Data().write(to: directory.appendingPathComponent("ocr.txt"))
        try Data().write(to: directory.appendingPathComponent("todos.json"))
        let key = Data(repeating: 42, count: 32)
        let encrypted = try #require(AES.GCM.seal(Data("Private source".utf8), using: SymmetricKey(data: key)).combined).base64EncodedString()
        try encrypted.write(to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        #expect(throws: NoteStoreError.missing) { try NoteLegacyImporter.preview(directory: directory) }
        let preview = try NoteLegacyImporter.preview(directory: directory, key: key)
        #expect(preview.note.text == "Private source")
        #expect(try String(contentsOf: directory.appendingPathComponent("source.txt"), encoding: .utf8) == encrypted)
        #expect(throws: (any Error).self) { try NoteLegacyImporter.preview(directory: directory, key: Data(repeating: 7, count: 32)) }
    }
    @Test func workflowResumeSkipsCommittedStagesAndRejectsLateWriter() async throws {
        let store = try store()
        var note = WorkNote(title: "Workflow"); note.text = "Decisions and actions"
        let saved = try await store.save(note)
        let job = try await store.enqueueWorkflow(note: saved, mediaID: nil, settings: .init(), summaryPrompt: "Summary")
        let calls = NoteGenerationCalls()
        let first = NoteWorkflowRunner(store: store) { _, prompt in
            await calls.add(prompt)
            if !prompt.hasPrefix("Summary") { throw CancellationError() }
            return "Committed summary"
        }
        await #expect(throws: CancellationError.self) { try await first.run(id: job.id, progress: { _ in }) }
        #expect(try await store.workflows().first?.stage == 2)
        #expect(try await store.get(id: saved.id)?.summaries.count == 1)
        let resume = NoteWorkflowRunner(store: store) { _, prompt in await calls.add(prompt); return "[\"Action\"]" }
        try await resume.run(id: job.id, progress: { _ in })
        #expect(await calls.values.count == 3)
        #expect(try await store.get(id: saved.id)?.summaries.count == 1)
        #expect(try await store.get(id: saved.id)?.todos.count == 1)
        #expect(try await store.workflows().first?.finished == true)

        let current = try #require(try await store.get(id: saved.id))
        let queued = try await store.enqueueWorkflow(note: current, mediaID: nil, settings: .init(), summaryPrompt: "New")
        let old = try await store.claimWorkflow(queued.id)
        _ = try await store.claimWorkflow(queued.id)
        var attempted = current; attempted.text = "Must roll back"
        await #expect(throws: NoteStoreError.conflict) { try await store.commitWorkflow(old, note: attempted) }
        #expect(try await store.get(id: saved.id) == current)
    }
    @Test func recordingRecoveryImportsIdempotentlyAndPreservesFailedEvidence() async throws {
        let store = try store(), directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = try await store.save(WorkNote(title: "Meeting"))
        let first = UUID(), second = UUID()
        let manifest = NoteCaptureManifest(id: UUID(), noteID: note.id, startedAt: Date(), parts: [
            .init(id: first, name: first.uuidString + ".caf", offset: 0, source: "microphone"),
            .init(id: second, name: second.uuidString + ".caf", offset: 0, source: "system")])
        let session = directory.appendingPathComponent(manifest.id.uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let recovery = NoteCaptureRecovery(root: directory)
        try recovery.save(manifest)
        let mic = session.appendingPathComponent(manifest.parts[0].name)
        try Self.writeSilence(mic)
        // Simulate a previous recovery that committed one part before interruption.
        try await store.addMedia(id: first, noteID: note.id, name: "microphone-0.caf", data: Data(contentsOf: mic))
        await #expect(throws: (any Error).self) { try await recovery.recover(manifest, store: store) }
        #expect(FileManager.default.fileExists(atPath: mic.path))
        try Self.writeSilence(session.appendingPathComponent(manifest.parts[1].name))
        try await recovery.recover(manifest, store: store)
        #expect(try await store.media(noteID: note.id).count == 3)
        #expect(try recovery.sessions().isEmpty)
    }
    @Test func mediaLinksAndTraversalAreRejected() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source")
        try Data([1]).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: NoteStoreError.self) { try NoteCaptureRecovery.read(link, maximum: 100) }
        var package = NotePackage(format: "agroom-note-v1", note: WorkNote(title: "Bad"), media: [])
        package.media = [.init(id: UUID(), name: "../secret", data: Data([1]), sha256: NoteMediaTranscriber.sourceHash(Data([1])))]
        #expect(throws: NoteStoreError.invalidContent) { try package.validate() }
    }
    private static func writeSilence(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
private actor NoteGenerationCalls {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
