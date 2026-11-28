import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import ImageIO
import ScreenCaptureKit
import Security
import AgRoomCore

@MainActor @Observable
final class NotesModel {
    let hub: Hub
    let space: AppSpace
    let store: NoteStore?
    let jobs: JobCenter
    var notes: [WorkNote] = []
    private var lastSavedDraft: WorkNote? { didSet { refreshLifecycleOwnership() } }
    var draft: WorkNote? { didSet { refreshLifecycleOwnership() } }
    var media: [NoteMedia] = []
    var archived = false { didSet { if archived != oldValue { invalidatePages(clear: true) } } }
    var search = "" { didSet { if search != oldValue { invalidatePages(clear: true) } } }
    private var pageGeneration = UUID()
    private var nextPage: NoteStore.PageCursor?
    private var pageTask: Task<Void, Never>?
    private var savingDraft: Task<Bool, Never>?
    var busy = false { didSet { refreshLifecycleOwnership() } }
    var error: String?
    private let recordingOwner = UUID()
    var recording = false { didSet { NotesRecordingStatus.shared.set(recording,space: space,owner: recordingOwner); refreshLifecycleOwnership() } }
    var microphoneMuted = false
    func toggleMicrophoneMute() { microphoneMuted.toggle(); capture?.setMicrophoneMuted(microphoneMuted) }
    var captureOptions: NoteCaptureOptions {
        var options = NoteCaptureOptions()
        options.microphoneUID = localPreferences.microphoneUID ?? ""
        options.startMuted = localPreferences.startMuted ?? false
        options.autoMute = localPreferences.autoMute ?? false
        options.screenQuality = localPreferences.screenQuality ?? "standard"
        options.screenAudio = localPreferences.screenAudio ?? "mixed"
        return options
    }
    var locale = "zh-CN"
    var transcriptionEngine = "system" { didSet { if transcriptionEngine == "system", locale == "auto" { locale = "zh-CN" } } }
    var cloudTranscription: Bool { get { transcriptionEngine == "cloud" } set { transcriptionEngine = newValue ? "cloud" : "system" } }
    var whisperBookmark: Data?
    var diarizationBookmark: Data?
    var diarizationEnabled = false
    var speakerPrecision = 3
    var speakerThreads = 2
    var modelDownloadSource = "https://hf-mirror.com"
    var systemSpeechReady = false
    var modelDownloadVariant = "openai_whisper-base"
    var voiceprints: [NoteVoiceprint] = []
    var speakerResult: NoteSpeakerResult?
    private var analyzingSpeakers = false

