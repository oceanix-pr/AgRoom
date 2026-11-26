import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

struct NoteSettingsTests {
    @Test @MainActor func preferencesReopenInTheirOwningSpaceAndPreserveLegacyLocalValues() async throws {
        let personalQueue = try DatabaseQueue(), workQueue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(personalQueue); try DatabaseBootstrap.prepareSpace(workQueue)
        let personalHub = Hub(spaceStore: SpaceStore(space: .personal, databaseQueue: personalQueue))
        let workHub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: workQueue))
        let first = NotesModel(hub: personalHub, space: .personal)
        await first.loadTranscriptionSettings()
        first.summaryTemplate = "custom"; first.customSummaryPrompt = "Keep decisions only"
        first.processingPreferences.todoPrompt = "Extract explicit tasks"
        first.processingPreferences.dictionaryEnabled = false
        first.processingPreferences.voiceprintConsent = true
        first.captureMode = .mixed
        first.localPreferences.reminderListID = "synthetic-list"
        first.localPreferences.microphoneUID = "synthetic-device"
        first.localPreferences.screenQuality = "compact"
        #expect(await first.saveProcessingPreferences())
        #expect(await first.saveLocalPreferences())
        let reopened = NotesModel(hub: personalHub, space: .personal)
        let work = NotesModel(hub: workHub, space: .work)
        await reopened.loadTranscriptionSettings(); await work.loadTranscriptionSettings()
        #expect(reopened.processingPreferences == first.processingPreferences)
        #expect(reopened.captureMode == .mixed)
        #expect(reopened.localPreferences.reminderListID == "synthetic-list")
        #expect(reopened.captureOptions.microphoneUID == "synthetic-device")
        #expect(reopened.captureOptions.screenQuality == "compact")
        #expect(work.summaryTemplate == "auto" && work.localPreferences.reminderListID == nil)
        var restoredPreferences = first.processingPreferences
        restoredPreferences.voiceprintConsent = false
        try await ProductPreferencesService(databaseQueue: personalQueue).save(restoredPreferences, key: "notes.processing")
        first.invalidateRestoredSettings()
        #expect(!first.processingPreferences.voiceprintConsent && !first.diarizationEnabled)
        await first.loadTranscriptionSettings()
        #expect(!first.processingPreferences.voiceprintConsent)
        let legacy = Data(#"{"voiceID":"legacy","rate":0.5,"echoReduction":true}"#.utf8)
        let decoded = try JSONDecoder().decode(NotesModel.LocalPreferences.self, from: legacy)
        #expect(decoded.voiceID == "legacy" && decoded.microphoneUID == nil && decoded.startMuted == nil)
    }

    @Test func queuedWorkflowUsesBothFrozenPromptsAfterPreferencesChange() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let store = NoteStore(databaseQueue: queue)
        var note = WorkNote(title: "Synthetic source"); note.text = "The review is assigned for next week."
        note = try await store.save(note)
        var preferences = NoteProcessingPreferences()
        preferences.summaryTemplate = "custom"; preferences.customSummaryPrompt = "Original summary"
        preferences.todoPrompt = "Original tasks"
        let job = try await store.enqueueWorkflow(note: note, mediaID: nil, settings: .init(), summaryPrompt: preferences.summaryPrompt, todoPrompt: preferences.effectiveTodoPrompt)
        preferences.customSummaryPrompt = "Changed summary"; preferences.todoPrompt = "Changed tasks"
        try await ProductPreferencesService(databaseQueue: queue).save(preferences, key: "notes.processing")
        let recorder = Prompts()
        try await NoteWorkflowRunner(store: store) { _, prompt in
            await recorder.append(prompt)
            return prompt.hasPrefix("Original summary") ? "Frozen summary" : "[\"Review draft\"]"
        }.run(id: job.id) { _ in }
        let prompts = await recorder.values
        #expect(prompts.count == 2)
        #expect(prompts[0].hasPrefix("Original summary") && prompts[1].hasPrefix("Original tasks"))
        #expect(!prompts.joined().contains("Changed"))
        let result = try #require(try await store.get(id: note.id))
        #expect(result.summaries.last?.text == "Frozen summary" && result.todos.last?.title == "Review draft")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        legacy.removeValue(forKey: "todoPrompt")
        let oldJob = try JSONDecoder().decode(NoteWorkflow.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(oldJob.todoPrompt == nil)
    }

    @Test func backupPreservesPromptsButRevokesVoiceprintConsent() async throws {
        let source = try DatabaseQueue(), target = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(source); try DatabaseBootstrap.prepareSpace(target)
        var preferences = NoteProcessingPreferences()
        preferences.customSummaryPrompt = "private-space-template"; preferences.voiceprintConsent = true
        try await ProductPreferencesService(databaseQueue: source).save(preferences, key: "notes.processing")
        let archive = try await SpaceDatabaseBackupStore(queue: source, space: "personal").export()
        let destination = SpaceDatabaseBackupStore(queue: target, space: "personal")
        let plan = try await destination.plan(archive, sourceSpace: "personal")
        let applied = try await destination.apply(plan) { _ in }; try await destination.verify(applied)
        let restored = try #require(try await ProductPreferencesService(databaseQueue: target).load(NoteProcessingPreferences.self, key: "notes.processing"))
        #expect(restored.customSummaryPrompt == "private-space-template" && !restored.voiceprintConsent)
    }
    private actor Prompts {
        var values: [String] = []
        func append(_ text: String) { values.append(text) }
    }
}
