import Foundation
import Testing
import CryptoKit
import Security
import AVFoundation
import GRDB
@testable import AgRoomCore
@testable import AgRoomUI

struct NoteMigrationParityTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700]); return url
    }
    private func store(cipher: NoteContentCipher = .plaintext) throws -> (DatabaseQueue,NoteStore) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return (queue,NoteStore(databaseQueue: queue,cipher: cipher))
    }
    @Test func encryptedSearchContinuesAfterScannedNonmatchesAndBreaksSortTiesByID() async throws {
        let cipher = NoteContentCipher(key: Data(repeating: 13, count: 32), scope: "work")
        let (db, records) = try store(cipher: cipher)
        var expected: [UUID] = [], scannedGap: UUID?
        for index in 0..<250 {
            let omitted = (100..<120).contains(index)
            var note = WorkNote(title: omitted ? "unrelated" : "match")
            note.id = try #require(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)))
            note.pinned = index < 16
            _ = try await records.save(note)
            if !omitted { expected.append(note.id) }
            if index == 110 { scannedGap = note.id }
        }
        try await db.write { try $0.execute(sql: "UPDATE notes SET updatedAt = '2030-01-01 00:00:00.000'") }
        let first = try await records.page(search: "MATCH")
        let cursor = try #require(first.next), gap = try #require(scannedGap)
        // Re-reading the already scanned gap would now fail authentication.
        try await db.write { try $0.execute(sql: "UPDATE notes SET contents = x'00' WHERE id = ?", arguments: [gap.uuidString]) }
        let second = try await records.page(search: "MATCH", after: cursor)
        let next = try #require(second.next)
        let third = try await records.page(search: "MATCH", after: next)
        let counts: [Int] = [first.notes.count, second.notes.count, third.notes.count]
        #expect(counts == [100, 100, 30])
        #expect((first.notes + second.notes + third.notes).map(\.id) == expected)
        #expect(third.next == nil)
    }

    @Test func encryptedContentHasNoPlaintextIndexAndBackupRekeys() async throws {
        let cipher = NoteContentCipher(key: Data(repeating: 7,count: 32),scope: "work")
        let (queue,store) = try self.store(cipher: cipher)
        var note = WorkNote(title: "private-title-7e2ffbd48e")
        note.text = "private-source-86c9a128f3"; note.visualNotes = "private-slides-11a9f203b7"
        let saved = try await store.save(note)
        let bytes = try #require(try await queue.read { db in try Data.fetchOne(db,sql: "SELECT contents FROM notes") })
        #expect(bytes.range(of: Data(note.text.utf8)) == nil)
        #expect(try await queue.read { db in try String.fetchOne(db,sql: "SELECT title || searchText FROM notes") } == "")
        #expect(try await store.list(search: "slides").first?.id == saved.id)
        let wrong = NoteStore(databaseQueue: queue,cipher: .init(key: Data(repeating: 7,count: 32),scope: "personal"))
        await #expect(throws: (any Error).self) { try await wrong.get(id: saved.id) }
        let backupStore = SpaceDatabaseBackupStore(queue: queue,space: "work",noteCipher: cipher)
        let backup = try await backupStore.export()
        let otherKey = NoteContentCipher(key: Data(repeating: 9,count: 32),scope: "work")
        let (targetQueue,target) = try self.store(cipher: otherKey)
        let restore = SpaceDatabaseBackupStore(queue: targetQueue,space: "work",noteCipher: otherKey)
        let plan = try await restore.plan(backup,sourceSpace: "work")
        _ = try await restore.apply(plan) { _ in }
        let restored = try #require(try await target.get(id: saved.id))
        #expect(restored.text == note.text && restored.visualNotes == note.visualNotes)
        #expect(restored.versionToken != saved.versionToken)
        #expect(try await targetQueue.read { db in try String.fetchOne(db,sql: "SELECT searchText FROM notes") } == "")
    }
    @Test func oldPlaintextConversionAuthenticatesBeforePublishing() async throws {
        let (queue,plain) = try self.store()
        var note = WorkNote(title: "Legacy"); note.text = "old text to protect"
        let saved = try await plain.save(note)
        let cipher = NoteContentCipher(key: Data(repeating: 4,count: 32),scope: "personal")
        try NoteContentCipher.protect(queue,cipher: cipher)
        let protected = NoteStore(databaseQueue: queue,cipher: cipher)
        #expect(try await protected.get(id: saved.id)?.text == note.text)
        let before = try await queue.read { db in try Data.fetchOne(db,sql: "SELECT contents FROM notes") }
        #expect(throws: (any Error).self) { try NoteContentCipher.protect(queue,cipher: .init(key: Data(repeating: 5,count: 32),scope: "personal")) }
        #expect(try await queue.read { db in try Data.fetchOne(db,sql: "SELECT contents FROM notes") } == before)
    }
    @Test func missingKeyIsNeverRecreatedForEncryptedOrDamagedRecords() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let db = try DatabaseQueue(path: folder.appendingPathComponent("work.sqlite").path)
        try DatabaseBootstrap.prepareSpace(db)
        let key = NoteContentCipher(key: Data(repeating: 19, count: 32), scope: "work")
        var createRequests = 0
        func lookup(_ create: Bool) throws -> NoteContentCipher {
            guard create else { throw KeychainService.KeychainError.unexpectedStatus(errSecItemNotFound) }
            createRequests += 1
            return key
        }
        let legacy = try await NoteStore(databaseQueue: db).save(WorkNote(title: "fixture"))
        _ = try NoteContentCipher.loadForMount(db, key: lookup)
        try NoteContentCipher.protect(db, cipher: key)
        #expect(throws: KeychainService.KeychainError.self) { try NoteContentCipher.loadForMount(db, key: lookup) }
        try await db.write { try $0.execute(sql: "UPDATE notes SET contents = x'00AAFFFF' WHERE id = ?", arguments: [legacy.id.uuidString]) }
        #expect(throws: KeychainService.KeychainError.self) { try NoteContentCipher.loadForMount(db, key: lookup) }
        #expect(createRequests == 1)
    }

    @Test func fileMountAuthenticatesEveryRowRollsBackAndFinishesPendingCleanup() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("test.sqlite")
        let queue = try DatabaseQueue(path: file.path)
        try DatabaseBootstrap.prepareSpace(queue)
        let cipher = NoteContentCipher(key: Data(repeating: 42, count: 32), scope: "work")
        let plain = NoteStore(databaseQueue: queue), sealed = NoteStore(databaseQueue: queue, cipher: cipher)
        let legacy = try await plain.save(WorkNote(title: "private fixture"))
        let current = try await sealed.save(WorkNote(title: "encrypted"))
        let id = current.id.uuidString
        let valid = try #require(try await queue.read { try Data.fetchOne($0, sql: "SELECT contents FROM notes WHERE id=?", arguments: [id]) })
        var damaged = valid; damaged[damaged.count - 1] ^= 1
        let corrupt = damaged
        try await queue.write { try $0.execute(sql: "UPDATE notes SET contents=? WHERE id=?", arguments: [corrupt, id]) }
        #expect(throws: (any Error).self) { try NoteContentCipher.protect(queue, cipher: cipher) }
        #expect(try await queue.read { try String.fetchOne($0, sql: "SELECT title FROM notes WHERE id=?", arguments: [legacy.id.uuidString]) } == legacy.title)
        try await queue.write { db in
            try db.execute(sql: "UPDATE notes SET contents=? WHERE id=?", arguments: [valid, id])
            // A process stops after conversion has committed and before clearing the durable cleanup receipt.
            try db.execute(sql: "CREATE TRIGGER delay_cleanup BEFORE DELETE ON note_cipher_cleanup BEGIN SELECT RAISE(ABORT,'pause'); END")
        }
        #expect(throws: (any Error).self) { try NoteContentCipher.protect(queue, cipher: cipher) }
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_cipher_cleanup") } == 1)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER delay_cleanup") }
        let reopened = try DatabaseQueue(path: file.path)
        try NoteContentCipher.protect(reopened, cipher: cipher)
        #expect(try await reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_cipher_cleanup") } == 0)
        #expect(try await NoteStore(databaseQueue: reopened, cipher: cipher).get(id: legacy.id) == legacy)
        let wrong = NoteContentCipher(key: Data(repeating: 0, count: 32), scope: "work")
        #expect(throws: (any Error).self) { try NoteContentCipher.protect(reopened, cipher: wrong) }
    }

    @Test func legacyCreationDateTitleAndSegmentEndsSurvive() throws {
        let parent = try self.root(); defer { try? FileManager.default.removeItem(at: parent) }
        let entry = parent.appendingPathComponent("20240102123456-1")
        try FileManager.default.createDirectory(at: entry,withIntermediateDirectories: false)
        try Data("Old title".utf8).write(to: entry.appendingPathComponent("title.txt"))
        try Data(#"[{"startTime":1,"endTime":2,"speaker":"A","text":"first"},{"startTime":7,"endTime":9,"text":"last"}]"#.utf8).write(to: entry.appendingPathComponent("transcript.json"))
        try Data("meeting summary".utf8).write(to: entry.appendingPathComponent("summary.md"))
        try Data("visual notes".utf8).write(to: entry.appendingPathComponent("visual.md"))
        let result = try NoteLegacyImporter.preview(directory: entry,plaintext: true,includeMedia: false)
        #expect(result.note.title == "Old title")
        let calendar = Calendar.current
        #expect(calendar.component(.year,from: result.note.createdAt) == 2024)
        #expect(calendar.component(.hour,from: result.note.createdAt) == 12)
        #expect(result.note.summaries.last?.text == "meeting summary")
        #expect(result.note.visualNotes == "visual notes")
        #expect(NoteSubtitleExporter.srt(result.note.segments).contains("00:00:01,000 --> 00:00:02,000"))
    }
    @Test func fileBackedMediaExceedsOldLimitWithoutAnUnboundedRead() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.wav")
        FileManager.default.createFile(atPath: source.path,contents: nil)
        let file = try FileHandle(forWritingTo: source)
        let size = NoteStore.maximumMediaBytes + 4096
        try file.truncate(atOffset: UInt64(size)); try file.seek(toOffset: UInt64(size - 4)); try file.write(contentsOf: Data([1,2,3,4])); try file.close()
        let (_,store) = try self.store(), note = try await store.save(WorkNote(title: "Large media"))
        try await store.addMediaFile(noteID: note.id,name: "large.wav",file: source)
        let media = try #require(try await store.media(noteID: note.id).first)
        #expect(media.byteCount == size)
        await #expect(throws: NoteStoreError.tooLarge) { try await store.mediaData(noteID: note.id,id: media.id) }
        let output = root.appendingPathComponent("copy.wav")
        try await store.writeMedia(noteID: note.id,id: media.id,to: output)
        let copiedHash = try await NoteStore.digest(output), originalHash = try await NoteStore.digest(source)
        #expect(copiedHash == originalHash)
        let staging = root.appendingPathComponent("staging"); try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: false)
        let package = try await store.filePackage(id: note.id,in: staging)
        let native = root.appendingPathComponent("large.zwnote")
        try await package.write(to: native)
        let read = try await NoteFilePackage.read(native)
        #expect(read.media.first?.bytes == size)
    }
    @Test func changedImportRemainsHiddenAndUnchangedRetryIsIdempotent() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.wav"); try Data([1,2,3]).write(to: file)
        let hash = try await NoteStore.digest(file)
        let package = NoteFilePackage(note: WorkNote(title: "Import"),media: [.init(id: UUID(),name: "audio.wav",bytes: 3,sha256: hash,file: file)],sourceIdentity: "fixture-source")
        let (_,store) = try self.store()
        try Data([4,5,6]).write(to: file)
        await #expect(throws: NoteStoreError.conflict) { try await store.importFiles(package) }
        #expect(try await store.list().isEmpty)
        try Data([1,2,3]).write(to: file)
        let first = try await store.importFiles(package), second = try await store.importFiles(package)
        #expect(first.id == second.id)
        #expect(try await store.list().count == 1)
        #expect(try await store.media(noteID: first.id).count == 1)
    }
    @Test func structuredTasksValidateEvidenceAndResolveExplicitDates() throws {
        let source = "[t=5.000] Alex: send the report tomorrow. https://example.test/report"
        let json = #"[{"title":"Send report","owner":"Alex","notes":"Review first","dueDate":"2026-11-14T10:00:00+08:00","priority":1,"alarmOffsetMinutes":30,"evidenceQuote":"send the report tomorrow.","sourceTimestamp":5,"url":"https://example.test/report"},{"title":"Unknown","owner":"Invented","evidenceQuote":"not present","sourceTimestamp":5}]"#
        let tasks = try NoteAIProcessing.decodeTodos(json,source: source)
        #expect(tasks[0].owner == "Alex" && tasks[0].priority == 1 && tasks[0].dueDate != nil)
        #expect(tasks[0].alarmOffsetMinutes == 30 && tasks[0].sourceTimestamp == 5)
        #expect(tasks[1].owner == nil && tasks[1].evidenceQuote == nil && tasks[1].sourceTimestamp == nil)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-12-31T10:00:00Z"))
        #expect(NoteAIProcessing.timeContext(now: now,zone: TimeZone(identifier: "Asia/Shanghai")!).contains("2026-12-31T18:00:00+08:00"))
    }
    @Test func aChangedNativePackageCannotResumeWithItsPreviousDraftContent() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.wav"); try Data([1,2,3]).write(to: file)
        let media = NoteFilePackage.Media(id: UUID(),name: "audio.wav",bytes: 3,sha256: try await NoteStore.digest(file),file: file)
        var note = WorkNote(title: "Old import"); note.text = "Old body"
        let old = NoteFilePackage(note: note,media: [media])
        let (_,store) = try self.store()
        try Data([4,5,6]).write(to: file)
        await #expect(throws: NoteStoreError.conflict) { try await store.importFiles(old) }
        try Data([1,2,3]).write(to: file)
        note.title = "New import"; note.text = "Updated body"
        let imported = try await store.importFiles(.init(note: note,media: [media]))
        #expect(imported.title == "New import" && imported.text == "Updated body")
        #expect(try await store.list().count == 1)
    }
    @Test func visualOutputFeedsLaterStagesAndCompletedStagesAreSkipped() async throws {
        let (_,store) = try self.store()
        var note = WorkNote(title: "Visual"); note.text = "spoken words"
        let saved = try await store.save(note), id = UUID()
        try await store.addMedia(id: id,noteID: saved.id,name: "slide.png",data: Data([1,2,3]))
        let job = try await store.enqueueWorkflow(note: saved,mediaID: id,settings: .init(),summaryPrompt: "Summary",steps: [.visual,.summary,.todos])
        let sources = NoteParityCalls()
        let runner = NoteWorkflowRunner(store: store,visual: { _,_ in "slide decision" }) { source,prompt in
            await sources.add(source)
            return prompt.contains("JSON array") ? "[\"Follow up\"]" : "Combined summary"
        }
        try await runner.run(id: job.id,progress: { _ in })
        let result = try #require(try await store.get(id: saved.id))
        #expect(result.visualNotes == "slide decision" && result.summaries.last?.text == "Combined summary")
        #expect(await sources.values.allSatisfy { $0.contains("slide decision") && $0.contains("spoken words") })
        let media = try #require(try await store.media(noteID: saved.id).first)
        #expect(NoteWorkflowPlan.make(note: result,media: media).steps.isEmpty)
    }
    @Test func markdownDictionaryPhoneticsAndPrivateTermsRemainSeparate() throws {
        let rules = try NoteTranscriptDictionary("# Dictionary\n| 错误词 | 正确词 |\n| --- | --- |\n| 工做 | 工作 |\n- 阿吉屋\n- Alex #去标识化:人员姓名")
        #expect(try rules.apply("工做与阿集屋 Alex") == "工作与阿吉屋 Alex")
        #expect(rules.privateTerms == ["Alex"])
        #expect(throws: NoteStoreError.invalidContent) { try NoteTranscriptDictionary("x=y\nx=z") }
        #expect(NoteSpeechText.prepare("# Header\n\n```swift\nsecretCode()\n```\n![image](url)\n| A | B |\n|---|---|\n|one|two|").contains("A: one; B: two"))
        #expect(!NoteSpeechText.prepare("```swift\nsecretCode()\n```").contains("secretCode"))
    }
    @Test func voiceNamesCollapseAndIdentityConflictsAreRejected() async throws {
        let (_,store) = try self.store()
        let one = NoteVoiceprint(name: "Alex",embedding: [1,0],modelID: "fixture")
        try await store.registerVoiceprint(one)
        await #expect(throws: NoteVoiceprintError.self) { try await store.registerVoiceprint(.init(name: "Other",embedding: [1,0],modelID: "fixture")) }
        try await store.registerVoiceprint(.init(name: "Alex",embedding: [1,0],modelID: "fixture"))
        #expect(try await store.voiceprints().count == 1)
        let names = NoteSpeakerRefinement.identify([0:[1,0],1:[0.99,0.01]],modelID: "fixture",records: [one])
        #expect(names.count == 1)
    }
    @Test func sourceCleanupChecksRevisionsAndPreservesPortableFrames() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_,store) = try self.store()
        let mediaID = UUID(), jpeg = Data([0xff,0xd8,0xff,0xd9])
        var note = WorkNote(title: "Slides"); note.visualNotes = "Slide decisions"; note.visualMediaID = mediaID
        note = try await store.save(note)
        try await store.addMedia(id: mediaID,noteID: note.id,name: "video.mp4",data: Data([1,2,3]))
        try await store.cacheFrames([.init(seconds: 2,jpeg: jpeg)],mediaID: mediaID,source: "fixture")
        let oldPlan = try await store.planSourceCleanup(ids: [note.id])
        note.text = "Edited after review"; note = try await store.save(note)
        await #expect(throws: NoteStoreError.conflict) { try await store.applySourceCleanup(oldPlan) }
        #expect(try await store.media(noteID: note.id).count == 1)
        let plan = try await store.planSourceCleanup(ids: [note.id])
        try await store.applySourceCleanup(plan)
        #expect(try await store.media(noteID: note.id).isEmpty)
        #expect(try await store.visualFrames(mediaID: mediaID).first?.jpeg == jpeg)
        let staging = root.appendingPathComponent("staging"); try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: false)
        let package = try await store.filePackage(id: note.id,in: staging)
        #expect(package.media.isEmpty && package.visual?.sourceRemoved == true)
        let native = root.appendingPathComponent("slides.zwnote"); try await package.write(to: native)
        let read = try await NoteFilePackage.read(native)
        let (_,target) = try self.store()
        let imported = try await target.importFiles(read)
        let importedMediaID = try #require(imported.visualMediaID)
        #expect(importedMediaID != mediaID && imported.visualNotes == "Slide decisions")
        #expect(try await target.visualFrames(mediaID: importedMediaID).first?.jpeg == jpeg)
        let archive = root.appendingPathComponent("slides.memontabackup")
        try await NoteProtectedArchive.exportFiles(package,to: archive,password: "synthetic-password")
        await #expect(throws: (any Error).self) { try await NoteProtectedArchive.stageFiles(from: archive,password: "wrong-password") }
        let (decrypted,entries) = try await NoteProtectedArchive.stageFiles(from: archive,password: "synthetic-password")
        defer { try? FileManager.default.removeItem(at: decrypted) }
        let entry = try #require(entries.first), protected = try await NoteProtectedArchive.previewFileEntry(entry)
        let importedProtected = try await target.importFiles(protected)
        #expect(try await target.visualFrames(mediaID: importedProtected.visualMediaID!).first?.jpeg == jpeg)
    }
    @Test func chunkedBackupsRejectTruncationAndDoNotPublishIncompleteImports() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.wav"); try Data([1,2,3]).write(to: file)
        let (queue,store) = try self.store(), note = try await store.save(WorkNote(title: "Complete"))
        let mediaID = UUID()
        try await store.addMediaFile(id: mediaID,noteID: note.id,name: "audio.wav",file: file)
        let backupStore = SpaceDatabaseBackupStore(queue: queue,space: "work")
        var backup = try await backupStore.export()
        let table = try #require(backup.tables.firstIndex { $0.name == "note_media_chunks" })
        backup.tables[table].rows = []
        await #expect(throws: (any Error).self) { try await backupStore.plan(backup,sourceSpace: "work") }
        let hidden = try await store.save(WorkNote(title: "Incomplete import"))
        try await queue.write { db in try db.execute(sql: "INSERT INTO note_import_staging (source,noteID) VALUES (?,?)",arguments: ["pending",hidden.id.uuidString]) }
        #expect(try await backupStore.export().count("notes") == 1)
        // A killed file upload can retry its stable identity after the previous lease expires.
        let pending = UUID()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO note_media (id,noteID,name,contents,isReady,uploadOwner,uploadUntil) VALUES (?,?,?,X'',0,?,?)",arguments: [pending.uuidString,note.id.uuidString,"retry.wav","old",Date.distantPast])
        }
        try await store.addMediaFile(id: pending,noteID: note.id,name: "retry.wav",file: file)
        #expect(try await store.mediaData(noteID: note.id,id: pending) == Data([1,2,3]))
    }
    @Test func mergingRecordingsOffsetsEndsAndRejectsStalePlans() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000,channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 3200)); buffer.frameLength = 3200
        for index in 0..<3200 { buffer.floatChannelData?[0][index] = Float(sin(Double(index) * 0.1) * 0.1) }
        let audio = root.appendingPathComponent("source.caf")
        do { let file = try AVAudioFile(forWriting: audio,settings: format.settings); try file.write(from: buffer) }
        let (_,store) = try self.store()
        var notes: [WorkNote] = []
        for index in 0..<2 {
            var note = WorkNote(title: "Part \(index)"); note.createdAt = Date(timeIntervalSince1970: Double(index + 1))
            note.text = "Part \(index)"; note.segments = [.init(timestamp: 0,endTimestamp: 0.15,text: "Part \(index)")]
            var todo = NoteTodo(title: "Task \(index)"); todo.sourceTimestamp = 0.1; note.todos = [todo]
            note = try await store.save(note)
            try await store.addMediaFile(noteID: note.id,name: "source.caf",file: audio)
            notes.append(note)
        }
        let stale = try await store.planRecordingMerge(ids: notes.map(\.id))
        notes[0].text = "Updated"; notes[0] = try await store.save(notes[0])
        await #expect(throws: NoteStoreError.conflict) { try await store.applyRecordingMerge(stale) }
        #expect(try await store.list().count == 2)
        let plan = try await store.planRecordingMerge(ids: notes.map(\.id))
        let merged = try await store.applyRecordingMerge(plan)
        #expect(merged.id == notes[1].id && merged.title == notes[1].title)
        #expect(abs(merged.segments[1].timestamp - plan.items[0].duration) < 0.001)
        #expect(abs(merged.segments[1].endTimestamp! - plan.items[0].duration - 0.15) < 0.001)
        #expect(abs(merged.todos[1].sourceTimestamp! - plan.items[0].duration - 0.1) < 0.001)
        #expect(try await store.list().count == 1)
        #expect(try await store.media(noteID: merged.id).contains { $0.name == "meeting.m4a" })
    }
    @Test @MainActor func workflowLeasesAndExitHandoffRequireExplicitAuthorization() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (queue,store) = try self.store(), note = try await store.save(WorkNote(title: "Private"))
        let job = try await store.enqueueWorkflow(note: note,mediaID: nil,settings: .init(),summaryPrompt: "Summary",steps: [.summary])
        let claim = try await store.claimWorkflow(job.id,leased: true)
        await #expect(throws: NoteStoreError.conflict) { try await store.claimWorkflow(job.id,leased: true) }
        try await store.releaseWorkflow(claim)
        try await store.authorizeBackground([job.id],enabled: true)
        #expect(try await store.backgroundWorkflows().isEmpty)
        try NoteBackgroundHandoff.publish(space: .work,ids: [job.id],root: root)
        let hub = Hub(spaceStore: SpaceStore(space: .work,databaseQueue: queue))
        await NoteBackgroundHandoff.drain(hub: hub,space: .work,root: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("work/note-handoff.json").path))
        #expect(try await store.get(id: note.id)?.summaries.isEmpty == true)
    }
    @Test func longSummaryRetainsLateDecisionsAndPIIMasksTheEntireIdentifier() async throws {
        let source = String(repeating: "Source context. ",count: 6000) + "TAIL_DECISION"
        let result = try await NoteAIProcessing.summarize(source,prompt: "Summary") { source,_ in source.contains("TAIL_DECISION") ? "TAIL_DECISION" : "Earlier context" }
        #expect(result == "TAIL_DECISION")
        let original = "Identifier 12345678901234567X is private"
        let envelope = try NotePII.redact(original)
        #expect(!envelope.text.contains("12345678901234567X"))
        #expect(envelope.restore(envelope.text) == original)
    }
    @Test func cancelledWorkflowImmediatelyReleasesItsCrossProcessLease() async throws {
        let (_,store) = try self.store()
        var note = WorkNote(title: "Cancel"); note.text = "Source"
        note = try await store.save(note)
        let job = try await store.enqueueWorkflow(note: note,mediaID: nil,settings: .init(),summaryPrompt: "Summary",steps: [.summary])
        let calls = NoteParityCalls()
        let runner = NoteWorkflowRunner(store: store) { _,_ in await calls.add("started"); try await Task.sleep(for: .seconds(60)); return "Too late" }
        let task = Task { try await runner.run(id: job.id,progress: { _ in }) }
        let deadline = Date().addingTimeInterval(5)
        while await calls.values.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await !calls.values.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let resumed = try await store.claimWorkflow(job.id,leased: true)
        #expect(resumed.stage == 0 && resumed.generation != job.generation)
        try await store.releaseWorkflow(resumed)
        #expect(try await store.get(id: note.id)?.summaries.isEmpty == true)
    }
    @Test @MainActor func printingUsesRenderedHeadingsAndTables() {
        let value = NotePrintDocument.attributed("# Title\n\n**Strong** body\n\n| A | B |\n|---|---|\n|one|two|\n\n```swift\nlet x = 1\n```")
        #expect(value.string.contains("Title") && !value.string.contains("# Title") && !value.string.contains("**Strong**"))
        #expect(value.string.contains("one") && value.string.contains("let x = 1"))
    }
    @Test @MainActor func newNoteClearsPreviousVisualsAndStoppedPlaybackCannotStartLate() async throws {
        let (queue,store) = try self.store()
        let model = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work,databaseQueue: queue)),space: .work)
        await model.create()
        model.frames = [.init(seconds: 2,jpeg: Data([1,2,3]))]
        model.transcriptionEngine = "whisper"; model.locale = "auto"; model.transcriptionEngine = "system"
        #expect(model.locale != "auto")
        await model.create()
        #expect(model.frames.isEmpty)
        let note = try #require(model.draft)
        try await store.addMedia(noteID: note.id,name: "audio.wav",data: Data([1,2,3]))
        model.media = try await store.media(noteID: note.id)
        model.play(try #require(model.media.first)); model.stopPlayback()
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.player == nil && model.error == nil)
    }
    @Test @MainActor func revokedSpeakerConsentCannotBeReusedByAnOldWorkflow() async throws {
        let (queue,store) = try self.store()
        let hub = Hub(spaceStore: SpaceStore(space: .work,databaseQueue: queue))
        let preferences = try #require(hub.makeProductPreferencesService(for: .work))
        var consent = NoteProcessingPreferences(); consent.voiceprintConsent = true
        try await preferences.save(consent,key: "notes.processing")
        let note = try await store.save(WorkNote(title: "Revoked consent")), mediaID = UUID()
        try await store.addMedia(id: mediaID,noteID: note.id,name: "audio.wav",data: Data([1,2,3]))
        var settings = NoteTranscriptionSettings(); settings.diarizationEnabled = true
        let job = try await store.enqueueWorkflow(note: note,mediaID: mediaID,settings: settings,summaryPrompt: "Summary",steps: [.transcription])
        consent.voiceprintConsent = false
        try await preferences.save(consent,key: "notes.processing")
        await #expect(throws: NoteVoiceprintError.consentRequired) { try await NoteWorkflowExecution.execute(hub: hub,space: .work,job: job) }
        let runner = NoteWorkflowRunner(store: store) { _,_ in "No inference" }
        await #expect(throws: NoteVoiceprintError.consentRequired) { try await runner.run(id: job.id,progress: { _ in }) }
        #expect(try await store.workflows().first?.stage == 0)
        #expect(try await store.speakerAnalysis(mediaID: mediaID) == nil)
    }
    @Test @MainActor func leavingThePageKeepsProcessingAndDirtyDraftOwnership() async throws {
        let (queue,_) = try self.store()
        let hub = Hub(spaceStore: SpaceStore(space: .work,databaseQueue: queue))
        var model: NotesModel? = NotesModel(hub: hub,space: .work)
        await model?.create()
        model?.draft?.text = "unsaved source"
        let retained = try #require(model)
        retained.run { try await Task.sleep(for: .milliseconds(30)); retained.draft?.text = "completed"; _ = await retained.save() }
        retained.leave(); model = nil
        let deadline = Date().addingTimeInterval(5)
        while retained.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!retained.busy && retained.draft?.text == "completed")
        #expect(try await retained.store?.get(id: retained.draft!.id)?.text == "completed")
    }
}

private actor NoteParityCalls {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
