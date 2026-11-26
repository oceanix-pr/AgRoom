import SwiftUI
import AVKit
import ImageIO
import AgRoomCore

struct NotesView: View {
    private struct ListQuery: Equatable { let search: String; let archived: Bool }
    @Bindable var model: NotesModel
    @Environment(\.globalSearchText) private var search
    @State private var settingsPage: NotesSettingsView.Page?
    @State private var showingTools = false
    @State private var showingDataSettings = false
    @State private var removingMedia: NoteMedia?
    @State private var tab = "notes.text"
    private let initialSection: String
    @State private var deletingNote: WorkNote?
    @State private var reminder: NoteTodo?
    @State private var editingTodo: NoteTodo?
    @State private var collapsedMonths = Set<Date>()
    @State private var batchMode = false
    @State private var listWidth = SplitColumnWidth.snapshot(key: "agroom.notes.listWidth", defaultValue: 320, range: 240...480)


    init(model: NotesModel, initialTab: String = "notes.text") {
        self.model = model
        self.initialSection = initialTab
        self._tab = State(initialValue: ["notes.text", "notes.transcript", "notes.media"].contains(initialTab) ? initialTab : "notes.text")
    }

    var body: some View {
        GeometryReader { geo in
            let widths = SplitWidths.resolve(available: Double(geo.size.width), dividers: 1, columns: [
                .init(width: listWidth, range: 240...480),
                .init(width: 0, range: 360...(.infinity), flexible: true)
            ])
            HStack(spacing: 0) {
                noteList.frame(width: widths[0])
                SplitDivider(columnWidth: $listWidth, range: 240...480, persistKey: "agroom.notes.listWidth", direction: 1)
                Group {
                    if model.draft != nil { editor }
                    else {
                        ContentUnavailableView {
                            Label { Text(L.string("nav.notes")).font(MeetTypography.pageTitle) }
                                icon: { Image(systemName: "note.text") }
                        } description: {
                            Text(L.string("notes.empty")).readingBodyFont()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(MeetTypography.control)
        .dropDestination(for: URL.self) { urls, _ in model.importDropped(urls); return !urls.isEmpty }
        .focusedSceneValue(\.notesMenuActions, NotesMenuActions(
            enabled: !model.busy && !model.recording,
            create: { Task { await model.create() } },
            save: { Task { _ = await model.save() } },
            importFile: { model.importFile() }, export: { model.export() }))
        .task { await model.loadTranscriptionSettings() }
        .onChange(of: search, initial: true) { _, value in model.search = value }
        .task(id: ListQuery(search: model.search, archived: model.archived)) { await model.reload() }
        .onDisappear { model.leave() }
        .sheet(item: $model.pendingCleanup) { plan in NoteSourceCleanupPreview(model: model,plan: plan) }
        .sheet(item: $model.pendingMerge) { plan in NoteRecordingMergePreview(model: model,plan: plan) }
        .sheet(item: $model.pendingWorkflow) { plan in NotesWorkflowPreview(model: model, plan: plan) }
        .onChange(of: model.pendingWorkflow?.id) { if model.pendingWorkflow != nil { showingTools = false } }
        .sheet(isPresented: $model.speechPanel) { NoteSpeechPanel(model: model) }
        .sheet(item: $model.pendingFileImport) { package in NoteFileImportPreview(model: model, package: package) }
        .sheet(item: $editingTodo) { todo in NoteTodoEditor(todo: todo) { updated in
            if let index = model.draft?.todos.firstIndex(where: { $0.id == todo.id }) {
                if let updated { model.draft?.todos[index] = updated } else { model.draft?.todos.remove(at: index) }
            }
        } }
        .sheet(isPresented: Binding(get: { settingsPage != nil }, set: { if !$0 { settingsPage = nil } })) {
            VStack(spacing: 0) {
                HStack {
                    Text(L.string("notes.settings.title")).font(MeetTypography.sectionTitle)
                    Spacer()
                    Button(L.string("notes.close")) { settingsPage = nil }
                }.padding(16)
                NotesSettingsView(model: model, page: settingsPage ?? .transcription)
            }.frame(width: 680, height: 720)
        }
        .sheet(isPresented: $showingDataSettings) { SettingsView(hub: model.hub, notesModel: model, initialTab: .data).frame(width: 960, height: 720) }
        .sheet(isPresented: $showingTools) { NotesToolsView(model: model, page: .operations) }
        .sheet(item: $model.imageSelection) { item in NoteImageEditor(selection: item, save: model.saveEditedImage, pin: model.pinImage) }
        .sheet(item: Binding(get: { showingTools ? nil : model.pendingImport }, set: { model.pendingImport = $0; if $0 == nil { model.protectedPackages = [] } })) { package in NoteImportPreview(model: model, package: package) }
        .confirmationDialog(L.string("notes.media.delete.confirm"), isPresented: Binding(get: { removingMedia != nil }, set: { if !$0 { removingMedia = nil } }), titleVisibility: .visible) {
            Button(L.string("notes.delete"), role: .destructive) { if let removingMedia { model.removeMedia(removingMedia) }; removingMedia = nil }
        }
        .alert(L.string("notes.error.title"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L.string("notes.ok")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(L.string("notes.delete.confirm"), isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } }), titleVisibility: .visible) {
            if let note = deletingNote {
                Button(L.string("notes.delete"), role: .destructive) {
                    deletingNote = nil
                    Task { await model.remove(note) }
                }
            }
        } message: { Text(deletingNote?.title ?? "") }
        .confirmationDialog(L.string("notes.reminder.confirm"), isPresented: Binding(get: { reminder != nil }, set: { if !$0 { reminder = nil } }), titleVisibility: .visible) {
            if let reminder {
                Button(reminder.title) { model.sendReminder(reminder.id); self.reminder = nil }
            }
        }
    }

    private var monthGroups: [(month: Date, notes: [WorkNote])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: model.notes) { calendar.dateInterval(of: .month, for: $0.createdAt)?.start ?? $0.createdAt }
        return groups.keys.sorted(by: >).map { month in
            (month, groups[month, default: []].sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.createdAt > $1.createdAt
            })
        }
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("nav.notes")).font(MeetTypography.sectionTitle)
                Spacer()
                Button { Task { await model.create() } } label: { Image(systemName: "square.and.pencil") }.help(L.string("notes.new"))
                Button { model.captureSelection() } label: { Image(systemName: "viewfinder") }.help(L.string("notes.screenshot.selection")).disabled(model.draft == nil)
                Button { model.importFile() } label: { Image(systemName: "square.and.arrow.down") }.help(L.string("notes.import")).disabled(model.draft == nil)
                Menu {
                    Toggle(L.string("notes.archived"), isOn: $model.archived)
                    Toggle(L.string("notes.batch.select"), isOn: $batchMode)
                    Button(L.string("notes.paste.new")) { model.pasteNote() }
                    if !model.batchSelection.isEmpty {
                        Button(L.string("notes.sources.cleanup")) { model.planCleanup(ids: model.notes.filter { model.batchSelection.contains($0.id) }.map(\.id)) }
                        Button(L.string("notes.recordings.merge")) { model.planMerge() }.disabled(model.batchSelection.count < 2)
                    }
                    Button(L.string("notes.operations")) { showingTools = true }
                    Button(L.string("notes.settings.data")) { showingDataSettings = true }
                    Button(L.string("notes.settings.title")) { settingsPage = .transcription }
                    Button(L.string("notes.local.models")) { settingsPage = .models }
                    Button(L.string("notes.refresh")) { Task { await model.reload() } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.borderless).padding(14)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L.string("notes.search"), text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(L.string("notes.search.clear"))
                }
            }.font(MeetTypography.listTitle).padding(9).background(.background, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 12).padding(.bottom, 10)
            if model.archived { Label(L.string("notes.archived"), systemImage: "archivebox").font(MeetTypography.secondary).foregroundStyle(.secondary).padding(.bottom, 8) }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(monthGroups, id: \.month) { group in
                        Button {
                            if collapsedMonths.contains(group.month) { collapsedMonths.remove(group.month) }
                            else { collapsedMonths.insert(group.month) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsedMonths.contains(group.month) && model.search.isEmpty ? "chevron.right" : "chevron.down").font(MeetTypography.caption)
                                Text(group.month, format: .dateTime.year().month(.wide)).font(MeetTypography.sectionTitle)
                                Spacer()
                                Text(group.notes.count, format: .number).font(MeetTypography.secondary).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if !collapsedMonths.contains(group.month) || !model.search.isEmpty {
                            ForEach(group.notes) { note in noteRow(note) }
                        }
                    }
                    if model.hasMore { Button(L.string("notes.more")) { Task { await model.reload(more: true) } }.padding() }
                    if model.notes.isEmpty { Text(L.string("notes.empty")).font(MeetTypography.listTitle).foregroundStyle(.secondary).padding(24) }
                }.padding(.horizontal, 10)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .disabled(model.busy || model.recording)

    }

