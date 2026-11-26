import AppKit
import SwiftUI
import Foundation
import Testing
import GRDB
import Synchronization
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
struct NotesPresentationTests {
    private func pauseReads(on queue: DatabaseQueue) async -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { entered in
            DispatchQueue.global().async {
                try? queue.read { _ in
                    entered.resume()
                    _ = release.wait(timeout: .now() + 5)
                }
            }
        }
        return release
    }

    @Test func concurrentPagesKeepEveryNoteAndIgnoreEarlierSearchGeneration() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let model = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        let store = try #require(model.store)
        var all = Set<UUID>()
        for n in 0..<230 {
            var note = WorkNote(title: "item-\(n)")
            note.pinned = n.isMultiple(of: 37)
            all.insert(try await store.save(note).id)
        }
        model.search = "item"
        await model.reload()
        try #require(model.notes.count == 100 && model.hasMore)
        let release = await pauseReads(on: queue)
        let first = Task { await model.reload(more: true) }
        let second = Task { await model.reload(more: true) }
        await Task.yield()
        release.signal()
        await first.value; await second.value
        #expect(model.notes.count == 200 && model.hasMore)
        await model.reload(more: true)
        #expect(model.notes.count == 230 && Set(model.notes.map(\.id)) == all && !model.hasMore)

        let hold = await pauseReads(on: queue)
        let stale = Task { await model.reload() }
        await Task.yield()
        model.search = "other"; model.search = "item"
        hold.signal()
        await stale.value
        #expect(model.notes.isEmpty)
        await model.reload()
        let toPin = try #require(model.notes.first { !$0.pinned })
        await model.togglePin(toPin)
        while model.hasMore { await model.reload(more: true) }
        #expect(model.notes.first?.id == toPin.id)
        #expect(model.notes.count == 230 && Set(model.notes.map(\.id)) == all)
    }

    @Test func cleanNavigationAndConcurrentSavesPreserveRevisionAndEdits() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let model = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        let store = try #require(model.store)
        let a = try await store.save(WorkNote(title: "A")), b = try await store.save(WorkNote(title: "B"))
        await model.select(a); await model.select(b)
        #expect(try await store.get(id: a.id) == a)
        model.draft?.text = "one"
        let release = await pauseReads(on: queue)
        let first = Task { await model.save() }, second = Task { await model.save() }
        await Task.yield()
        release.signal()
        #expect(await first.value); #expect(await second.value)
        #expect(try await store.get(id: b.id)?.revision == b.revision + 1)
        model.draft?.text = "two"
        let hold = await pauseReads(on: queue)
        let save = Task { await model.save() }
        try await Task.sleep(for: .milliseconds(15))
        model.draft?.text = "latest"
        hold.signal()
        #expect(await save.value)
        let saved = try #require(try await store.get(id: b.id))
        #expect(saved.text == "latest" && model.draft == saved)
        var external = saved; external.text = "another window"
        _ = try await store.save(external)
        model.draft?.text = "unsaved local edit"
        await model.select(a)
        #expect(model.draft?.id == b.id && model.draft?.text == "unsaved local edit" && model.error != nil)
        model.draft = nil
    }

    @Test func cancelledNoteJobEndsAfterToolbarHistoryWasEvicted() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        var model: NotesModel? = NotesModel(hub: hub, space: .work)
        weak var observed = model
        let jobs = try #require(model?.jobs)
        let blockers = (0..<2).map { _ in jobs.submit(name: "block", kind: "hold", space: .work) { _ in try await Task.sleep(for: .seconds(10)) } }
        defer { for id in blockers { jobs.cancel(id: id) } }
        model?.run(stage: "eviction") { Issue.record("Cancelled queued work ran") }
        let job = try #require(jobs.snapshot(space: .work).first { $0.kind == "notes-eviction" })
        try #require(job.state == .queued)
        model?.cancel()
        let evicted = DispatchSemaphore(value: 0)
        let producer = Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !jobs.snapshot(space: .work).contains(where: { $0.id == job.id && $0.state.isFinished }) {
                guard .now < deadline else { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            for id in blockers { jobs.cancel(id: id) }
            for _ in 0..<25 { jobs.submit(name: "other", kind: "other", space: .work) { _ in } }
            while jobs.snapshot(space: .work).contains(where: { $0.id == job.id || !$0.state.isFinished }) {
                guard .now < deadline else { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            evicted.signal()
        }
        // Hold the UI consumer until the target receipt has disappeared from the toolbar.
        func awaitEviction() -> Bool { evicted.wait(timeout: .now() + 7) == .success }
        try #require(awaitEviction())
        try await producer.value
        #expect(await model?.prepareForTermination(timeout: .seconds(2)) == true)
        #expect(model?.busy == false)
        model = nil
        #expect(observed == nil)
    }

    @Test func quittingStalledOperationHasDeadlineAndReleasesModelAfterCompletion() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        var model: NotesModel? = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        let hub = try #require(model?.hub)
        weak var weakModel = model
        var resume: CheckedContinuation<Void, Never>?
        model?.run { await withCheckedContinuation { resume = $0 } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while resume == nil && .now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let signal = try #require(resume)
        #expect(await model?.prepareForTermination(timeout: .milliseconds(40)) == false)
        #expect(model?.busy == true)
        model = nil
        #expect(NotesLifecycle.retained(space: .work, hub: hub) === weakModel)
        signal.resume()
        while weakModel != nil && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(weakModel == nil && NotesLifecycle.retained(space: .work, hub: hub) == nil)
    }

    @Test func deniedOperationAndCancellationReleaseBusyStateWithoutChangingDraft() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let model = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        let original = WorkNote(title: "Keep this draft")
        model.draft = original
        // Inject failure at the operation boundary without requesting real system access.
        model.run(stage: "capture-start", captureNoteID: original.id) {
            throw TranscriptionService.TranscriptionError.microphoneNotAuthorized
        }
        while model.busy { await Task.yield() }
        #expect(model.error == L.string("error.actionable.microphone_permission"))
        #expect(!model.recording && model.draft == original && model.recoverableCaptures.isEmpty)
        model.error = nil
        model.run { throw CancellationError() }
        while model.busy { await Task.yield() }
        #expect(model.error == nil && !model.recording && model.draft == original)
    }

    @Test func permissionFailuresShowSpecificCausesAndOnlyRelevantRecoveryHints() throws {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let model = NotesModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)), space: .work)
        let noteID = UUID(), partID = UUID()
        let retained = NoteCaptureManifest(id: UUID(), noteID: noteID, startedAt: Date(), parts: [
            .init(id: partID, name: partID.uuidString + ".caf", offset: 0, source: "microphone")
        ])
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            model.recoverableCaptures = []
            model.report(TranscriptionService.TranscriptionError.microphoneNotAuthorized, stage: "capture-start", captureNoteID: noteID)
            #expect(model.error == L.string("error.actionable.microphone_permission"))
            model.report(TranscriptionService.TranscriptionError.notAuthorized)
            #expect(model.error == L.string("error.actionable.speech_permission"))
            model.report(OCRService.OCRError.screenCaptureNotPermitted)
            #expect(model.error == L.string("error.actionable.ocr_permission"))
            model.recoverableCaptures = [retained]
            model.report(TranscriptionService.TranscriptionError.microphoneNotAuthorized, captureNoteID: UUID())
            #expect(model.error == L.string("error.actionable.microphone_permission"))
            model.report(TranscriptionService.TranscriptionError.microphoneNotAuthorized, captureNoteID: noteID)
            #expect(model.error == L.string("error.actionable.microphone_permission") + "\n\n" + L.string("notes.capture.retained"))
            model.report(LLMError.providerUnavailable)
            #expect(model.error == L.string("error.actionable.provider_missing"))
            model.report(CocoaError(.fileWriteOutOfSpace))
            #expect(model.error == L.string("error.actionable.storage_full"))
            model.report(NoteStoreError.conflict)
            #expect(model.error == L.string("notes.conflict"))
            model.report(NSError(domain: "Private", code: 7, userInfo: [NSLocalizedDescriptionKey: "SECRET /private/path"]))
            #expect(model.error == L.string("notes.error"))
            #expect(model.recoverableCaptures.count == 1 && model.recoverableCaptures[0].parts.count == 1)
        }
    }

    @Test func deferredScreenshotBindsToMountedSpaceAndIsDeliveredOnce() {
        let navigation = AppNavigation()
        let requests = Mutex<[AppNavigation.CommandRequest]>([])
        let token = NotificationCenter.default.addObserver(forName: AppNavigation.CommandRequest.notification, object: nil, queue: nil) { notification in
            if let request = notification.object as? AppNavigation.CommandRequest { requests.withLock { $0.append(request) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        navigation.performInCurrentSpace(.noteScreenshot)
        #expect(requests.withLock { $0.isEmpty })
        navigation.deliverCommandIfNeeded(space: .work)
        #expect(requests.withLock { $0.count == 1 && $0.first?.space == .work && $0.first?.command == .noteScreenshot })
        navigation.deliverCommandIfNeeded(space: .personal)
        #expect(requests.withLock { $0.count == 1 })
    }

    @Test func notesAndCaptureMaterialUseSeparatePhysicalSpaceStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personalQueue = try DatabaseQueue(path: root.appendingPathComponent("personal.sqlite").path)
        let workQueue = try DatabaseQueue(path: root.appendingPathComponent("work.sqlite").path)
        try DatabaseBootstrap.prepareSpace(personalQueue); try DatabaseBootstrap.prepareSpace(workQueue)
        let personalHub = Hub(spaceStore: SpaceStore(space: .personal, databaseQueue: personalQueue), captureDirectoryRoot: root.appendingPathComponent("captures"))
        let workHub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: workQueue), captureDirectoryRoot: root.appendingPathComponent("captures"))
        let personal = try #require(personalHub.makeNoteStore(for: .personal)), work = try #require(workHub.makeNoteStore(for: .work))
        #expect(personalHub.makeNoteStore(for: .work) == nil && workHub.makeNoteStore(for: .personal) == nil)
        var personalNote = WorkNote(title: "Personal only"); personalNote.text = "Personal content"
        var workNote = personalNote; workNote.title = "Work only"; workNote.text = "Work content"
        personalNote = try await personal.save(personalNote); workNote = try await work.save(workNote)
        let mediaID = UUID()
        try await personal.addMedia(id: mediaID, noteID: personalNote.id, name: "source.txt", data: Data("personal".utf8))
        try await work.addMedia(id: mediaID, noteID: workNote.id, name: "source.txt", data: Data("work".utf8))
        #expect(try await personal.get(id: personalNote.id)?.text == "Personal content")
        #expect(try await work.get(id: workNote.id)?.text == "Work content")
        #expect(try await personal.mediaData(noteID: personalNote.id, id: mediaID) == Data("personal".utf8))
        #expect(try await work.mediaData(noteID: workNote.id, id: mediaID) == Data("work".utf8))
        #expect(try await personal.list(search: "Work content").isEmpty)
        #expect(try await work.list(search: "Personal content").isEmpty)
        let sessionID = UUID()
        let personalRoot = try #require(personalHub.noteCaptureRoot(for: .personal)), workRoot = try #require(workHub.noteCaptureRoot(for: .work))
        #expect(personalRoot != workRoot)
        for (directory, note) in [(personalRoot, personalNote), (workRoot, workNote)] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(sessionID.uuidString), withIntermediateDirectories: true)
            try NoteCaptureRecovery(root: directory).save(.init(id: sessionID, noteID: note.id, startedAt: Date(), parts: []))
        }
        try NoteCaptureRecovery(root: personalRoot).discard(try #require(NoteCaptureRecovery(root: personalRoot).sessions().first))
        #expect(try NoteCaptureRecovery(root: personalRoot).sessions().isEmpty)
        #expect(try NoteCaptureRecovery(root: workRoot).sessions().count == 1)
    }

    @Test func mountedEditorSurvivesDeletingItsDraft() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = NotesModel(hub: hub, space: .work)
        let store = try #require(model.store)
        let host = NSHostingView(rootView: NotesView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        for _ in 0..<3 {
            let note = try await store.save(WorkNote(title: "Delete mounted editor"))
            model.draft = note
            await model.reload()
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            await model.remove(note)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            #expect(model.draft == nil && model.error == nil)
            #expect(try await store.get(id: note.id) == nil)
        }
    }

    @Test func selectingARowRemovedBySavingTheSearchFilterKeepsCurrentVersion() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = NotesModel(hub: hub, space: .work)
        let store = try #require(model.store)
        let row = try await store.save(WorkNote(title: "Search match"))
        model.search = "Search match"; model.draft = row
        await model.reload()
        model.draft?.title = "Renamed"
        // Saving removes this row from the current search results before selection completes.
        await model.select(row)
        #expect(model.notes.isEmpty)
        #expect(model.draft?.title == "Renamed")
        #expect(model.draft?.revision == row.revision + 1)
        await model.remove(try #require(model.draft))
        #expect(model.error == nil)
        #expect(try await store.get(id: row.id) == nil)
    }

    @Test func rowActionsPreserveDraftAndDeleteOnlyTheirTarget() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = NotesModel(hub: hub, space: .work)
        let store = try #require(model.store)
        let first = try await store.save(WorkNote(title: "Editing"))
        let other = try await store.save(WorkNote(title: "Right clicked"))
        model.draft = first; model.draft?.text = "Unsaved text"
        await model.reload()
        await model.togglePin(other)
        #expect(try await store.get(id: other.id)?.pinned == true)
        #expect(model.draft?.text == "Unsaved text")
        let pinned = try #require(try await store.get(id: other.id))
        await model.toggleArchive(pinned)
        #expect(try await store.get(id: other.id)?.archived == true)
        let archived = try #require(try await store.get(id: other.id))
        model.batchSelection.insert(other.id)
        await model.remove(archived)
        #expect(model.error == nil)
        #expect(try await store.get(id: other.id) == nil)
        #expect(model.draft?.id == first.id && model.draft?.text == "Unsaved text")
        #expect(!model.batchSelection.contains(other.id))
        await model.togglePin(first)
        #expect(model.draft?.pinned == true)
        #expect(try await store.get(id: first.id)?.text == "Unsaved text")
        // A confirmation opened from an older row still uses the current editor version.
        await model.remove(first)
        #expect(model.error == nil && model.draft == nil)
        #expect(try await store.get(id: first.id) == nil)
    }

    @Test func deletingAStaleRowPreservesTheNewerNote() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = NotesModel(hub: hub, space: .work)
        let store = try #require(model.store)
        let old = try await store.save(WorkNote(title: "Original"))
        var newer = old; newer.text = "Changed elsewhere"
        newer = try await store.save(newer)
        await model.remove(old)
        #expect(model.error != nil)
        #expect(try await store.get(id: old.id) == newer)
    }

    @Test func narrowNotesPagesAndToolsUseIsolatedData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), captureDirectoryRoot: root)
        let store = try #require(hub.makeNoteStore(for: .work))
        var note = WorkNote(title: "Synthetic meeting / 合成会议")
        note.text = "Decisions, actions and open questions."
        note.transcript = "Synthetic transcript"
        note.summaries = [NoteSummary(text: "## Decisions\n\n- Review next week")]
        var todo = NoteTodo(title: "Review synthetic draft"); todo.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        note.todos = [todo]
        let saved = try await store.save(note)
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        let snapshotDirectory = ProcessInfo.processInfo.environment["AGROOM_NOTES_SNAPSHOT_DIR"]
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for tab in ["notes.text", "notes.summary", "notes.todos", "tools", "models", "archive", "workflow", "speech", "import"] + NotesSettingsView.Page.allCases.map({ "settings-" + $0.rawValue }) {
                let model = NotesModel(hub: hub, space: .work)
                model.draft = saved; model.notes = [saved]
                let view: AnyView
                switch tab {
                case let value where value.hasPrefix("settings-"):
                    view = AnyView(NotesSettingsView(model: model, page: NotesSettingsView.Page(rawValue: String(value.dropFirst(9))) ?? .transcription))
                case "tools": view = AnyView(NotesToolsView(model: model))
                case "models": view = AnyView(NotesLocalModelsView(model: model))
                case "archive": view = AnyView(NotesArchivePasswordView(model: model, importing: false))
                case "workflow":
                    let plan = NoteWorkflowPlan(note: saved,mediaID: nil,steps: [.transcription,.visual,.summary,.todos,.title],skipped: [])
                    view = AnyView(NotesWorkflowPreview(model: model,plan: plan))
                case "speech": view = AnyView(NoteSpeechPanel(model: model))
                case "import": view = AnyView(NoteFileImportPreview(model: model,package: .init(note: saved,media: [])))
                default: view = AnyView(NotesView(model: model, initialTab: tab))
                }
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0)
                if let snapshotDirectory {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("notes-\(language.rawValue)-\(tab).png"))
                }
                window.close()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
