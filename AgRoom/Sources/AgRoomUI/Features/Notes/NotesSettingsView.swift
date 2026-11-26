import SwiftUI
import AgRoomCore

/// Shared by the central Settings page and contextual shortcuts, always with the same space model.
struct NotesSettingsView: View {
    enum Page: String, CaseIterable {
        case transcription, recording, prompts, dictionary, models, speakers, speech, reminders
        var key: String { "notes.settings." + rawValue }
    }
    @Bindable var model: NotesModel
    var page: Page = .transcription
    @State private var lists: [RemindersService.ReminderList] = []
    @State private var authorized = false
    @State private var providers: [LLMProviderConfig] = []
    @State private var saved = false
    @State private var loading = true
    @State private var microphones: [NoteMicrophoneDevices.Device] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.format("settings.scope.space", L.string(model.space.nameKey)))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(
                    .top, 12)
            ScrollViewReader { proxy in
                Form {
                    ForEach(Page.allCases, id: \.self) { item in
                        content(for: item)
                    }
                }
                .formStyle(.grouped)
                .disabled(model.busy || model.recording)
                .task {
                    await model.loadTranscriptionSettings()
                    refreshLists()
                    do { providers = try await model.hub.providerService?.getAll() ?? [] } catch {
                        model.report(error)
                    }
                    loading = false
                    // Contextual shortcuts open this same page at the requested section.
                    if page != .transcription {
                        await Task.yield()
                        proxy.scrollTo(page, anchor: .top)
                    }
                }
            }
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(L.string("notes.cancel")) { model.cancel() }
                }
                if saved { Text(L.string("notes.settings.saved")).foregroundStyle(.secondary) }
                Spacer()
                Button(L.string("notes.save")) {
                    Task {
                        saved = false
                        model.error = nil
                        guard await model.saveProcessingPreferences(),
                            await model.saveTranscriptionSettings()
                        else { return }
                        saved = await model.saveLocalPreferences()
                    }
                }.disabled(model.busy || model.recording)
            }.padding(16)
            if let error = model.error {
                Text(error).foregroundStyle(.red).padding(.horizontal, 16)
            }
        }
        .disabled(loading || model.hub.spaceStore.current != model.space)
        .onChange(of: model.processingPreferences) { saved = false }
    }

    @ViewBuilder private func content(for page: Page) -> some View {
        switch page {
        case .models:
            NotesLocalModelsView(
                model: model, page: .models, embedded: true, sectionsOnly: true,
                scrollTarget: AnyHashable(page))
        case .speakers:
            NotesLocalModelsView(
                model: model, page: .speakers, embedded: true, sectionsOnly: true,
                scrollTarget: AnyHashable(page))
        case .speech:
            NotesLocalModelsView(
                model: model, page: .speech, embedded: true, sectionsOnly: true,
                scrollTarget: AnyHashable(page))

        case .transcription:
            Section {
                Picker(
                    L.string("notes.transcription.settings"), selection: $model.transcriptionEngine
                ) {
                    ForEach(["system", "cloud", "whisper"], id: \.self) {
                        Text(L.string("notes.engine." + $0)).tag($0)
                    }
                }
                Picker(L.string("notes.settings.language"),selection: $model.locale) {
                    if model.transcriptionEngine != "system" { Text(L.string("notes.language.auto")).tag("auto") }
                    ForEach(TranscriptionService.supportedLocales,id: \.locale.identifier) { Text($0.name).tag($0.locale.identifier) }
                }
                if model.transcriptionEngine == "system", NoteSystemSpeech.available {
                    Button(L.string("notes.systemSpeech.prepare")) { model.prepareSystemSpeech() }
                    if model.systemSpeechReady { Text(L.string("notes.systemSpeech.ready")).foregroundStyle(.secondary) }
                }
                if model.cloudTranscription {
                    providerPicker(selection: $model.processingPreferences.transcriptionProviderID)
                    TextField(L.string("notes.cloud.model"), text: $model.cloudSTTModel)
                    Text(L.string("notes.cloud.hint")).font(.caption)
                }
                Picker(L.string("notes.normalize"), selection: $model.normalization) {
                    ForEach(["none", "simplified", "traditional"], id: \.self) {
                        Text(L.string("notes.normalize." + $0)).tag($0)
                    }
                }
            } header: {
                Text(L.string("notes.transcription.settings")).id(page)
            }
        case .recording:
            Section {
                Picker(
                    L.string("notes.settings.microphone"),
                    selection: Binding(
                        get: { model.localPreferences.microphoneUID ?? "" },
                        set: { model.localPreferences.microphoneUID = $0 })
                ) {
                    Text(L.string("notes.settings.microphone.default")).tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if let uid = model.localPreferences.microphoneUID, !uid.isEmpty,
                        !microphones.contains(where: { $0.id == uid })
                    {
                        Text(L.string("notes.settings.microphone.missing")).tag(uid)
                    }
                }
                Toggle(
                    L.string("notes.settings.startMuted"),
                    isOn: Binding(
                        get: { model.localPreferences.startMuted ?? false },
                        set: { model.localPreferences.startMuted = $0 }))
                Toggle(
                    L.string("notes.settings.autoMute"),
                    isOn: Binding(
                        get: { model.localPreferences.autoMute ?? false },
                        set: { model.localPreferences.autoMute = $0 }))
                Picker(
                    L.string("notes.settings.quality"),
                    selection: Binding(
                        get: { model.localPreferences.screenQuality ?? "standard" },
                        set: { model.localPreferences.screenQuality = $0 })
                ) {
                    ForEach(["compact", "standard", "high"], id: \.self) {
                        Text(L.string("notes.settings.quality." + $0)).tag($0)
                    }
                }
                Picker(
                    L.string("notes.settings.screenAudio"),
                    selection: Binding(
                        get: { model.localPreferences.screenAudio ?? "mixed" },
                        set: { model.localPreferences.screenAudio = $0 })
                ) {
                    Text(L.string("notes.settings.screenAudio.none")).tag("none")
                    ForEach(["microphone", "system", "mixed"], id: \.self) {
                        Text(L.string("notes.capture." + $0)).tag($0)
                    }
                }
                Picker(L.string("notes.capture.mode"), selection: $model.captureMode) {
                    ForEach(NoteCaptureMode.allCases, id: \.self) {
                        Text(L.string("notes.capture." + $0.rawValue)).tag($0)
                    }
                }
                Toggle(L.string("notes.capture.echo"), isOn: $model.captureEchoReduction)
                Text(L.string("notes.settings.recording.hint")).font(.caption)
            } header: {
                Text(L.string("notes.settings.recording")).id(page)
            }
        case .dictionary:
            Section {
                Toggle(
                    L.string("notes.settings.dictionary.enabled"),
                    isOn: $model.processingPreferences.dictionaryEnabled)
                Text(L.string("notes.dictionary.hint")).font(.caption)
                TextEditor(text: $model.dictionary).font(.body.monospaced()).frame(minHeight: 160)
                NotesDictionaryDocuments(model: model)
                HStack {
                    Button(L.string("notes.settings.dictionary.import")) {
                        model.importDictionary()
                    }
                    Button(L.string("notes.settings.dictionary.export")) {
                        model.exportDictionary()
                    }
                }
            } header: {
                Text(L.string("notes.settings.dictionary")).id(page)
            }
        case .prompts:
            Section {
                providerPicker(selection: $model.processingPreferences.summaryProviderID)
                Picker(L.string("notes.summary.template"), selection: $model.summaryTemplate) {
                    ForEach(["auto", "meeting", "overview", "custom"], id: \.self) {
                        Text(L.string("notes.summary." + $0)).tag($0)
                    }
                }
                if model.summaryTemplate == "custom" {
                    TextEditor(text: $model.customSummaryPrompt).frame(minHeight: 160)
                }
                Text(L.string("notes.settings.todo.prompt")).font(.headline)
                TextEditor(text: $model.processingPreferences.todoPrompt).frame(minHeight: 140)
                Text(L.string("notes.settings.prompts.hint")).font(.caption)
                Button(L.string("notes.settings.prompts.reset")) {
                    model.summaryTemplate = "meeting"
                    model.customSummaryPrompt = ""
                    model.processingPreferences.todoPrompt = ""
                }
            } header: {
                Text(L.string("notes.settings.prompts")).id(page)
            }
        case .reminders:
            Section {
                if !authorized {
                    Button(L.string("notes.settings.reminders.authorize")) {
                        Task {
                            do {
                                try await RemindersService().requestAccess()
                                refreshLists()
                            } catch { model.report(error) }
                        }
                    }
                } else {
                    Picker(
                        L.string("notes.settings.reminders.list"),
                        selection: Binding(
                            get: { model.localPreferences.reminderListID ?? "" },
                            set: { model.localPreferences.reminderListID = $0 })
                    ) {
                        Text(L.string("notes.speech.default")).tag("")
                        ForEach(lists) { Text($0.title).tag($0.id) }
                        if let selected = model.localPreferences.reminderListID, !selected.isEmpty,
                            !lists.contains(where: { $0.id == selected })
                        {
                            Text(L.string("notes.settings.reminders.unavailable")).tag(selected)
                        }
                    }
                }
                Button(L.string("notes.refresh")) { refreshLists() }
                Text(L.string("notes.settings.reminders.hint")).font(.caption)
            } header: {
                Text(L.string("notes.settings.reminders")).id(page)
            }
        }
    }
    private func providerPicker(selection: Binding<UUID?>) -> some View {
        Picker(L.string("notes.settings.provider"), selection: selection) {
            Text(L.string("notes.settings.provider.active")).tag(nil as UUID?)
            ForEach(providers.filter(\.isEnabled)) {
                Text($0.name + " · " + $0.model).tag(Optional($0.id))
            }
            if let id = selection.wrappedValue,
                !providers.contains(where: { $0.id == id && $0.isEnabled })
            {
                Text(L.string("notes.settings.provider.unavailable")).tag(Optional(id))
            }
        }
    }
    private func refreshLists() {
        microphones = NoteMicrophoneDevices.available()
        let service = RemindersService()
        authorized = service.isAuthorized
        lists = service.availableLists()
    }
}
