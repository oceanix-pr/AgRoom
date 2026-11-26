import AVFoundation
import SwiftUI
import AgRoomCore

struct NotesLocalModelsView: View {
    enum Page { case models, speakers, privacy, speech }
    @Bindable var model: NotesModel
    var page: Page? = nil
    var embedded = false
    var sectionsOnly = false
    var scrollTarget: AnyHashable? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSpeaker = 0
    @State private var speakerName = ""
    @State private var privacyProviders: [LLMProviderConfig] = []
    @State private var deleting: NoteVoiceprint?
    var body: some View {
        Group {
            if sectionsOnly {
                sections.disabled(model.busy || model.recording)
            } else {
                VStack(alignment: .leading) {
                    if !embedded {
                        HStack {
                            Text(L.string("notes.local.models")).font(.title2)
                            Spacer()
                            Button(L.string("notes.close")) { dismiss() }
                        }
                    }
                    Form {
                        sections
                    }.formStyle(.grouped).disabled(model.busy || model.recording)
                    if model.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.transcriptionProgress ?? L.string("notes.processing"))
                            Button(L.string("notes.cancel")) { model.cancel() }
                        }
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
            }
        }.padding(embedded ? 0 : 20).frame(
            width: embedded ? nil : 620, height: embedded ? nil : 680
        )
        .task {
            if !sectionsOnly { await model.loadTranscriptionSettings() }
            if page == nil || page == .speakers { await model.loadVoiceprints() }
            if page == nil || page == .privacy {
                do { privacyProviders = try await model.hub.providerService?.getAll().filter { ["localhost","127.0.0.1","::1","[::1]"].contains(URLComponents(string: $0.endpoint)?.host?.lowercased() ?? "") } ?? [] } catch { model.report(error) }
            }
        }
        .onChange(of: model.speechVoiceID) {
            if page == nil || page == .speech { Task { await model.saveLocalPreferences() } }
        }
        .onChange(of: model.speechRate) {
            if page == nil || page == .speech { Task { await model.saveLocalPreferences() } }
        }
        .confirmationDialog(
            L.string("notes.voiceprint.delete"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(L.string("notes.delete"), role: .destructive) {
                if let deleting { model.deleteVoiceprint(deleting) }
                deleting = nil
            }
        }
    }