    private func noteRow(_ note: WorkNote) -> some View {
        let selected = model.draft?.id == note.id
        let status = !note.todos.isEmpty ? "notes.status.todos" : (!note.summaries.isEmpty ? "notes.status.summary" : "notes.status.raw")
        return HStack(spacing: 6) {
            if batchMode {
                Toggle(L.string("notes.batch.select"), isOn: Binding(get: { model.batchSelection.contains(note.id) }, set: {
                    if $0 { model.batchSelection.insert(note.id) } else { model.batchSelection.remove(note.id) }
                })).labelsHidden().toggleStyle(.checkbox)
            }
            Button { Task { await model.select(note) } } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: note.transcript.isEmpty ? "note.text" : "waveform")
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                        Text(note.title).font(MeetTypography.listTitle(weight: .semibold)).lineLimit(1)
                        if note.pinned { Image(systemName: "pin.fill").font(MeetTypography.caption) }
                    }
                    HStack {
                        Text(L.string(status)).font(MeetTypography.secondary.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(selected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.09), in: Capsule())
                        Spacer(minLength: 2)
                        Text(note.createdAt, format: .dateTime.month().day().hour().minute()).font(MeetTypography.secondary).opacity(0.7)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contextMenu {
                Button(L.string("notes.open")) { Task { await model.select(note) } }
                Button(L.string(note.pinned ? "notes.unpin" : "notes.pin")) { Task { await model.togglePin(note) } }
                Button(L.string(note.archived ? "notes.unarchive" : "notes.archive")) { Task { await model.toggleArchive(note) } }
                Divider()
                Button(L.string("notes.export")) { model.export(note) }
                Button(L.string("notes.sources.cleanup")) { model.planCleanup(ids: [note.id]) }
                Divider()
                Button(L.string("notes.delete"), role: .destructive) { deletingNote = note }
            }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(Color.accentColor)
                TextField(L.string("notes.title"), text: binding(\.title)).textFieldStyle(.plain).font(MeetTypography.pageTitle)
                Button(L.string("notes.save")) { Task { _ = await model.save() } }.keyboardShortcut("s", modifiers: .command)
                Menu {
                    Toggle(L.string("notes.pin"), isOn: binding(\.pinned))
                    Toggle(L.string("notes.archived"), isOn: binding(\.archived))
                    Button(L.string("notes.export")) { model.export() }
                    Button(L.string("notes.knowledge")) { model.publishKnowledge() }
                    Button(L.string("notes.sources.cleanup")) { if let id = model.draft?.id { model.planCleanup(ids: [id]) } }
                    Button(L.string("notes.print")) { model.printNote() }
                    Button(L.string("notes.screenshot")) { model.screenshot() }
                    Button(L.string("notes.transcription.settings")) { settingsPage = .transcription }
                    Button(L.string("notes.subtitles")) { model.exportSubtitles() }.disabled(model.draft?.segments.isEmpty != false)
                    Button(L.string("notes.speech.export")) { model.speechPanel = true }
                    Button(L.string("notes.title.polish")) { model.polishTitle() }
                    Button(L.string("notes.speak")) { model.speak() }
                    Divider()
                    Button(L.string("notes.delete"), role: .destructive) { deletingNote = model.draft }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize().help(L.string("notes.actions"))
            }.disabled(model.busy || model.recording).padding(16)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button(L.string(model.recording ? "notes.stop" : "notes.record"), systemImage: model.recording ? "stop.circle.fill" : "record.circle") { model.toggleRecording() }
                        .labelStyle(.iconOnly).help(L.string(model.recording ? "notes.stop" : "notes.record")).disabled(model.busy)
                    Menu {
                        Picker(L.string("notes.capture.source"), selection: $model.captureMode) {
                            ForEach(NoteCaptureMode.allCases, id: \.self) { Text(L.string("notes.capture." + $0.rawValue)).tag($0) }
                        }
                        Picker(L.string("notes.language"), selection: $model.locale) {
                            ForEach(TranscriptionService.supportedLocales, id: \.locale.identifier) { Text($0.name).tag($0.locale.identifier) }
                        }
                        Button(L.string("notes.transcription.settings")) { settingsPage = .transcription }
                    } label: { Image(systemName: "slider.horizontal.3") }.fixedSize()
                        .help(L.string("notes.transcription.settings")).disabled(model.busy || model.recording)
                    Divider().frame(height: 18)
                    Button(L.string("notes.summarize"), systemImage: "sparkles") { model.summarize() }.disabled(!canProcess)
                    Button(L.string("notes.extract"), systemImage: "checklist") { model.summarize(todos: true) }.disabled(!canProcess)
                    Button(L.string("notes.pipeline"), systemImage: "wand.and.stars") { model.enqueueWorkflow(mediaID: nil) }
                        .buttonStyle(.borderedProminent).disabled(!canProcess)
                }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            if model.recording {
                HStack {
                    Label(L.string("notes.recording"), systemImage: "record.circle").foregroundStyle(.red)
                    if model.captureMode != .system {
                        Button(L.string(model.microphoneMuted ? "notes.mic.unmute" : "notes.mic.mute")) { model.toggleMicrophoneMute() }
                    }
                }.padding(8)
            }
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text(model.transcriptionProgress ?? L.string("notes.processing")); Button(L.string("notes.cancel")) { model.cancel() } }.padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        sourceContent.id("notes.text")
                        Divider()
                        summaries.id("notes.summary")
                        Divider()
                        todos.id("notes.todos")
                    }.frame(maxWidth: 960).padding(24).frame(maxWidth: .infinity)
                }
                .onAppear { if ["notes.summary", "notes.todos"].contains(initialSection) { proxy.scrollTo(initialSection, anchor: .top) } }
            }.id(model.draft?.id)
        }.background(.background)
    }

    private var canProcess: Bool { !model.busy && !model.recording && (model.draft?.sourceText.isEmpty == false || !model.media.isEmpty) }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L.string("notes.source"), systemImage: "doc.text").font(MeetTypography.sectionTitle).foregroundStyle(.secondary)
                Spacer()
                Picker(L.string("notes.section"), selection: $tab) {
                    ForEach(["notes.text", "notes.transcript", "notes.media", "notes.visual"], id: \.self) { Text(L.string($0)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 260)
            }
            TextField(L.string("notes.tags"), text: binding(\.tags)).textFieldStyle(.plain).foregroundStyle(.secondary).disabled(model.busy || model.recording)
            if let player = model.player { NoteMediaPlayer(player: player, model: model) }
            if tab == "notes.media" {
                attachments.frame(minHeight: 180, maxHeight: 300)
            } else if tab == "notes.visual" {
                visualNotes
            } else if tab == "notes.transcript" {
                transcript.frame(minHeight: 220)
            } else {
                if let noteID = model.draft?.id {
                    ForEach(model.media.filter { ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }) { item in
                        NoteInlineImage(store: model.store, noteID: noteID, media: item, edit: { model.editImage(item) }, recognize: { model.ocr(item) })
                    }
                }
                TextEditor(text: binding(\.text)).readingBodyFont().scrollContentBackground(.hidden)
                    .frame(minHeight: 200).padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
            }
        }.disabled(model.busy || model.recording)
    }

    private var transcript: some View { NoteTranscriptView(model: model) }

    private var visualNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L.string("notes.visual"), systemImage: "film").font(MeetTypography.sectionTitle)
            if !model.frames.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.frames.enumerated()), id: \.offset) { _, frame in
                            Button { model.playSegment(frame.seconds,mediaID: model.draft?.visualMediaID) } label: {
                                VStack {
                                    if let image = NSImage(data: frame.jpeg) { Image(nsImage: image).resizable().scaledToFit().frame(width: 130,height: 78) }
                                    Text(Duration.seconds(frame.seconds).formatted(.time(pattern: .minuteSecond))).font(.caption)
                                }
                            }.buttonStyle(.plain).help(L.string("notes.transcript.seek")).disabled(!model.media.contains { $0.id == model.draft?.visualMediaID })
                        }
                    }
                }
            }
            if let text = model.draft?.visualNotes, !text.isEmpty { MarkdownView(text: text) }
            else { Text(L.string("notes.visual.empty")).foregroundStyle(.secondary) }
        }
    }

    private var summaries: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L.string("notes.summary.heading"), systemImage: "sparkles").font(MeetTypography.sectionTitle)
            if !model.partialSummary.isEmpty {
                MarkdownView(text: model.partialSummary)
            }
            if let summary = model.draft?.summaries.last {
                MarkdownView(text: summary.text, documentID: summary.id.uuidString)
                Text(summary.date, format: .dateTime.month().day().hour().minute()).font(MeetTypography.secondary).foregroundStyle(.tertiary)
                DisclosureGroup(L.string("notes.summary.history")) {
                    ForEach((model.draft?.summaries ?? []).reversed()) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.date, format: .dateTime.month().day().hour().minute()).font(MeetTypography.secondary).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { model.draft?.summaries.first { $0.id == item.id }?.text ?? item.text }, set: { value in
                                if let index = model.draft?.summaries.firstIndex(where: { $0.id == item.id }) { model.draft?.summaries[index].text = value }
                            })).readingBodyFont().frame(height: 160)
                        }.padding(.vertical, 8)
                    }
                }
            } else { Text(L.string("notes.summary.empty")).readingBodyFont().foregroundStyle(.tertiary) }
            Button(L.string("notes.settings.prompts")) { settingsPage = .prompts }

        }.disabled(model.busy || model.recording)
    }

    private var todos: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L.string("notes.todos"), systemImage: "checklist").font(MeetTypography.sectionTitle)
                if let items = model.draft?.todos, !items.isEmpty {
                    Text(L.string("notes.sent") + " \(items.filter { $0.reminderID != nil }.count)/\(items.count)")
                        .font(MeetTypography.secondary).foregroundStyle(.green).help(L.string("notes.sent"))
                }
                Spacer()
                Button { model.draft?.todos.append(NoteTodo(title: L.string("notes.newTodo"))) } label: { Image(systemName: "plus.circle") }.help(L.string("notes.addTodo")).buttonStyle(.plain)
            }
            if model.draft?.todos.isEmpty != false { Text(L.string("notes.todos.empty")).readingBodyFont().foregroundStyle(.tertiary) }
            ForEach(model.draft?.todos ?? []) { todo in
                HStack(alignment: .top, spacing: 12) {
                    Toggle(L.string("notes.todo.completed"), isOn: todoBinding(todo, \.completed, fallback: false)).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L.string("notes.newTodo"), text: todoBinding(todo, \.title, fallback: "")).textFieldStyle(.plain).readingBodyFont().fontWeight(.semibold).strikethrough(todo.completed)
                        if let notes = todo.notes, !notes.isEmpty { Text(notes).readingBodyFont().foregroundStyle(.secondary) }
                        if let quote = todo.evidenceQuote { Text(quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let seconds = todo.sourceTimestamp { Button(L.string("notes.todo.source")) { model.playSegment(seconds) }.font(.caption) }
                        if let due = todo.dueDate { Text(due, format: .dateTime.month().day().hour().minute()).font(MeetTypography.secondary).foregroundStyle(.orange) }
                        HStack {
                            if let owner = todo.owner, !owner.isEmpty { Label(owner, systemImage: "person").font(MeetTypography.secondary).foregroundStyle(.secondary) }
                            Spacer()
                            Button(L.string(todo.reminderID == nil ? "notes.reminder" : "notes.sent")) { reminder = model.draft?.todos.first { $0.id == todo.id } }.disabled(todo.reminderID != nil).controlSize(.small)
                        }
                    }
                    Button { editingTodo = model.draft?.todos.first { $0.id == todo.id } } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help(L.string("notes.todo.details"))
                }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }.disabled(model.busy || model.recording)
    }

    private func todoBinding<Value>(_ todo: NoteTodo, _ path: WritableKeyPath<NoteTodo, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { model.draft?.todos.first { $0.id == todo.id }?[keyPath: path] ?? fallback }, set: { value in
            if let index = model.draft?.todos.firstIndex(where: { $0.id == todo.id }) { model.draft?.todos[index][keyPath: path] = value }
        })
    }

    private var attachments: some View {
        List(model.media) { item in
            HStack {
                VStack(alignment: .leading) {
                    Text(item.name).font(MeetTypography.listTitle).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)).font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if OCRService.supportedExtensions.contains(URL(fileURLWithPath: item.name).pathExtension.lowercased()) {
                        Button(L.string("notes.ocr")) { model.ocr(item) }
                        Button(L.string("notes.ocr.pin")) { model.pinOCR(item) }
                        Button(L.string("notes.image.edit")) { model.editImage(item) }
                        Button(L.string("notes.visual")) { model.analyzeVisuals(item) }
                    } else if ["m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "mp4", "mov", "m4v", "aac"].contains(URL(fileURLWithPath: item.name).pathExtension.lowercased()) {
                        Button(L.string("notes.transcribe")) { model.transcribe(item) }
                        Button(L.string("notes.speakers")) { model.analyzeSpeakers(item) }.disabled(model.draft?.segments.isEmpty != false)
                        Button(L.string("notes.pipeline")) { model.enqueueWorkflow(mediaID: item.id) }
                    }
                    if ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: item.name).pathExtension.lowercased()) {
                        Button(L.string("notes.visual")) { model.analyzeVisuals(item) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize().help(L.string("notes.actions"))
                Button { model.play(item) } label: { Image(systemName: "play.circle") }.help(L.string("notes.play"))
                Button { model.exportMedia(item) } label: { Image(systemName: "square.and.arrow.up") }.help(L.string("notes.export"))
                Button(role: .destructive) { removingMedia = item } label: { Image(systemName: "trash") }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<WorkNote, T>) -> Binding<T> {
        let noteID = model.draft?.id
        let fallback = (model.draft ?? WorkNote(title: ""))[keyPath: path]
        // SwiftUI may evaluate the outgoing editor after deletion clears the draft.
        // Its bindings must also ignore late writes after another note is selected.
        return Binding(get: {
            guard model.draft?.id == noteID else { return fallback }
            return model.draft?[keyPath: path] ?? fallback
        }, set: {
            guard model.draft?.id == noteID else { return }
            model.draft?[keyPath: path] = $0
        })
    }
}

/// Loads only the selected note's image; decoding is bounded to the reading width.
private struct NoteInlineImage: View {
    let store: NoteStore?
    let noteID: UUID
    let media: NoteMedia
    let edit: () -> Void
    let recognize: () -> Void
    @State private var preview: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(media.name, systemImage: "photo").font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L.string("notes.ocr"), action: recognize)
                Button(L.string("notes.image.edit"), action: edit)
            }.controlSize(.small)
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 360).frame(maxWidth: .infinity)
            } else if failed {
                Text(L.string("notes.image.preview.error")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .task(id: media.id) {
                do {
                    guard let data = try await store?.mediaData(noteID: noteID, id: media.id), !Task.isCancelled else { return }
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1600,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { failed = true; return }
                    preview = NSImage(cgImage: cgImage, size: .zero)
                } catch { if !Task.isCancelled { failed = true } }
            }
    }
}
