import Foundation
import Testing
import CryptoKit
import AVFoundation
import GRDB
@testable import AgRoomCore

struct NoteExpandedTests {
    private func store() throws -> NoteStore {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        return NoteStore(databaseQueue: db)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func passwordArchiveRoundTripAuthenticatesEveryChunkAndPreservesNames() async throws {
        let store = try store(), root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var note = WorkNote(title: "Archive"); note.text = ""; note.summaries = [.init(text: "Original"), .init(text: "Revised")]
        let saved = try await store.save(note)
        try await store.addMedia(noteID: saved.id, name: "原始 name.txt", data: Data(repeating: 42, count: NoteProtectedArchive.chunkSize + 12))
        let package = try await store.package(id: saved.id), archive = root.appendingPathComponent("archive.memontabackup")
        try NoteProtectedArchive.export(package, to: archive, password: "synthetic-password")
        let restored = try #require(try NoteProtectedArchive.preview(from: archive, password: "synthetic-password").first)
        #expect(restored.note == package.note)
        #expect(restored.media.first?.name == "原始 name.txt")
        #expect(restored.media.first?.data == package.media.first?.data)
        #expect(throws: (any Error).self) { try NoteProtectedArchive.preview(from: archive, password: "different-password") }
        let chunk = try #require(try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).first { $0.pathExtension == "bin" && $0.lastPathComponent != "manifest.bin" })
        var bytes = try Data(contentsOf: chunk); bytes[bytes.count - 1] ^= 1; try bytes.write(to: chunk)
        #expect(throws: (any Error).self) { try NoteProtectedArchive.preview(from: archive, password: "synthetic-password") }
        #expect(!NoteProtectedArchive.safePath("20260101010101/../secret"))
        #expect(!NoteProtectedArchive.safePath("/20260101010101/source.txt"))
        #expect(!NoteProtectedArchive.safePath("20260101010101/C:\\secret"))
    }
    @Test func legacyWrappedTodosAndHistoryAreImported() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"title\":\"Legacy\"}".utf8).write(to: root.appendingPathComponent("meta.json"))
        try Data("{\"items\":[{\"title\":\"Review\",\"dueDate\":0}]}".utf8).write(to: root.appendingPathComponent("todos.json"))
        let history = root.appendingPathComponent("summary-history"); try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let prior = NoteSummary(text: "Previous summary")
        try JSONEncoder().encode(prior).write(to: history.appendingPathComponent(prior.id.uuidString + ".json"))
        let package = try NoteLegacyImporter.preview(directory: root, plaintext: true)
        #expect(package.note.summaries.first?.text == "Previous summary")
        #expect(package.note.todos.first?.title == "Review")
        #expect(package.note.todos.first?.dueDate == Date(timeIntervalSinceReferenceDate: 0))
    }
    @Test func localRedactionRestoresOverlappingUnicodeAndQuotedTerms() throws {
        let source = "客户张三（研发部）\"预算\"，邮箱 test@example.org，电话 +86 138 0013 8000。"
        let mask = try NotePII.redact(source, terms: "客户张三\n张三\n\"预算\"")
        #expect(!mask.text.contains("test@example.org"))
        #expect(!mask.text.contains("客户张三"))
        #expect(mask.restore(mask.text) == source)
        #expect(try NotePII.redact("", terms: "").text.isEmpty)
        var one = NoteTranscriptionSettings(); var two = one
        two.redactText = true; two.privateTerms = "张三"; two.diarizationEnabled = true
        #expect(one.recognitionMatches(two))
        one.engine = "whisper"; one.whisperIdentity = "model-1"
        #expect(!one.recognitionMatches(two))
        two.privateTerms = String(repeating: "x", count: 32_769)
        #expect(throws: NoteStoreError.tooLarge) { try two.validate() }
    }
    @Test func voiceprintsAreNormalizedIsolatedAndModelBound() async throws {
        let personal = try store(), work = try store()
        let voice = NoteVoiceprint(name: "Synthetic", embedding: [3,4], modelID: "model-a")
        try await personal.saveVoiceprint(voice)
        #expect(try await work.voiceprints().isEmpty)
        let records = try await personal.voiceprints()
        #expect(abs(records[0].embedding[0] - 0.6) < 0.001)
        #expect(NoteVoiceprintMath.match([3,4], modelID: "model-a", in: records)?.name == "Synthetic")
        #expect(NoteVoiceprintMath.match([3,4], modelID: "model-b", in: records) == nil)
        #expect(NoteVoiceprintMath.normalize([Float.nan]).isEmpty)
        await #expect(throws: NoteStoreError.invalidContent) { try await personal.saveVoiceprint(.init(name: "Invalid", embedding: [.infinity], modelID: "a")) }
    }
    @Test func immutableFolderMirrorIsIdempotentAndRejectsOtherSpaceAndLinks() async throws {
        let store = try store(), root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.save(WorkNote(title: "Mirror")), package = try await store.package(id: saved.id)
        #expect(try NoteFolderMirror.write(package, to: root, space: "personal"))
        #expect(try !NoteFolderMirror.write(package, to: root, space: "personal"))
        #expect(throws: NoteStoreError.conflict) { try NoteFolderMirror.prepare(root, space: "work") }
        let revisions = try NoteFolderMirror.revisions(in: root, space: "personal")
        #expect(revisions.count == 1)
        #expect(try NotePackage.read(from: revisions[0]).note == saved)
        let marker = root.appendingPathComponent("agroom-notes-space.json")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: revisions[0].appendingPathComponent("note.json"))
        #expect(throws: NoteStoreError.self) { try NoteFolderMirror.prepare(root, space: "personal") }
    }
    @Test @MainActor func authenticatedMCPIsReadOnlyAndRevocableOverRealLoopback() async throws {
        let store = try store(), server = NoteMCPServer(store: store)
        var note = WorkNote(title: "MCP synthetic"); note.text = "Only this database"
        let saved = try await store.save(note), token = String(repeating: "x", count: 48)
        try await server.start(token: token)
        let port = server.port
        func request(_ body: [String: Any], bearer: String = token, origin: String? = nil) -> NoteMCPHTTPRequest {
            var headers = ["host": "127.0.0.1:\(port)", "authorization": "Bearer " + bearer]
            if let origin { headers["origin"] = origin }
            return .init(method: "POST", headers: headers, body: try? JSONSerialization.data(withJSONObject: body), path: "/mcp")
        }
        let call: [String: Any] = ["jsonrpc":"2.0", "id":1, "method":"tools/call", "params":["name":"notes_get", "arguments":["id":saved.id.uuidString]]]
        #expect(await server.handle(request(call, bearer: "bad")).status == 401)
        #expect(await server.handle(request(call, origin: "https://untrusted.example")).status == 403)
        #expect(String(decoding: await server.handle(request(call)).body, as: UTF8.self).contains("Only this database"))
        var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!); http.httpMethod = "POST"
        http.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); http.httpBody = try JSONSerialization.data(withJSONObject: call)
        let (data, response) = try await URLSession.shared.data(for: http)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Only this database"))
        server.deactivate()
        #expect(await server.handle(request(call)).status == 503)
        try await server.stop()
    }
    @Test func spaceBackupRetainsVoicesButRemovesDeviceGrants() async throws {
        let source = try DatabaseQueue(), target = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(source); try DatabaseBootstrap.prepareSpace(target)
        let store = NoteStore(databaseQueue: source)
        try await store.saveVoiceprint(.init(name: "Synthetic", embedding: [1,0], modelID: "model-a"))
        let preferences = ProductPreferencesService(databaseQueue: source)
        var settings = NoteTranscriptionSettings(); settings.engine = "whisper"; settings.whisperBookmark = Data("secret-grant".utf8); settings.diarizationBookmark = settings.whisperBookmark; settings.diarizationEnabled = true
        try await preferences.save(settings, key: "notes.transcription")
        try await preferences.save(["mirrorBookmark":"device-only"], key: "notes.local")
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "work").export()
        #expect(!String(decoding: try JSONEncoder().encode(archive), as: UTF8.self).contains("device-only"))
        let destination = SpaceDatabaseBackupStore(queue: target, space: "work")
        let plan = try await destination.plan(archive, sourceSpace: "work")
        let applied = try await destination.apply(plan) { _ in }; try await destination.verify(applied)
        #expect(try await NoteStore(databaseQueue: target).voiceprints().first?.name == "Synthetic")
        let restored = try #require(try await ProductPreferencesService(databaseQueue: target).load(NoteTranscriptionSettings.self, key: "notes.transcription"))
        #expect(restored.whisperBookmark == nil && restored.diarizationBookmark == nil && restored.diarizationEnabled == false)
        #expect(restored.effectiveEngine == "system")
    }
    @Test @MainActor func actualSystemSpeechExportUsesSyntheticTextWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AGROOM_TEST_NOTE_SPEECH"] == "1" else { return }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("speech.m4a")
        try await NoteSpeechExport().write(text: "This is a synthetic test of local speaker recognition. We review decisions and actions, then keep the original audio unchanged.", locale: "en-US", to: output)
        #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0)
        if let path = ProcessInfo.processInfo.environment["AGROOM_TEST_NOTE_SPEAKER_MODEL"] {
            let speakers = try await NoteSpeakerAnalyzer().analyze(url: output, modelFolder: URL(fileURLWithPath: path)) { _ in }
            #expect(!speakers.turns.isEmpty)
            #expect(speakers.embeddings.values.contains { !$0.isEmpty && $0.allSatisfy(\.isFinite) })
        }
    }
    @Test func actualSpeakerRuntimeAcceptsSyntheticAudioWhenPublicWeightsAreProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGROOM_TEST_NOTE_SPEAKER_MODEL"] else { return }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 5)); buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let result = try await NoteSpeakerAnalyzer().analyze(url: url, modelFolder: URL(fileURLWithPath: path)) { _ in }
        #expect(result.turns.allSatisfy { $0.start >= 0 && $0.end <= 5.1 })
        #expect(!result.modelID.isEmpty)
    }
}