    @ViewBuilder private var sections: some View {
        if page == nil || page == .models {
            Section {
                Text(L.string("notes.whisper.hint"))
                Button(
                    L.string(
                        model.whisperBookmark == nil ? "notes.model.choose" : "notes.model.reselect"
                    )
                ) { model.chooseLocalModel(diarization: false) }
                Picker(L.string("notes.model.variant"), selection: $model.modelDownloadVariant) {
                    ForEach(
                        NoteWhisperEngine.variants,
                        id: \.self
                    ) { Text($0).tag($0) }
                }
                Picker(L.string("notes.model.source"),selection: $model.modelDownloadSource) {
                    Text("HF-Mirror").tag("https://hf-mirror.com")
                    Text("HuggingFace").tag("https://huggingface.co")
                }
                Button(L.string("notes.model.download")) { model.downloadWhisper() }
            } header: {
                if let scrollTarget {
                    Text(sectionsOnly ? L.string("notes.settings.models") : "WhisperKit").id(
                        scrollTarget)
                } else {
                    Text(sectionsOnly ? L.string("notes.settings.models") : "WhisperKit")
                }
            }
        }
        if page == nil || page == .speakers {
            Section {
                Toggle(
                    L.string("notes.settings.voiceprint.consent"),
                    isOn: $model.processingPreferences.voiceprintConsent
                )
                .onChange(of: model.processingPreferences.voiceprintConsent) { _, granted in
                    if !granted { model.revokeVoiceprintConsent() }
                    Task {
                        _ = await model.saveProcessingPreferences()
                        _ = await model.saveTranscriptionSettings()
                    }
                }
                Toggle(L.string("notes.speakers.auto"), isOn: $model.diarizationEnabled)
                    .disabled(!model.processingPreferences.voiceprintConsent)
                    .onChange(of: model.diarizationEnabled) {
                        Task { _ = await model.saveTranscriptionSettings() }
                    }
                Button(
                    L.string(
                        model.diarizationBookmark == nil
                            ? "notes.model.choose" : "notes.model.reselect")
                ) { model.chooseLocalModel(diarization: true) }
                Button(L.string("notes.model.download")) { model.downloadSpeakerModels() }
                Picker(L.string("notes.speakers.precision"),selection: $model.speakerPrecision) {
                    ForEach(NoteSpeakerPrecision.allCases,id: \.rawValue) { value in Text(L.string("notes.speakers.precision.\(value.rawValue)")).tag(value.rawValue) }
                }
                Stepper(L.format("notes.speakers.threads",model.speakerThreads),value: $model.speakerThreads,in: 1...16)
                Text(L.string("notes.speakers.hint")).font(.caption).foregroundStyle(.secondary)
            } header: {
                if let scrollTarget {
                    Text(L.string("notes.speakers")).id(scrollTarget)
                } else {
                    Text(L.string("notes.speakers"))
                }
            }
        }
        if page == nil || page == .privacy {
            Section(L.string("notes.privacy")) {
                Toggle(L.string("notes.privacy.enabled"), isOn: $model.redactText)
                Text(L.string("notes.privacy.hint")).font(.caption)
                TextEditor(text: $model.privateTerms).frame(height: 80)
                Picker(L.string("notes.privacy.localModel"),selection: $model.processingPreferences.privacyProviderID) {
                    Text(L.string("notes.speech.default")).tag(Optional<UUID>.none)
                    ForEach(privacyProviders) { Text($0.chatDisplayName).tag(Optional($0.id)) }
                }
                Button(L.string("notes.privacy.scan")) { model.scanPrivacy() }
                Button(L.string("notes.privacy.voiceNames")) { model.synchronizePrivateNames() }
                Button(L.string("notes.save")) {
                    Task { _ = await model.saveTranscriptionSettings() }
                }
            }
        }
        if page == nil || page == .speech {
            Section {
                Picker(L.string("notes.speech.voice"), selection: $model.speechVoiceID) {
                    Text(L.string("notes.speech.default")).tag("")
                    ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) {
                        Text($0.name + " · " + $0.language).tag($0.identifier)
                    }
                }
                Slider(value: $model.speechRate, in: 0.25...0.65) {
                    Text(L.string("notes.speech.rate"))
                }
            } header: {
                if let scrollTarget {
                    Text(L.string("notes.settings.speech")).id(scrollTarget)
                } else {
                    Text(L.string("notes.settings.speech"))
                }
            }
        }
        if page == nil || page == .speakers {
            Section(L.string("notes.voiceprints")) {
                HStack {
                    Button(L.string("notes.voiceprints.import")) { model.importVoiceprints() }.disabled(!model.processingPreferences.voiceprintConsent)
                    Button(L.string("notes.voiceprints.merge")) { model.mergeVoiceprints() }
                }
                if model.speakerResult == nil, let item = model.primaryMedia(model.media), model.draft?.segments.isEmpty == false {
                    Button(L.string("notes.speakers")) { model.analyzeSpeakers(item) }.disabled(!model.processingPreferences.voiceprintConsent)
                }
                if model.voiceprints.isEmpty {
                    Text(L.string("notes.voiceprints.empty")).foregroundStyle(.secondary)
                }
                if let result = model.speakerResult {
                    Picker(L.string("notes.speaker"), selection: $selectedSpeaker) {
                        ForEach(result.embeddings.keys.sorted(), id: \.self) {
                            Text("SPEAKER_\($0 + 1)").tag($0)
                        }
                    }
                    Button(L.string("notes.voiceprint.listen")) {
                        if let turn = result.turns.first(where: { $0.speaker == selectedSpeaker }) { model.playSegment(turn.start,until: turn.end) }
                    }
                    TextField(L.string("notes.voiceprint.name"), text: $speakerName)
                    Button(L.string("notes.voiceprint.register")) {
                        model.registerVoiceprint(speaker: selectedSpeaker, name: speakerName)
                    }.disabled(speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.voiceprints) { record in
                    HStack {
                        Text(record.name)
                        Spacer()
                        Button(role: .destructive) {
                            deleting = record
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }
}