    var cloudSTTModel = "whisper-1"
    var normalization = "none"
    var dictionary = ""
    var effectiveDictionary: String { ([dictionary] + (processingPreferences.dictionaryDocuments ?? []).map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n") }
    var effectivePrivateTerms: String { ([privateTerms] + ((try? NoteTranscriptDictionary(effectiveDictionary).privateTerms) ?? [])).filter { !$0.isEmpty }.joined(separator: "\n") }
    var transcriptionProgress: String?
    private var settingsLoaded = false
    var hasMore = false
    var player: AVPlayer?
    private var playbackDirectory: URL?
    private var playbackMediaID: UUID?
    private var playbackRequest = UUID()
    private let synthesizer = AVSpeechSynthesizer()
    var workflows: [NoteWorkflow] = []
    var pendingCleanup: NoteSourceCleanupPlan?
    var pendingMerge: NoteRecordingMergePlan?
    var pendingWorkflow: NoteWorkflowPlan?
    var pendingBatchPlans: [NoteWorkflowPlan] = []
    var allowBackground = true
    var partialSummary = ""
    var frames: [NoteVisualFrame] = []
    var pendingFileImport: NoteFilePackage?
    var importFailures: [String] = []
    var importCompleted = 0
    var importRemaining: [URL] = []
    var importDirectory: URL?
    var importAccess = false
    var importTemporaryRoot: URL?
    var importingArchive = false
    var speechPanel = false
    var playbackTime = 0.0
    private var playbackObserver: Any?
    private var pendingWorkflowSettings: NoteTranscriptionSettings?
    private var pendingGenerationProviderID: UUID?
    private var pendingSummaryPrompt = ""
    private var pendingTodoPrompt = ""
    private var terminating = false
    var batchSelection = Set<UUID>()
    private var batchQueue: [UUID] = []
    struct LocalPreferences: Codable {
        var mirrorBookmark: Data?
        var voiceID = ""
        var rate: Float = 0.5
        var echoReduction = true
        var captureMode: String?
        var reminderListID: String?
        var microphoneUID: String?
        var startMuted: Bool?
        var screenQuality: String?
        var screenAudio: String?
        var autoMute: Bool?
        var whisperSource: String?
    }
    var localPreferences = LocalPreferences()
    var mirrorWritten = 0

    private var workflowJobID: UUID?
    private var activeWorkflowID: UUID?
    private var workflowMonitor: Task<Void, Never>?
    var imageSelection: NoteImageSelection?
    var protectedArchiveMode: String?
    var protectedPackages: [NotePackage] = []
    var pendingImport: NotePackage?
    var redactText = false
    var privateTerms = ""
    var speechVoiceID = ""
    var speechRate: Float = 0.5
    var processingPreferences = NoteProcessingPreferences()
    var summaryTemplate: String {
        get { processingPreferences.summaryTemplate }
        set { processingPreferences.summaryTemplate = newValue }
    }
    var customSummaryPrompt: String {
        get { processingPreferences.customSummaryPrompt }
        set { processingPreferences.customSummaryPrompt = newValue }
    }
    var captureEchoReduction = true
    var captureReports: [NoteCaptureReport] = []
    var captureMode = NoteCaptureMode.microphone
    var recoverableCaptures: [NoteCaptureManifest] = []
    private var capture: NoteMeetingCapture?
    private var captureMonitor: Task<Void, Never>?

    private var operation: Task<Void, Never>?
    private var operationJobID: UUID?
    private let ocrPanel = NoteOCRPanel()
    private let imagePins = NoteImagePins()
    private var mcpServer: NoteMCPServer?
    var mcpPort = 0


    init(hub: Hub, space: AppSpace) {
        self.hub = hub; self.space = space; store = hub.makeNoteStore(for: space)
        jobs = store?.isInMemory == true ? .ephemeral() : .shared
        NotesLifecycle.register(self)
    }

    private func refreshLifecycleOwnership() { NotesLifecycle.setActive(self,active: busy || recording || (draft != nil && draft != lastSavedDraft)) }

    func report(_ error: Error, stage: String = "operation", captureNoteID: UUID? = nil) {
        let category: String
        if let speech = error as? TranscriptionService.TranscriptionError {
            switch speech {
            case .microphoneNotAuthorized: category = "microphone-permission"
            case .notAuthorized: category = "speech-permission"
            case .recognizerUnavailable: category = "recognizer-unavailable"
            case .noResult: category = "speech-no-result"
            }
        } else { category = "other" }
        HubLogger.shared.error("Notes operation failed: stage=\(stage), category=\(category), \(HubLogger.safeErrorSummary(error))")
        var message = L.actionableError(error, fallbackKey: "notes.error")
        if let captureNoteID, recoverableCaptures.contains(where: { $0.noteID == captureNoteID && !$0.parts.isEmpty }) {
            message += "\n\n" + L.string("notes.capture.retained")
        }
        self.error = message
    }

    private func invalidatePages(clear: Bool = false) {
        pageTask?.cancel()
        pageTask = nil
        pageGeneration = UUID()
        nextPage = nil
        hasMore = false
        if clear { notes = [] }
    }

    private func refreshList() async {
        invalidatePages()
        await reload()
    }

    func reload(more: Bool = false) async {
        guard let store else { report(NoteStoreError.missing); return }
        if let pageTask { await pageTask.value; return }
        if more && nextPage == nil { return }
        let generation = pageGeneration, after = more ? nextPage : nil
        let task = Task { [search, archived] in
            defer { if pageGeneration == generation { pageTask = nil } }
            do {
                let page = try await store.page(search: search, archived: archived, after: after)
                guard !Task.isCancelled, pageGeneration == generation else { return }
                if more {
                    var seen = Set(notes.map(\.id))
                    notes += page.notes.filter { seen.insert($0.id).inserted }
                } else { notes = page.notes }
                nextPage = page.next
                hasMore = page.next != nil
            } catch { if !Task.isCancelled && pageGeneration == generation { report(error) } }
        }
        pageTask = task
        await task.value
    }

    @discardableResult
    func save() async -> Bool {
        if let savingDraft { return await savingDraft.value }
        guard let id = draft?.id, draft != lastSavedDraft else { return true }
        guard let store else { report(NoteStoreError.missing); return false }
        let task = Task {
            defer { savingDraft = nil }
            do {
                // Share one writer between Save, navigation and quit. A continuously edited draft stays open.
                for _ in 0..<3 {
                    guard let note = draft, note.id == id else { return false }
                    let saved = try await store.save(note)
                    guard var current = draft, current.id == id, current.revision == note.revision,
                          current.versionToken == note.versionToken else { return false }
                    current.revision = saved.revision
                    current.versionToken = saved.versionToken
                    current.updatedAt = saved.updatedAt
                    lastSavedDraft = saved
                    draft = current
                    await refreshList()
                    if draft == saved { return true }
                }
            } catch { report(error) }
            return false
        }
        savingDraft = task
        return await task.value
    }

    func select(_ note: WorkNote) async {
        guard !busy, !recording else { return }
        busy = true; defer { busy = false }
        guard await save() else { return }
        do {
            guard let store, let current = try await store.get(id: note.id) else { throw NoteStoreError.missing }
            let attachments = try await store.media(noteID: note.id)
            stopPlayback()
            speakerResult = nil
            lastSavedDraft = current; draft = current; media = attachments
            await loadFrames()
        } catch { report(error) }
    }

    func create() async {
        guard !busy, !recording else { return }
        busy = true; defer { busy = false }
        guard await save() else { return }
        speakerResult = nil
        stopPlayback(); frames = []
        draft = WorkNote(title: L.string("notes.untitled")); media = []
        _ = await save()
    }

    func remove(_ note: WorkNote) async {
        guard !busy, !recording, let store else { return }
        busy = true; defer { busy = false }
        do {
            // The editor may contain unsaved changes; keep its current version check.
            let target = draft?.id == note.id ? draft! : note
            try await store.delete(target)
            if draft?.id == note.id {
                stopPlayback()
                synthesizer.stopSpeaking(at: .immediate)
                draft = nil; lastSavedDraft = nil; media = []; speakerResult = nil; captureReports = []; frames = []
            }
            batchSelection.remove(note.id)
            workflows.removeAll { $0.noteID == note.id }
            await refreshList()
        } catch { report(error) }
    }

    func togglePin(_ note: WorkNote) async {
        await updateFlags(note, pin: true)
    }

    func toggleArchive(_ note: WorkNote) async {
        await updateFlags(note, pin: false)
    }

    private func updateFlags(_ note: WorkNote, pin: Bool) async {
        guard !busy, !recording, let store else { return }
        busy = true; defer { busy = false }
        if draft?.id == note.id {
            if pin { draft?.pinned.toggle() } else { draft?.archived.toggle() }
            _ = await save()
            return
        }
        var target = note
        if pin { target.pinned.toggle() } else { target.archived.toggle() }
        do {
            _ = try await store.save(target)
            await refreshList()
        } catch { report(error) }
    }

    func run(stage: String = "operation", captureNoteID: UUID? = nil, _ action: @escaping @MainActor @Sendable () async throws -> Void) {
        guard !terminating, !busy, !recording else { return }
        busy = true
        let submission = jobs.submitTracked(name: L.string("notes.processing"), kind: "notes-" + stage, space: space,
                                            origin: "notes", historyStore: hub.makeJobRunStore(for: space)) { [weak self] _ in
            do { try Task.checkCancellation(); try await action() }
            catch is CancellationError { throw CancellationError() }
            catch { await self?.report(error, stage: stage, captureNoteID: captureNoteID); throw error }
        }
        operationJobID = submission.id
        operation = Task { [weak self] in
            for await receipt in submission.completion {
                guard let self, operationJobID == submission.id else { return }
                reportJobFailure(receipt)
                operationJobID = nil
                operation = nil
                if workflowJobID == nil { busy = false }
            }
        }
    }
    private func reportJobFailure(_ receipt: JobOutcome) {
        if !receipt.historySaved { error = L.string("jobs.history.failed") }
        else if receipt.job.state == .failed, error == nil { error = L.string("notes.error") }
    }
    func cancel() {
        batchQueue = []; if let operationJobID { jobs.cancel(id: operationJobID) }
        if let workflowJobID { jobs.cancel(id: workflowJobID) }
        if !terminating, let activeWorkflowID, let store { Task { do { try await store.authorizeBackground([activeWorkflowID], enabled: false) } catch { report(error) } } }
    }

    func importFile() {
        guard draft != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .image, .audio, .movie, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { [self] in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try await attach(url)
        }
    }

    func attach(_ url: URL) async throws {
        guard let id = draft?.id, let store, await save() else { throw NoteStoreError.missing }
        try await store.addMediaFile(noteID: id, name: url.lastPathComponent, file: url)
        media = try await store.media(noteID: id)
        if ["txt", "md"].contains(url.pathExtension.lowercased()) {
            let data = try await Task.detached { try NoteCaptureRecoveryText.read(url) }.value
            if let text = String(data: data, encoding: .utf8) { draft?.text += "\n" + text; _ = await save() }
        }
    }

    func withMedia(_ item: NoteMedia, body: @escaping @MainActor (URL) async throws -> Void) async throws {
        guard let note = draft, let store else { throw NoteStoreError.missing }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("media").appendingPathExtension(URL(fileURLWithPath: item.name).pathExtension)
        try await store.writeMedia(noteID: note.id, id: item.id, to: url)
        try await body(url)
    }

    func invalidateRestoredSettings() {
        invalidatePages(clear: true)
        settingsLoaded = false
        processingPreferences.voiceprintConsent = false
        diarizationEnabled = false
        deactivateSpaceResources()
    }

    func loadTranscriptionSettings() async {
        guard !settingsLoaded else { return }
        do {
            do {
                let value = try await hub.makeProductPreferencesService(for: space)?.load(NoteTranscriptionSettings.self, key: "notes.transcription") ?? NoteTranscriptionSettings()
                try value.validate()
                locale = value.locale; normalization = value.normalization; dictionary = value.dictionary
                transcriptionEngine = value.effectiveEngine; cloudSTTModel = value.cloudModel ?? "whisper-1"
                redactText = value.redactText ?? false; privateTerms = value.privateTerms ?? ""
                whisperBookmark = value.whisperBookmark; diarizationBookmark = value.diarizationBookmark; diarizationEnabled = value.diarizationEnabled ?? false
                speakerPrecision = value.diarizationPrecision ?? 3; speakerThreads = value.diarizationThreads ?? 2
            }
            localPreferences = try await hub.makeProductPreferencesService(for: space)?.load(LocalPreferences.self, key: "notes.local") ?? LocalPreferences()
            modelDownloadSource = localPreferences.whisperSource ?? "https://hf-mirror.com"
            speechVoiceID = localPreferences.voiceID; speechRate = min(0.65, max(0.25, localPreferences.rate))
            captureEchoReduction = localPreferences.echoReduction
            processingPreferences = try await hub.makeProductPreferencesService(for: space)?.load(NoteProcessingPreferences.self, key: "notes.processing") ?? NoteProcessingPreferences()
            try processingPreferences.validate()
            captureMode = NoteCaptureMode(rawValue: localPreferences.captureMode ?? "") ?? .microphone
            settingsLoaded = true
        } catch { report(error) }
    }

    func saveTranscriptionSettings() async -> Bool {
        do {
            var value = NoteTranscriptionSettings(locale: locale, normalization: normalization, dictionary: dictionary)
            value.redactText = redactText; value.privateTerms = privateTerms
            value.engine = transcriptionEngine; value.whisperBookmark = whisperBookmark
            value.cloudModel = cloudTranscription ? cloudSTTModel : nil
            value.diarizationBookmark = diarizationBookmark; value.diarizationEnabled = diarizationEnabled
            value.diarizationPrecision = speakerPrecision; value.diarizationThreads = speakerThreads
            try value.validate()
            guard let preferences = hub.makeProductPreferencesService(for: space) else { throw NoteStoreError.missing }
            try await preferences.save(value, key: "notes.transcription")
            return true
        } catch { self.error = L.string("notes.dictionary.error"); return false }
    }

    func transcribe(_ item: NoteMedia) { prepareWorkflow(mediaID: item.id, steps: [.transcription]) }

    private func updateTranscriptionProgress(_ done: Int, _ total: Int) { transcriptionProgress = "\(done) / \(total)" }

    func exportSubtitles() {
        guard let segments = draft?.segments, !segments.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "transcript.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try NoteSubtitleExporter.srt(segments).write(to: url, atomically: true, encoding: .utf8) } catch { report(error) }
    }

    func ocr(_ item: NoteMedia) {
        run { [self] in
            let baseline = draft
            try await withMedia(item) { [self] url in
                let text = try await OCRService.recognizeCancellable(imageURL: url)
                try Task.checkCancellation()
                guard draft == baseline else { throw NoteStoreError.conflict }
                draft?.text += "\n" + text
                _ = await save()
            }
        }
    }

    func summarize(todos: Bool = false) { prepareWorkflow(mediaID: nil, steps: [todos ? .todos : .summary]) }

    func polishTitle() { prepareWorkflow(mediaID: nil, steps: [.title]) }

    func chooseLocalModel(diarization: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let bookmark = try NoteModelAccess.bookmark(folder)
            if diarization { diarizationBookmark = bookmark } else { whisperBookmark = bookmark; transcriptionEngine = "whisper" }
            Task { _ = await saveTranscriptionSettings() }
        } catch { report(error) }
    }
    func downloadWhisper() {
        run { [self] in
            guard let root = hub.noteCaptureRoot(for: space)?.deletingLastPathComponent().appendingPathComponent("note-models/whisper") else { throw NoteStoreError.missing }
            let variant = modelDownloadVariant
            let folder = try await NoteWhisperEngine.download(variant: variant, to: root, endpoint: modelDownloadSource) { [weak self] fraction in
                Task { @MainActor in self?.transcriptionProgress = String(format: "%.0f%%", fraction * 100) }
            }
            whisperBookmark = try NoteModelAccess.bookmark(folder); transcriptionEngine = "whisper"
            _ = await saveTranscriptionSettings(); transcriptionProgress = nil
        }
    }
    func downloadSpeakerModels() {
        run { [self] in
            guard let root = hub.noteCaptureRoot(for: space)?.deletingLastPathComponent().appendingPathComponent("note-models/speakers") else { throw NoteStoreError.missing }
            defer { transcriptionProgress = nil }
            let folder = try await NoteSpeakerModels.download(to: root) { [weak self] progress in await self?.updateSpeakerProgress(progress) }
            diarizationBookmark = try NoteModelAccess.bookmark(folder)
            _ = await saveTranscriptionSettings()
        }
    }
    func loadVoiceprints() async {
        do { voiceprints = try await store?.voiceprints() ?? [] } catch { report(error) }
    }
    func analyzeSpeakers(_ item: NoteMedia) { run { [self] in try await analyzeSpeakersNow(item) } }
    func revokeVoiceprintConsent() {
        diarizationEnabled = false
        if analyzingSpeakers || workflows.contains(where: { $0.id == activeWorkflowID && $0.settings.diarizationEnabled == true }) { cancel() }
    }
    private func analyzeSpeakersNow(_ item: NoteMedia) async throws {
        guard processingPreferences.voiceprintConsent else { throw NoteVoiceprintError.consentRequired }
        analyzingSpeakers = true; defer { analyzingSpeakers = false }
        guard let bookmark = diarizationBookmark else { throw NoteStoreError.missing }
        let folder = try NoteModelAccess.resolve(bookmark)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let baseline = draft
        try await withMedia(item) { [self] url in
            let result = try await NoteSpeakerAnalyzer().analyze(url: url, modelFolder: folder, precision: NoteSpeakerPrecision(rawValue: speakerPrecision) ?? .standard, threads: speakerThreads) { [weak self] progress in
                await self?.updateSpeakerProgress(progress)
            }
            try Task.checkCancellation()
            guard processingPreferences.voiceprintConsent else { throw NoteVoiceprintError.consentRequired }
            guard draft == baseline, let store else { throw NoteStoreError.conflict }
            try await store.saveSpeakerAnalysis(result,mediaID: item.id)
            let voices = try await store.voiceprints()
            draft?.segments = NoteVoiceprintMath.apply(result, to: draft?.segments ?? [], voices: voices)
            speakerResult = result
            _ = await save()
        }
        transcriptionProgress = nil
    }
    private func updateSpeakerProgress(_ progress: Double) { transcriptionProgress = String(format: "%.0f%%", progress * 100) }
    func registerVoiceprint(speaker: Int, name: String) {
        run { [self] in
            guard processingPreferences.voiceprintConsent, let result = speakerResult, let embedding = result.embeddings[speaker], let store else { throw NoteStoreError.missing }
            try await store.registerVoiceprint(NoteVoiceprint(name: name, embedding: embedding, modelID: result.modelID))
            if let indices = draft?.segments.indices {
                for index in indices {
                    let segment = draft!.segments[index]
                    let end = segment.endTimestamp ?? (index + 1 < draft!.segments.count ? draft!.segments[index + 1].timestamp : segment.timestamp + 0.01)
                    if let turn = result.turns.max(by: { max(0,min(end,$0.end) - max(segment.timestamp,$0.start)) < max(0,min(end,$1.end) - max(segment.timestamp,$1.start)) }), turn.speaker == speaker, min(end,turn.end) > max(segment.timestamp,turn.start) { draft?.segments[index].speaker = name }
                }
            }
            _ = await save()
            await loadVoiceprints()
        }
    }
    func deleteVoiceprint(_ record: NoteVoiceprint) {
        run { [self] in guard let store else { throw NoteStoreError.missing }; try await store.deleteVoiceprint(id: record.id); await loadVoiceprints() }
    }

    func loadCaptureReports() async {
        guard let note = draft else { captureReports = []; return }
        do { captureReports = try await store?.captureReports(noteID: note.id) ?? [] } catch { report(error) }
    }
    func loadCaptureRecovery() {
        guard let root = hub.noteCaptureRoot(for: space) else { return }
        do { recoverableCaptures = try NoteCaptureRecovery(root: root).sessions() } catch { report(error) }
    }

    func recoverCapture(_ manifest: NoteCaptureManifest) {
        run { [self] in
            guard let root = hub.noteCaptureRoot(for: space), let store else { throw NoteStoreError.missing }
            try await NoteCaptureRecovery(root: root).recover(manifest, store: store)
            loadCaptureRecovery()
            if draft?.id == manifest.noteID { media = try await store.media(noteID: manifest.noteID) }
            await refreshList()
        }
    }

    func discardCapture(_ manifest: NoteCaptureManifest) {
        guard let root = hub.noteCaptureRoot(for: space) else { return }
        do { try NoteCaptureRecovery(root: root).discard(manifest); loadCaptureRecovery() } catch { report(error) }
    }

    func revealCaptureRecovery() {
        if let root = hub.noteCaptureRoot(for: space) { NSWorkspace.shared.open(root) }
    }

    func toggleRecording() {
        if recording {
            recording = false
            captureMonitor?.cancel(); captureMonitor = nil
            let current = capture
            run(stage: "capture-stop", captureNoteID: draft?.id) { [self] in
                guard let manifest = await current?.stop(), let store, let root = hub.noteCaptureRoot(for: space) else { return }
                loadCaptureRecovery()
                try await NoteCaptureRecovery(root: root).recover(manifest, store: store)
                loadCaptureRecovery()
                media = try await store.media(noteID: manifest.noteID)
                if let failure = current?.failure { report(failure, stage: "capture-stop", captureNoteID: manifest.noteID) }
            }
        } else {
            run(stage: "capture-start", captureNoteID: draft?.id) { [self] in
                guard await save(), let note = draft, let root = hub.noteCaptureRoot(for: space) else { return }
                let current = NoteMeetingCapture(root: root)
                capture = current
                do {
                    let filter = captureMode == .screen ? try await NotesScreenPicker().choose().filter : nil
                    try await current.start(noteID: note.id, mode: captureMode, screenFilter: filter, echoReduction: captureEchoReduction, options: captureOptions)
                    microphoneMuted = captureOptions.startMuted
                    try Task.checkCancellation()
                } catch { _ = await current.stop(); loadCaptureRecovery(); throw error }
                recording = true
                draft?.sourceDate = Date()
                draft?.sourceTimeZone = TimeZone.current.identifier
                _ = await save()
                captureMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self else { return }
                        if current.manifest == nil {
                            self.recording = false
                            self.loadCaptureRecovery()
                            if let failure = current.failure { self.report(failure, stage: "capture-monitor", captureNoteID: note.id) }
                            return
                        }
                    }
                }
            }
        }
    }

    func export() {
        guard let draft else { return }
        export(draft)
    }

    func export(_ note: WorkNote) {
        let draft = self.draft?.id == note.id ? self.draft! : note
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "note.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.markdown.write(to: url, atomically: true, encoding: .utf8) } catch { report(error) }
    }

    func exportMedia(_ item: NoteMedia) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { [self] in
            guard let id = draft?.id, let store else { throw NoteStoreError.missing }
            let staging = url.deletingLastPathComponent().appendingPathComponent(".note-export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await store.writeMedia(noteID: id, id: item.id, to: staging)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: url) }
        }
    }

    func sendReminder(_ id: UUID) {
        run { [self] in
            guard let todo = draft?.todos.first(where: { $0.id == id }), todo.reminderID == nil else { return }
            let link = todo.url.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let details = [draft?.title, todo.owner, todo.notes, todo.evidenceQuote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let reminderID = try await RemindersService().create(title: todo.title, notes: details, dueDate: todo.dueDate, priority: todo.priority ?? 0, url: link, alarmOffsetMinutes: todo.alarmOffsetMinutes, calendarID: localPreferences.reminderListID)
            if let index = draft?.todos.firstIndex(where: { $0.id == id }) {
                draft?.todos[index].reminderID = reminderID
                _ = await save()
            }
        }
    }

    func importDictionary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        run { [self] in
            var documents = processingPreferences.dictionaryDocuments ?? []
            var totalBytes = documents.reduce(0) { $0 + $1.text.utf8.count }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                let files = isDirectory ? try FileManager.default.contentsOfDirectory(at: url,includingPropertiesForKeys: nil).filter { ["txt","md"].contains($0.pathExtension.lowercased()) } : [url]
                guard documents.count + files.count <= 100 else { throw NoteStoreError.tooLarge }
                for file in files {
                    let data = try await Task.detached { try NoteCaptureRecoveryText.read(file) }.value
                    totalBytes += data.count; guard totalBytes <= 32_768 else { throw NoteStoreError.tooLarge }
                    guard let text = String(data: data,encoding: .utf8) else { throw NoteStoreError.invalidContent }
                    _ = try NoteTranscriptDictionary(text)
                    documents.append(.init(name: file.deletingPathExtension().lastPathComponent,text: text))
                }
            }
            let original = processingPreferences.dictionaryDocuments
            processingPreferences.dictionaryDocuments = documents
            guard await saveProcessingPreferences() else { processingPreferences.dictionaryDocuments = original; return }
        }
    }

    func synchronizePrivateNames() {
        run { [self] in
            guard let store else { throw NoteStoreError.missing }
            let names = try await store.voiceprints().map(\.name)
            let combined = Set(privateTerms.components(separatedBy: .newlines) + names).filter { !$0.isEmpty }.sorted().joined(separator: "\n")
            guard combined.utf8.count <= 32_768 else { throw NoteStoreError.tooLarge }
            privateTerms = combined; _ = await saveTranscriptionSettings()
        }
    }
    func scanPrivacy() {
        run { [self] in
            guard let store, let provider = try await hub.makeConfiguredProvider(for: space,configurationID: processingPreferences.privacyProviderID ?? processingPreferences.summaryProviderID,source: "notes-private-scan") else { throw LLMError.providerUnavailable }
            var found = Set(privateTerms.components(separatedBy: .newlines))
            for archived in [false,true] {
                var offset = 0
                while true {
                    let notes = try await store.list(archived: archived,offset: offset)
                    guard !notes.isEmpty else { break }
                    for note in notes { found.formUnion(try await NotePrivacyScanner.scan(note.sourceText,provider: provider)) }
                    offset += notes.count; if notes.count < 100 { break }
                }
            }
            let value = found.filter { !$0.isEmpty }.sorted().joined(separator: "\n")
            guard found.count <= 500, value.utf8.count <= 32_768 else { throw NoteStoreError.tooLarge }
            privateTerms = value; _ = await saveTranscriptionSettings()
        }
    }
    func mergeVoiceprints() { run { [self] in guard let store else { return }; try await store.mergeVoiceprintNames(); await loadVoiceprints() } }
    func importVoiceprints() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let root = panel.url else { return }
        run { [self] in
            guard processingPreferences.voiceprintConsent, let store else { throw NoteStoreError.invalidContent }
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            _ = try await store.importLegacyVoiceprints(directory: root)
            await loadVoiceprints()
        }
    }
    func prepareSystemSpeech() { run { [self] in try await NoteSystemSpeech.prepare(locale: locale); systemSpeechReady = await NoteSystemSpeech.installed(locale: locale) } }

    func exportDictionary() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "dictionary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rules = effectiveDictionary
        run {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await Task.detached {
                try NoteTranscriptionSettings(dictionary: rules).validate()
                try Data(rules.utf8).write(to: url, options: .atomic)
            }.value
        }
    }

    func loadWorkflows() async {
        do { workflows = try await store?.workflows() ?? [] } catch { report(error) }
    }
    func enqueueWorkflow(mediaID: UUID?) { prepareWorkflow(mediaID: mediaID) }

    func prepareWorkflow(mediaID: UUID?, steps: [NoteWorkflowStep]? = nil) {
        run { [self] in
            guard await save(), let note = draft, let store else { throw NoteStoreError.missing }
            let files = try await store.media(noteID: note.id)
            let primary = mediaID.flatMap { id in files.first { $0.id == id } } ?? primaryMedia(files)
            var plan = NoteWorkflowPlan.make(note: note, media: primary, title: note.title == L.string("notes.untitled"))
            if let steps {
                var chosen = steps
                if note.sourceText.isEmpty, let primary, steps.contains(where: { [.summary,.todos,.title].contains($0) }) {
                    let ext = URL(fileURLWithPath: primary.name).pathExtension.lowercased()
                    chosen.insert(OCRService.supportedExtensions.contains(ext) ? .visual : .transcription,at: 0)
                }
                plan = .init(note: note,mediaID: primary?.id,steps: chosen,skipped: [])
            }
            guard !plan.steps.isEmpty else { return }
            pendingWorkflowSettings = try await workflowSettings()
            pendingGenerationProviderID = processingPreferences.summaryProviderID
            if pendingGenerationProviderID == nil { pendingGenerationProviderID = try await hub.providerService?.activeConfiguration()?.id }
            pendingSummaryPrompt = processingPreferences.summaryPrompt
            pendingTodoPrompt = processingPreferences.effectiveTodoPrompt
            pendingBatchPlans = []
            pendingWorkflow = plan
        }
    }
    func primaryMedia(_ files: [NoteMedia]) -> NoteMedia? {
        files.first { $0.name == "meeting.m4a" } ?? files.first { ["mp4","mov","m4v"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
        ?? files.first { ["m4a","wav","mp3","aac","caf","flac"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
        ?? files.first { OCRService.supportedExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
    }
    func confirmWorkflow() {
        guard let plan = pendingWorkflow, let settings = pendingWorkflowSettings else { return }
        pendingWorkflow = nil
        run { [self] in
            guard let store, try await store.get(id: plan.note.id) == plan.note else { throw NoteStoreError.conflict }
            let plans = pendingBatchPlans.isEmpty ? [plan] : pendingBatchPlans
            var jobs: [NoteWorkflow] = []
            for item in plans where !item.steps.isEmpty {
                guard try await store.get(id: item.note.id) == item.note else { throw NoteStoreError.conflict }
                jobs.append(try await store.enqueueWorkflow(note: item.note, mediaID: item.mediaID, settings: settings, summaryPrompt: pendingSummaryPrompt, todoPrompt: pendingTodoPrompt, generationProviderID: pendingGenerationProviderID, steps: item.steps, backgroundAllowed: allowBackground))
            }
            pendingBatchPlans = []
            await loadWorkflows()
            busy = false; operation = nil
            if let first = jobs.first { batchQueue = jobs.dropFirst().map(\.id); executeWorkflow(first) }
        }
    }

    private func workflowSettings() async throws -> NoteTranscriptionSettings {
        var settings = NoteTranscriptionSettings(locale: locale, normalization: normalization, dictionary: processingPreferences.dictionaryEnabled ? effectiveDictionary : "")
        if cloudTranscription {
            guard let provider = try await hub.makeConfiguredProvider(for: space, configurationID: processingPreferences.transcriptionProviderID, source: "notes-transcription") else { throw NoteStoreError.missing }
            settings.cloudProviderID = processingPreferences.transcriptionProviderID
                if settings.cloudProviderID == nil { settings.cloudProviderID = try await hub.providerService?.activeConfiguration()?.id }
                settings.cloudModel = cloudSTTModel; settings.providerIdentity = provider.transcriptionIdentity
        }
        settings.redactText = redactText; settings.privateTerms = effectivePrivateTerms
        settings.engine = transcriptionEngine; settings.whisperBookmark = whisperBookmark
        settings.diarizationBookmark = diarizationBookmark; settings.diarizationEnabled = diarizationEnabled && processingPreferences.voiceprintConsent
        settings.diarizationPrecision = speakerPrecision; settings.diarizationThreads = speakerThreads
        if transcriptionEngine == "whisper", let bookmark = whisperBookmark {
            let folder = try NoteModelAccess.resolve(bookmark)
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            settings.whisperIdentity = try await Task.detached { try NoteModelAccess.identity(folder) }.value
        }
        try settings.validate()
        return settings
    }
    func enqueueBatch() {
        run { [self] in
            guard await save(), let store else { throw NoteStoreError.missing }
            let selected = notes.filter { batchSelection.contains($0.id) }
            guard !selected.isEmpty, selected.count <= 100 else { throw NoteStoreError.invalidContent }
            var plans: [NoteWorkflowPlan] = []
            for row in selected {
                guard let note = try await store.get(id: row.id) else { throw NoteStoreError.missing }
                let files = try await store.media(noteID: note.id)
                let plan = NoteWorkflowPlan.make(note: note, media: primaryMedia(files), title: note.title == L.string("notes.untitled"))
                if !plan.steps.isEmpty { plans.append(plan) }
            }
            pendingWorkflowSettings = try await workflowSettings()
            pendingGenerationProviderID = processingPreferences.summaryProviderID
            if pendingGenerationProviderID == nil { pendingGenerationProviderID = try await hub.providerService?.activeConfiguration()?.id }
            pendingSummaryPrompt = processingPreferences.summaryPrompt; pendingTodoPrompt = processingPreferences.effectiveTodoPrompt
            pendingBatchPlans = plans; pendingWorkflow = plans.first
        }
    }
    func resumeBatch() {
        guard !busy, !recording else { return }
        if batchQueue.isEmpty { batchQueue = workflows.filter { !$0.finished }.map(\.id).reversed() }
        guard !batchQueue.isEmpty else { return }
        let id = batchQueue.removeFirst()
        if let job = workflows.first(where: { $0.id == id }) { executeWorkflow(job) }
    }
    @discardableResult
    func saveProcessingPreferences() async -> Bool {
        do {
            try processingPreferences.validate()
            guard let preferences = hub.makeProductPreferencesService(for: space) else { throw NoteStoreError.missing }
            try await preferences.save(processingPreferences, key: "notes.processing")
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func saveLocalPreferences() async -> Bool {
        localPreferences.captureMode = captureMode.rawValue
        localPreferences.voiceID = speechVoiceID; localPreferences.rate = speechRate; localPreferences.echoReduction = captureEchoReduction
        do {
            localPreferences.whisperSource = modelDownloadSource
            guard let preferences = hub.makeProductPreferencesService(for: space) else { throw NoteStoreError.missing }
            try await preferences.save(localPreferences, key: "notes.local")
            return true
        } catch { report(error); return false }
    }
    func chooseMirror() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run { [self] in
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let sourceSpace = space.rawValue
            try await Task.detached { try NoteFolderMirror.prepare(folder, space: sourceSpace) }.value
            localPreferences.mirrorBookmark = try NoteModelAccess.bookmark(folder)
            await saveLocalPreferences()
        }
    }
    func syncMirror() {
        run { [self] in
            guard await save(), let store, let bookmark = localPreferences.mirrorBookmark else { throw NoteStoreError.missing }
            let folder = try NoteModelAccess.resolve(bookmark)
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            mirrorWritten = 0
            for archive in [false, true] {
                var offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await store.list(archived: archive, offset: offset)
                    for note in page {
                        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
                        defer { try? FileManager.default.removeItem(at: staging) }
                        let package = try await store.filePackage(id: note.id,in: staging)
                        if try await NoteFolderMirror.writeFiles(package,to: folder,space: space.rawValue) { mirrorWritten += 1 }
                    }
                    guard page.count == 100 else { break }
                    offset += page.count
                }
            }
        }
    }
    func executeWorkflow(_ job: NoteWorkflow) {
        guard !terminating, !busy, !recording, store != nil else { return }
        busy = true
        let baseline = draft
        let sourceSpace = space
        partialSummary = ""
        activeWorkflowID = job.id
        let submission = jobs.submitTracked(name: L.string("notes.pipeline"), kind: "notes-workflow", space: space,
                                            origin: "notes", historyStore: hub.makeJobRunStore(for: space)) { [weak self, hub] context in
            do {
                try await NoteWorkflowExecution.execute(hub: hub, space: sourceSpace, job: job, progress: { context.reportProgress($0) },
                    partial: { [weak self] text in await self?.updatePartialSummary(text) })
                context.reportResult(await MainActor.run { L.string("notes.pipeline.done") })
            } catch {
                if !(error is CancellationError) { await self?.report(error) }
                throw error
            }
        }
        workflowJobID = submission.id
        workflowMonitor = Task { [weak self] in
            for await receipt in submission.completion {
                guard let self, workflowJobID == submission.id else { return }
                reportJobFailure(receipt)
                await workflowFinished(baseline: baseline, succeeded: receipt.job.state == .succeeded && receipt.historySaved)
            }
        }
    }

    private func workflowFinished(baseline: WorkNote?, succeeded: Bool) async {
        if draft == baseline, let id = baseline?.id {
            do {
                let saved = try await store?.get(id: id)
                if draft == baseline { lastSavedDraft = saved; draft = saved }
            } catch { report(error) }
        }
        await loadWorkflows(); await refreshList(); await loadFrames()
        activeWorkflowID = nil
        workflowJobID = nil
        workflowMonitor = nil
        partialSummary = ""
        busy = false
        if succeeded, !terminating, hub.spaceStore.current == space, !batchQueue.isEmpty {
            let id = batchQueue.removeFirst()
            if let next = workflows.first(where: { $0.id == id && !$0.finished }) { executeWorkflow(next) }
        } else { batchQueue = [] }
    }

    func exportSpeech() { speechPanel = true }

    func pinImage(_ data: Data) { do { try imagePins.show(data) } catch { report(error) } }

    func printNote() {
        guard let note = draft else { return }
        NotePrintDocument.print(note.markdown)
    }

    func protectedArchive(password: String, importing: Bool) {
        if importing {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            guard panel.runModal() == .OK, let archive = panel.url else { return }
            closeFileImport()
            run { [self] in
                let access = archive.startAccessingSecurityScopedResource(); defer { if access { archive.stopAccessingSecurityScopedResource() } }
                let (root, entries) = try await NoteProtectedArchive.stageFiles(from: archive,password: password)
                importTemporaryRoot = root; importRemaining = entries; importingArchive = true
                try await nextFileImport()
            }
        } else {
            guard let id = draft?.id else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "note.memontabackup"
            guard panel.runModal() == .OK, let target = panel.url else { return }
            run { [self] in
                guard await save(), let store else { throw NoteStoreError.missing }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let package = try await store.filePackage(id: id,in: root)
                try await NoteProtectedArchive.exportFiles(package,to: target,password: password)
            }
        }
    }

    func exportPackage() {
        guard let id = draft?.id else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "note.zwnote"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        run { [self] in
            guard await save(), let store else { throw NoteStoreError.missing }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let package = try await store.filePackage(id: id, in: root)
            try await package.write(to: target)
        }
    }

    func previewImport(legacy: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let root = panel.url else { return }
        closeFileImport()
        importDirectory = root; importAccess = root.startAccessingSecurityScopedResource()
        run { [self] in
            pendingFileImport = legacy ? try await NoteLegacyImporter.previewFiles(directory: root) : try await NoteFilePackage.read(root)
        }
    }
    func previewLegacyCollection() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let root = panel.url else { return }
        closeFileImport()
        importDirectory = root; importAccess = root.startAccessingSecurityScopedResource()
        importFailures = []; importCompleted = 0
        run { [self] in
            importRemaining = try await Task.detached { try NoteLegacyImporter.inventory(directory: root) }.value
            guard !importRemaining.isEmpty else { throw NoteStoreError.missing }
            try await nextFileImport()
        }
    }
    private func nextFileImport() async throws {
        pendingFileImport = nil
        while !importRemaining.isEmpty {
            try Task.checkCancellation()
            let file = importRemaining.removeFirst()
            do { pendingFileImport = importingArchive ? try await NoteProtectedArchive.previewFileEntry(file) : try await NoteLegacyImporter.previewFiles(directory: file); return }
            catch is CancellationError { importRemaining.insert(file, at: 0); throw CancellationError() }
            catch { importFailures.append(file.lastPathComponent + " · " + L.actionableError(error,fallbackKey: "notes.error")) }
        }
        if pendingFileImport == nil { closeFileImport(keepReport: true, force: true) }
    }
    func confirmFileImport(all: Bool) {
        run { [self] in
            guard let store, await save() else { throw NoteStoreError.missing }
            repeat {
                guard let package = pendingFileImport else { break }
                let note = try await store.importFiles(package)
                importCompleted += 1
                stopPlayback(); frames = []; speakerResult = nil
                lastSavedDraft = note; draft = note; media = try await store.media(noteID: note.id); archived = note.archived
                await refreshList(); await loadFrames()
                try await nextFileImport()
            } while all && pendingFileImport != nil
        }
    }
    func skipFileImport() { run { [self] in try await nextFileImport() } }
    func closeFileImport(keepReport: Bool = false, force: Bool = false) {
        guard !busy || force else { return }
        pendingFileImport = nil; importRemaining = []
        if importAccess { importDirectory?.stopAccessingSecurityScopedResource() }
        importDirectory = nil; importAccess = false; importingArchive = false
        if let root = importTemporaryRoot { try? FileManager.default.removeItem(at: root) }; importTemporaryRoot = nil
        if !keepReport { importCompleted = 0; importFailures = [] }
    }
    func importDropped(_ urls: [URL]) {
        guard !busy, !recording else { return }
        run { [self] in
            if draft == nil { draft = WorkNote(title: L.string("notes.untitled")); guard await save() else { return } }
            for url in urls.prefix(100) {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation(); try await attach(url)
            }
        }
    }
    func pasteNote() {
        guard !busy, !recording else { return }
        let text = NSPasteboard.general.string(forType: .string)
        let image = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff)
        run { [self] in
            guard await save(), let store else { throw NoteStoreError.missing }
            draft = WorkNote(title: L.string("notes.untitled")); media = []
            if let text { draft?.text = text }
            guard await save(), let id = draft?.id else { return }
            if let image { try await store.addMedia(noteID: id,name: "clipboard.png",data: image); media = try await store.media(noteID: id) }
        }
    }

    func confirmImport() {
        guard let package = pendingImport else { return }
        run { [self] in
            guard let store, await save() else { throw NoteStoreError.missing }
            draft = try await store.importPackage(package)
            media = try await store.media(noteID: draft!.id)
            if let index = protectedPackages.firstIndex(where: { $0.id == package.id }) { protectedPackages.remove(at: index) }
            pendingImport = protectedPackages.first
            archived = draft?.archived ?? false
            await refreshList()
        }
    }

    func removeMedia(_ item: NoteMedia) {
        run { [self] in
            guard let id = draft?.id, let store else { throw NoteStoreError.missing }
            stopPlayback()
            try await store.removeMedia(noteID: id, id: item.id)
            media = try await store.media(noteID: id)
        }
    }

    func planCleanup(ids: [UUID]) {
        run { [self] in guard await save(), let store else { throw NoteStoreError.missing }; pendingCleanup = try await store.planSourceCleanup(ids: ids) }
    }
    func confirmCleanup() {
        guard let plan = pendingCleanup else { return }; pendingCleanup = nil
        run { [self] in
            guard let store else { throw NoteStoreError.missing }
            try await store.applySourceCleanup(plan)
            if let id = draft?.id, plan.items.contains(where: { $0.note.id == id }) { stopPlayback(); draft = try await store.get(id: id); lastSavedDraft = draft; media = try await store.media(noteID: id) }
            await refreshList(); await loadFrames()
        }
    }
    func planMerge() {
        let ids = notes.filter { batchSelection.contains($0.id) }.map(\.id)
        run { [self] in guard await save(), let store else { throw NoteStoreError.missing }; pendingMerge = try await store.planRecordingMerge(ids: ids) }
    }
    func confirmMerge() {
        guard let plan = pendingMerge else { return }; pendingMerge = nil
        run { [self] in
            guard let store else { throw NoteStoreError.missing }
            let note = try await store.applyRecordingMerge(plan)
            stopPlayback(); speakerResult = nil; frames = []
            lastSavedDraft = note; draft = note; archived = note.archived; media = try await store.media(noteID: note.id); batchSelection = []
            await refreshList(); await loadFrames()
        }
    }

    func publishKnowledge() {
        run { [self] in
            guard let note = draft, let service = hub.makeKnowledgeService(for: space) else { throw NoteStoreError.missing }
            try await service.save(KnowledgeItem(title: note.title, content: note.markdown, tags: note.tags.split(separator: ",").map(String.init)))
        }
    }

    func editImage(_ item: NoteMedia) {
        run { [self] in
            guard let id = draft?.id, let store else { throw NoteStoreError.missing }
            let data = try await store.mediaData(noteID: id, id: item.id)
            guard let image = NSImage(data: data) else { throw NoteStoreError.invalidContent }
            imageSelection = NoteImageSelection(image: image, name: item.name)
        }
    }
    func saveEditedImage(_ data: Data) {
        run { [self] in
            guard let id = draft?.id, let store else { throw NoteStoreError.missing }
            try await store.addMedia(noteID: id, name: "annotated.png", data: data)
            media = try await store.media(noteID: id)
        }
    }
    func analyzeVisuals(_ item: NoteMedia) { prepareWorkflow(mediaID: item.id, steps: [.visual]) }

    func updatePartialSummary(_ text: String) { partialSummary = text }
    func loadFrames() async {
        do {
            guard let store, let noteID = draft?.id else { frames = []; speakerResult = nil; return }
            let visualID = draft?.visualMediaID
            let result: NoteSpeakerResult?
            if let primary = primaryMedia(media) { result = try await store.speakerAnalysis(mediaID: primary.id) } else { result = nil }
            let samples: [NoteVisualFrame]
            if let visualID { samples = try await store.visualFrames(mediaID: visualID) } else { samples = [] }
            guard draft?.id == noteID, draft?.visualMediaID == visualID else { return }
            speakerResult = result; frames = samples
        } catch { report(error) }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.currentItem?.forwardPlaybackEndTime = .invalid
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }
    func playSegment(_ seconds: Double, until end: Double? = nil, mediaID: UUID? = nil) {
        let selected = mediaID.flatMap { id in media.first { $0.id == id } } ?? (mediaID == nil ? primaryMedia(media) : nil)
        guard let item = selected else { return }
        if playbackMediaID != item.id { stopPlayback() }
        let request = playbackRequest
        Task {
            if playbackMediaID != item.id {
                await startPlayback(item,request: request)
            }
            guard playbackRequest == request, playbackMediaID == item.id else { return }
            seek(seconds)
            if let end, end > seconds { player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end,preferredTimescale: 600) }
        }
    }
    private func startPlayback(_ item: NoteMedia, request: UUID) async {
        guard playbackRequest == request else { return }
        let noteID = draft?.id
        do {
            try await withMedia(item) { [self] source in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { if playbackDirectory != directory { try? FileManager.default.removeItem(at: directory) } }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try await NoteFileTransfer.copy(source, to: destination)
                guard playbackRequest == request, draft?.id == noteID, hub.spaceStore.current == space else { throw CancellationError() }
                playbackDirectory = directory; playbackMediaID = item.id; player = AVPlayer(url: destination)
                playbackObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor in guard let self, self.playbackRequest == request else { return }; self.playbackTime = time.seconds.isFinite ? time.seconds : 0 }
                }
                player?.play()
            }
        } catch is CancellationError {} catch { if playbackRequest == request { report(error) } }
    }

    func play(_ item: NoteMedia) { stopPlayback(); let request = playbackRequest; Task { await startPlayback(item,request: request) } }

    func stopPlayback() {
        playbackRequest = UUID(); playbackMediaID = nil
        if let playbackObserver { player?.removeTimeObserver(playbackObserver) }; playbackObserver = nil
        player?.pause(); player = nil; playbackTime = 0
        if let playbackDirectory { try? FileManager.default.removeItem(at: playbackDirectory) }
        playbackDirectory = nil
    }

    func speak() {
        synthesizer.stopSpeaking(at: .immediate)
        guard let draft else { return }
        let utterance = AVSpeechUtterance(string: NoteSpeechText.prepare(draft.sourceText))
        utterance.voice = AVSpeechSynthesisVoice(identifier: speechVoiceID) ?? AVSpeechSynthesisVoice(language: locale)
        utterance.rate = speechRate
        synthesizer.speak(utterance)
    }

    func captureSelection() {
        run(stage: "screen-capture") { [self] in
            guard let id = draft?.id, let store, await save() else { throw NoteStoreError.missing }
            let data = try await NoteSelectionCapture.image()
            try Task.checkCancellation()
            guard hub.spaceStore.current == space else { throw CancellationError() }
            try await store.addMedia(noteID: id, name: "selection.png", data: data)
            media = try await store.media(noteID: id)
            if let image = NSImage(data: data) { imageSelection = NoteImageSelection(image: image,name: "selection.png") }
        }
    }
    func pinOCR(_ item: NoteMedia) {
        run { [self] in
            try await withMedia(item) { [self] url in
                let text = try await OCRService.recognizeCancellable(imageURL: url)
                try Task.checkCancellation()
                guard hub.spaceStore.current == space else { throw CancellationError() }
                ocrPanel.show(text: text)
            }
        }
    }
    func generateMCPToken() {
        run { [self] in
            if let server = mcpServer { server.deactivate(); try await server.stop() }
            mcpPort = 0
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard status == errSecSuccess else { throw NoteStoreError.invalidContent }
            try KeychainService.setString(bytes.base64EncodedString(), account: "notes.mcp." + space.rawValue)
        }
    }
    func startMCP() {
        run { [self] in
            guard let store, let token = KeychainService.getString(account: "notes.mcp." + space.rawValue) else { throw NoteStoreError.missing }
            let server = NoteMCPServer(store: store); mcpServer = server
            try await server.start(token: token)
            guard hub.spaceStore.current == space, !Task.isCancelled else { server.deactivate(); try await server.stop(); throw CancellationError() }
            mcpPort = server.port
        }
    }
    func stopMCP() {
        let server = mcpServer; server?.deactivate(); mcpPort = 0
        Task { do { if let server { try await server.stop() } } catch { report(error) } }
    }
    func copyMCPConfiguration() {
        guard mcpPort > 0, let token = KeychainService.getString(account: "notes.mcp." + space.rawValue) else { return }
        let object = ["mcpServers": ["agroom-notes-" + space.rawValue: ["url": "http://127.0.0.1:\(mcpPort)/mcp", "headers": ["Authorization": "Bearer " + token]]]]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        } catch { report(error) }
    }
    func deactivateSpaceResources() {
        cancel(); speechPanel = false; pendingWorkflow = nil; pendingCleanup = nil; pendingMerge = nil
        Task { await operation?.value; _ = await finishCapture(); _ = await save(); closeFileImport(force: true) }
        imagePins.close()
        ocrPanel.close()
        let server = mcpServer; server?.deactivate(); mcpPort = 0
        Task { do { try await server?.stop() } catch { report(error) } }
    }

    func screenshot() {
        run { [self] in
            guard let id = draft?.id, let store, await save() else { throw NoteStoreError.missing }
            let image = try await OCRService.captureMainDisplay()
            let data = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw NoteStoreError.invalidContent }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw NoteStoreError.invalidContent }
            try Task.checkCancellation()
            try await store.addMedia(noteID: id, name: "screenshot.png", data: data as Data)
            media = try await store.media(noteID: id)
        }
    }

    func leave() {
        stopPlayback(); synthesizer.stopSpeaking(at: .immediate)
        if !busy && !recording { Task { _ = await save() } }
    }

    func prepareForTermination(timeout: Duration = .seconds(120)) async -> Bool {
        terminating = true
        let resume = ([activeWorkflowID].compactMap { $0 } + batchQueue)
        batchQueue = []
        if let workflowJobID { jobs.cancel(id: workflowJobID) }
        if let operationJobID { jobs.cancel(id: operationJobID) }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while operationJobID != nil || workflowJobID != nil {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { terminating = false; return false }
            let nextCheck = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(50)))
            do { try await Task.sleep(until: nextCheck, clock: .continuous) }
            catch { terminating = false; return false }
        }
        guard await finishCapture(), await save() else { terminating = false; return false }
        do {
            if !resume.isEmpty, let store {
                let remaining = try await store.workflows().filter { resume.contains($0.id) && !$0.finished && $0.backgroundAllowed == true }.map(\.id)
                if !remaining.isEmpty {
                    try await store.authorizeBackground(remaining, enabled: true)
                    try NoteBackgroundHandoff.publish(space: space, ids: remaining)
                }
            }
            return true
        } catch { report(error); terminating = false; return false }
    }
    func resumeAfterCancelledExit() { terminating = false }
    private func finishCapture() async -> Bool {
        captureMonitor?.cancel(); captureMonitor = nil
        let current = capture; capture = nil; recording = false
        guard let manifest = await current?.stop() else { return true }
        do {
            guard let store, let root = hub.noteCaptureRoot(for: space) else { throw NoteStoreError.missing }
            try await NoteCaptureRecovery(root: root).recover(manifest, store: store)
            loadCaptureRecovery()
            if draft?.id == manifest.noteID { media = try await store.media(noteID: manifest.noteID) }
            return true
        } catch { loadCaptureRecovery(); report(error, stage: "capture-stop", captureNoteID: manifest.noteID); return false }
    }


}
