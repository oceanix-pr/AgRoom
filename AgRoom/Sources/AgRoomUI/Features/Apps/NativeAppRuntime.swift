import SwiftUI
import AgRoomCore

@MainActor
@Observable
final class NativeAppQueryModel {
    private(set) var items: [NativeAppKnowledgeSummary] = []
    private(set) var selectedID: UUID?
    private(set) var content = ""
    private(set) var isContentTruncated = false
    private(set) var isContentReady = false
    private(set) var selectedRecord: NativeAppRecord?
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var dataset: HostDataTable?
    private(set) var error: String?
    private var queryTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = UUID()
    private var search = ""
    let source: NativeAppDefinition.DataSource
    private let resources: NativeAppResources?
    private let preview: Bool
    var workspace: NativeAppWorkspace?

    init(source: NativeAppDefinition.DataSource, resources: NativeAppResources?, preview: Bool) {
        self.source = source; self.resources = resources; self.preview = preview
    }

    var selectedTitle: String { items.first { $0.id == selectedID }?.title ?? "" }

    func refresh(search: String, debounce: Bool = false, more: Bool = false) {
        if source.kind == .result, !preview {
            self.search = search
            let rows = dataset?.rows.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } ?? []
            items = rows.map { .init(id: $0.stableUUID, title: $0.title, preview: String($0.content.prefix(180))) }
            if let selectedID, !items.contains(where: { $0.id == selectedID }) { clearSelection() }
            isLoading = false; hasMore = false
            return
        }
        queryTask?.cancel()
        if !more {
            detailTask?.cancel(); selectedID = nil; selectedRecord = nil; content = ""; isContentTruncated = false; items = []
            isContentReady = false
        }
        self.search = search
        let requestID = UUID()
        generation = requestID
        error = nil
        guard !preview else {
            items = [NativeAppKnowledgeSummary(id: UUID(), title: L.string("apps.preview.sample.title"), preview: L.string("apps.preview.sample.body"))]
            isLoading = false; hasMore = false; return
        }
        guard source.kind == .records ? workspace != nil : resources != nil else { error = L.string("apps.error.unavailable"); return }
        isLoading = true
        let offset = more ? items.count : 0
        let limit = source.pageSize
        let source = self.source
        let workspace = self.workspace
        let resources = self.resources
        queryTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                let page: NativeAppKnowledgePage
                if source.kind == .records, let workspace {
                    page = try await workspace.recordSummaries(collection: source.collection ?? "", search: search, offset: offset, limit: limit)
                } else if let resources {
                    page = try await resources.queryKnowledge(search: search, offset: offset, limit: limit)
                } else { throw NativeAppError(.unavailable) }
                try Task.checkCancellation()
                guard let self, self.generation == requestID else { return }
                let known = Set(self.items.map(\.id))
                self.items += page.items.filter { !known.contains($0.id) }
                self.hasMore = page.hasMore && self.items.count < 500
                self.isLoading = false
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); self.isLoading = false
            }
        }
    }

    func loadMore() { guard hasMore, !isLoading else { return }; refresh(search: search, more: true) }

    func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        detailTask?.cancel()
        selectedID = id; selectedRecord = nil; content = ""; isContentTruncated = false; error = nil
        isContentReady = false
        if source.kind == .result, let row = dataset?.rows.first(where: { $0.stableUUID == id }) {
            content = row.content; isContentReady = true
            return
        }
        let requestID = generation
        if preview {
            content = L.string("apps.preview.sample.body")
            isContentReady = true
            if source.kind == .records {
                selectedRecord = NativeAppRecord(id: id, collection: source.collection ?? "", title: selectedTitle,
                    content: content, revision: 1, updatedAt: Date())
            }
            return
        }
        let source = self.source
        let resources = self.resources
        let workspace = self.workspace
        detailTask = Task { [weak self] in
            do {
                let detail: NativeAppKnowledgeDetail
                let record: NativeAppRecord?
                if source.kind == .records, let workspace {
                    let value = try await workspace.record(id: id)
                    guard value.collection == source.collection else { throw NativeAppError(.missing) }
                    record = value
                    detail = NativeAppKnowledgeDetail(content: value.content, isTruncated: false)
                } else if let resources {
                    record = nil
                    detail = try await resources.knowledgeContent(id: id)
                } else { throw NativeAppError(.unavailable) }
                try Task.checkCancellation()
                guard let self, self.generation == requestID, self.selectedID == id else { return }
                self.content = detail.content; self.isContentTruncated = detail.isTruncated; self.selectedRecord = record
                self.isContentReady = true
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == requestID, self.selectedID == id, !Task.isCancelled else { return }
                self.error = L.errorDescription(error)
            }
        }
    }

    func cancel() {
        generation = UUID(); queryTask?.cancel(); detailTask?.cancel()
        queryTask = nil; detailTask = nil; isLoading = false
    }

    func clearSelection() {
        isContentReady = false
        detailTask?.cancel(); selectedID = nil; selectedRecord = nil; content = ""; isContentTruncated = false
    }

    func replaceDataset(_ value: HostDataTable?) {
        clearSelection(); dataset = value; refresh(search: search)
    }
    func selectedField(_ key: String) -> NativeAppValue {
        dataset?.rows.first(where: { $0.stableUUID == selectedID })?.fields[key] ?? .string("")
    }
}

enum NativeAppCommandEffect {
    case savedRecord(source: String, id: UUID, collection: String, revision: Int)
    case deletedRecord(UUID)
    case script(NativeAppScriptReceipt, bindings: [String: String])
    case savedArtifact(UUID)
    case capability(HostCapabilityReceipt, source: String?, bindings: [String: String])
}

@MainActor
struct NativeAppPendingCommand: Identifiable {
    let id: UUID
    let engine: DispatcherEngine
    let title: String
    let content: String
    var titleKey = "apps.confirm.save"
    var statusKey = "apps.saved"
    var effect: NativeAppCommandEffect?
    var presentation: ToolApprovalPresentation?
    var versionApproval: NativeAppPendingVersionApproval?
}

@MainActor
struct NativeAppPendingVersionApproval {
    let id: UUID
    let engine: DispatcherEngine
}

/// One instance per window, permanently bound to its originating space and definition.
@MainActor
@Observable
final class NativeAppRuntime {
    let definition: NativeAppDefinition
    let space: AppSpace
    let preview: Bool
    let queries: [String: NativeAppQueryModel]
    private let store: NativeAppStore?
    private let resources: NativeAppResources?
    private(set) var workspace: NativeAppWorkspace?
    private(set) var filesModel: NativeAppFilesModel?
    private(set) var editors: [String: NativeAppEditingContext] = [:]
    private(set) var values: [String: NativeAppValue]
    private(set) var boardProgress: [String: NativeAppBoardProgress]
    private(set) var boardFeedback: [String: String] = [:]
    private(set) var isReady = false
    private(set) var isActive = false
    private(set) var isBusy = false
    private(set) var isDirty = false
    private(set) var pending: NativeAppPendingCommand?
    var error: String?
    private(set) var statusKey: String?
    private(set) var availableFiles: [NativeAppFile] = []
    private(set) var scriptArtifacts: [NativeAppScriptArtifact] = []
    private(set) var scriptDiagnostics = ""
    private(set) var authorizationState: NativeAppScriptAuthorizationState = .required
    var codeReviewed: Bool { authorizationState.isAuthorized }
    private(set) var authorizationGrantedAt: Date?
    private(set) var isReviewingCode = false
    private var scriptService: NativeAppScriptService?
    private let scriptReviewer: NativeAppScriptReviewer?
    private var fileQueryTask: Task<Void, Never>?
    private var loaded = false
    private var generation = UUID()
    private var operationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var commandEngine: DispatcherEngine?
    private let capabilityBridge: NativeAppCapabilityBridge?
    private(set) var connections: [MySQLConnectionConfig] = []
    private(set) var selectedResources: [String: MySQLConnectionConfig] = [:]
    private var remainingActions: [String] = []
    var mysqlConnector: MySQLConnectorService? { capabilityBridge?.mysql }
    func reloadConnections() async {
        guard !preview, let mysql = capabilityBridge?.mysql else { return }
        let requestID = generation
        do {
            let values = try await mysql.connections()
            guard isActive, generation == requestID, !Task.isCancelled else { return }
            connections = values
            let remaining = selectedResources.filter { _, selected in values.contains(selected) }
            if remaining != selectedResources {
                for query in queries.values where query.source.kind == .result { query.replaceDataset(nil) }
            }
            selectedResources = remaining
        } catch { if isActive, generation == requestID { self.error = L.errorDescription(error) } }
    }

    init(definition: NativeAppDefinition, space: AppSpace, store: NativeAppStore? = nil,
         resources: NativeAppResources? = nil, preview: Bool = false, scriptService: NativeAppScriptService? = nil,
         scriptReviewer: NativeAppScriptReviewer? = nil,
         capabilityBridge: NativeAppCapabilityBridge? = nil) {
        self.definition = definition; self.space = space; self.store = store
        self.resources = resources; self.preview = preview
        self.scriptService = scriptService
        self.scriptReviewer = scriptReviewer
        self.capabilityBridge = capabilityBridge
        values = definition.state.mapValues(\.initial)
        boardProgress = (definition.boards ?? [:]).mapValues(\.initialProgress)
        queries = Dictionary(uniqueKeysWithValues: definition.dataSources.map { key, source in
            var source = source
            if source.kind == .records, source.collection == nil { source.collection = key }
            return (key, NativeAppQueryModel(source: source, resources: resources, preview: preview))
        })
    }

    func activate() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        generation = requestID; isActive = true; error = nil
        do {
            if !loaded, !preview {
                guard let store else { throw NativeAppError(.unavailable) }
                guard store.space == space, resources == nil || resources?.space == space else { throw NativeAppError(.spaceMismatch) }
                let workspace = try await store.workspace(for: definition)
                let saved = try await workspace.loadDraft(for: definition)
                try Task.checkCancellation()
                guard generation == requestID, isActive else { return }
                self.workspace = workspace
                if definition.scripts != nil {
                    if let service = scriptService {
                        guard service.workspace.space == space, service.workspace.appID == definition.id else { throw NativeAppError(.spaceMismatch) }
                    } else { scriptService = NativeAppScriptService(workspace: workspace, reviewer: scriptReviewer) }
                }
                for query in queries.values { query.workspace = workspace }
                values.merge(saved.values) { _, saved in saved }
                boardProgress.merge(saved.boards) { _, saved in saved }
                editors = saved.editors.filter { definition.dataSources[$0.key]?.kind == .records
                    && (definition.dataSources[$0.key]?.collection ?? $0.key) == $0.value.collection }
            }
            guard generation == requestID, isActive, !Task.isCancelled else { return }
            loaded = true; isReady = true
            if let scriptService {
                let reviewed = (try? await scriptService.authorizationState(definition: definition)) ?? .unavailable
                guard generation == requestID, isActive, !Task.isCancelled else { return }
                authorizationState = reviewed
                let grantedAt = try? await scriptService.authorizationGrantedAt(definition: definition)
                guard generation == requestID, isActive, !Task.isCancelled else { return }
                authorizationGrantedAt = grantedAt
            }
            if !preview, let mysql = capabilityBridge?.mysql {
                let connections = try await mysql.connections()
                guard generation == requestID, isActive, !Task.isCancelled else { return }
                self.connections = connections
            }
            refreshAll()
            refreshFiles()
        } catch is CancellationError { }
        catch { guard generation == requestID, isActive else { return }; self.error = L.errorDescription(error) }
    }

    func retry() async {
        guard isActive, !isBusy else { return }
        error = nil
        if !isReady { await activate() }
        else if isDirty { _ = await flush() }
        else { refreshAll() }
    }

    @discardableResult
    func openFiles() -> Bool {
        guard isReady, isActive, !isBusy, let workspace else { return false }
        filesModel?.suspend()
        filesModel = NativeAppFilesModel(workspace: workspace, space: space)
        return true
    }

    func closeFiles() {
        filesModel?.suspend(); filesModel = nil
        refreshFiles()
    }

    private func refreshFiles() {
        guard !preview, isActive, let workspace, definition.manifest.dslVersion >= 2 else { return }
        fileQueryTask?.cancel()
        let requestID = generation
        fileQueryTask = Task { [weak self] in
            do {
                let files = try await workspace.files()
                guard let self, self.isActive, self.generation == requestID, !Task.isCancelled else { return }
                self.availableFiles = files
            } catch is CancellationError { }
            catch {
                guard let self, self.isActive, self.generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error)
            }
        }
    }

    func text(_ key: String) -> String { definition.text(key, language: LanguageManager.shared.activeLanguageCode) }

    func resolve(_ binding: NativeAppDefinition.Binding?) -> NativeAppValue {
        guard let binding else { return .string("") }
        if let literal = binding.literal { return literal }
        if let key = binding.state { return values[key] ?? .string("") }
        if let reference = binding.board {
            let parts = reference.split(separator: ".").map(String.init)
            guard parts.count == 2, let progress = boardProgress[parts[0]], let board = definition.boards?[parts[0]] else { return .string("") }
            switch parts[1] {
            case "moves": return .number(Double(progress.moves))
            case "won": return .bool(board.isWon(progress))
            case "canUndo": return .bool(!progress.undo.isEmpty)
            case "canRedo": return .bool(!progress.redo.isEmpty)
            default: return .string("")
            }
        }
        let parts = (binding.selection ?? "").split(separator: ".").map(String.init)
        guard parts.count == 2, let query = queries[parts[0]] else { return .string("") }
        if parts[1] == "title" { return .string(query.selectedTitle) }
        if parts[1] == "content" { return .string(query.content) }
        return query.selectedField(parts[1])
    }

    func setValue(_ value: NativeAppValue, key: String) {
        guard isReady, isActive, !isBusy,
              definition.state[key]?.initial.valueType == value.valueType, values[key] != value else { return }
        guard value.isBounded else { error = L.string("apps.error.tooLarge"); return }
        var candidate = values
        candidate[key] = value
        do {
            try validateDraft(values: candidate, editors: editors)
        } catch { self.error = L.errorDescription(error); return }
        values[key] = value
        statusKey = nil
        for query in queries.values where query.source.searchKey == key { query.refresh(search: value.string, debounce: true) }
        if !preview, definition.state[key]?.persistent == true { scheduleSave() }
    }

    private func scheduleSave() {
        guard !preview else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)); _ = await self?.flush() }
            catch { }
        }
    }

    func perform(_ actionID: String) {
        guard isReady, isActive, !isBusy else { return }
        remainingActions = []
        performAction(actionID)
    }

    func boardActionEnabled(_ actionID: String) -> Bool {
        guard let action = definition.actions[actionID], let key = action.board, let progress = boardProgress[key] else { return true }
        switch action.type {
        case .boardUndo: return !progress.undo.isEmpty
        case .boardRedo: return !progress.redo.isEmpty
        default: return true
        }
    }

    @discardableResult
    func moveBoard(_ key: String, piece: String, dx: Int, dy: Int, expected: NativeAppBoardProgress? = nil) -> Bool {
        changeBoard(key) { board, progress in
            if let expected, expected != progress { throw NativeAppError(.conflict) }
            return try board.moving(progress, piece: piece, dx: dx, dy: dy)
        }
    }

    @discardableResult
    private func changeBoard(_ key: String, transform: (NativeAppBoard, NativeAppBoardProgress) throws -> NativeAppBoardProgress) -> Bool {
        guard isReady, isActive, !isBusy, let board = definition.boards?[key], let progress = boardProgress[key] else { return false }
        do {
            let next = try transform(board, progress)
            var candidate = boardProgress
            candidate[key] = next
            try validateDraft(values: values, editors: editors, boards: candidate)
            boardProgress = candidate; boardFeedback[key] = nil; error = nil; statusKey = nil
            if next != progress, board.persistent { scheduleSave() }
            return true
        } catch let issue as NativeAppBoardError {
            boardFeedback[key] = L.string(issue.localizationKey)
        } catch { self.error = L.errorDescription(error) }
        return false
    }

    private func performAction(_ actionID: String) {
        guard isReady, isActive, !isBusy, let action = definition.actions[actionID] else { return }
        switch action.type {
        case .boardUndo, .boardRedo, .boardReset:
            guard let key = action.board else { return }
            changeBoard(key) { board, progress in
                switch action.type {
                case .boardUndo: return try board.undoing(progress)
                case .boardRedo: return try board.redoing(progress)
                default: return board.initialProgress
                }
            }
        case .sequence:
            remainingActions = action.steps ?? []
            advanceSequence()
        case .callCapability:
            prepareCapability(actionID, action: action)
        case .runPython:
            prepareScript(actionID, action: action)
        case .refresh:
            if let query = queries[action.source ?? ""] {
                query.refresh(search: query.source.searchKey.flatMap { values[$0]?.string } ?? "")
            }
        case .setState:
            if let key = action.stateKey { setValue(resolve(action.value), key: key) }
        case .transformState:
            guard let key = action.stateKey, let operation = action.operation else { return }
            do {
                let value = try NativeAppLocalActions.transform(operation, current: values[key]?.string ?? "", value: resolve(action.value))
                error = nil
                setValue(value, key: key)
            } catch let error as NativeAppLocalActionError {
                self.error = L.string(error.localizationKey)
            } catch { self.error = L.errorDescription(error) }
        case .newRecord, .editRecord:
            guard let source = action.source, let query = queries[source] else { return }
            var nextValues = values
            var nextEditors = editors
            if action.type == .editRecord {
                guard let record = query.selectedRecord else { error = L.string("apps.record.select"); return }
                for (field, key) in action.fields ?? [:] {
                    nextValues[key] = .string(field == "title" ? record.title : record.content)
                }
                nextEditors[source] = NativeAppEditingContext(record: record)
            } else {
                for key in (action.fields ?? [:]).values { nextValues[key] = definition.state[key]?.initial ?? .string("") }
                nextEditors.removeValue(forKey: source)
            }
            do {
                try validateDraft(values: nextValues, editors: nextEditors)
                values = nextValues; editors = nextEditors; statusKey = nil
                if action.type == .newRecord { query.clearSelection() }
                for query in queries.values where (action.fields ?? [:]).values.contains(query.source.searchKey ?? "") {
                    query.refresh(search: query.source.searchKey.flatMap { values[$0]?.string } ?? "", debounce: true)
                }
                scheduleSave()
            } catch { self.error = L.errorDescription(error) }
        case .saveRecord, .deleteRecord, .saveFile:
            guard !preview, let workspace else { return }
            do {
                switch action.type {
                case .saveRecord:
                    guard let source = action.source, let query = queries[source] else { return }
                    let resolved = (action.values ?? [:]).mapValues { resolve($0) }
                    let title = resolved["title"]?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let content = resolved["content"]?.string ?? ""
                    guard !title.isEmpty, title.utf8.count <= 512 else { error = L.string("apps.form.invalid"); return }
                    let collection = query.source.collection ?? source
                    let editor = editors[source]
                    let id = editor?.id ?? UUID()
                    let fields = resolved.filter { $0.key != "title" && $0.key != "content" }
                    var nextEditors = editors
                    nextEditors[source] = .init(id: id, collection: collection, revision: (editor?.revision ?? 0) + 1)
                    try validateDraft(values: values, editors: nextEditors)
                    let command = try workspace.makeSaveRecordCommand(space: space, id: id, collection: collection,
                        title: title, content: content, fields: fields, replacing: editor?.revision)
                    var detail = content
                    if !fields.isEmpty { detail += "\n\n" + String(decoding: try JSONEncoder().encode(fields), as: UTF8.self) }
                    start(command, title: title, content: detail, titleKey: "apps.record.save", statusKey: "apps.record.saved",
                        effect: .savedRecord(source: source, id: id, collection: collection, revision: (editor?.revision ?? 0) + 1))
                case .deleteRecord:
                    guard let record = queries[action.source ?? ""]?.selectedRecord else { error = L.string("apps.record.select"); return }
                    start(try workspace.makeDeleteRecordCommand(space: space, record: record), title: record.title, content: record.content,
                        titleKey: "apps.record.delete", statusKey: "apps.record.deleted", effect: .deletedRecord(record.id))
                case .saveFile:
                    let name = resolve(action.values?["name"]).string
                    let content = resolve(action.values?["content"]).string
                    start(try workspace.makeSaveFileCommand(space: space, name: name, data: Data(content.utf8)),
                        title: name, content: content, titleKey: "apps.files.save", statusKey: "apps.files.saved")
                default: break
                }
            } catch { self.error = L.errorDescription(error) }
        case .saveKnowledge:
            guard !preview, let resources else { return }
            let title = resolve(action.values?["title"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = resolve(action.values?["content"]).string
            guard !title.isEmpty, title.utf8.count <= 512, content.utf8.count <= 32 * 1024 else {
                error = L.string("apps.form.invalid"); return
            }
            do {
                let (engine, call) = try resources.makeSaveCommand(title: title, content: content)
                start((engine, call), title: title, content: content)
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func prepareScript(_ actionID: String, action: NativeAppDefinition.Action) {
        guard !preview, let scriptService else { return }
        do {
            for binding in (action.inputs ?? [:]).values {
                if let selection = binding.selection {
                    let parts = selection.split(separator: ".").map(String.init)
                    if parts.count == 2, parts[1] == "content" {
                        guard queries[parts[0]]?.isContentReady == true else { throw NativeAppScriptError(.inputUnavailable) }
                        if queries[parts[0]]?.isContentTruncated == true { throw NativeAppScriptError(.inputTruncated) }
                    }
                }
            }
            let inputs = (action.inputs ?? [:]).mapValues { resolve($0) }
            var datasets: [String: HostDataTable] = [:]
            for (key, source) in action.dataInputs ?? [:] {
                guard let value = queries[source]?.dataset else { throw NativeAppScriptError(.inputUnavailable) }
                guard !value.hasMore && value.isComplete else { throw NativeAppScriptError(.inputTruncated) }
                datasets[key] = value
            }
            var records: [String: NativeAppScriptRecordQuery] = [:]
            for (key, input) in action.recordInputs ?? [:] {
                guard let source = definition.dataSources[input.source] else { throw NativeAppError(.invalidDefinition) }
                records[key] = .init(collection: source.collection ?? input.source,
                    search: source.searchKey.flatMap { values[$0]?.string } ?? "", limit: input.limit)
            }
            var files: [String: UUID] = [:]
            for (key, binding) in action.fileInputs ?? [:] {
                guard let id = UUID(uuidString: resolve(binding).string) else { throw NativeAppError(.missing) }
                files[key] = id
            }
            let definition = self.definition
            let requestID = generation
            isBusy = true; isReviewingCode = true; error = nil; statusKey = nil; scriptDiagnostics = ""
            operationTask = Task { [weak self] in
                do {
                    let command = try await scriptService.prepare(definition: definition, actionID: actionID,
                        inputs: inputs, records: records, files: files, datasets: datasets)
                    try Task.checkCancellation()
                    guard let self, self.isActive, self.generation == requestID else { return }
                    self.isReviewingCode = false; self.authorizationState = command.authorizationState
                    let content = (command.reviewReason.map { L.string($0.localizationKey) + "\n\n" } ?? "")
                        + L.string("apps.script.authorization.definition") + "\n\n" + command.definitionJSON
                        + "\n\n" + L.string("apps.script.inputs") + "\n\n" + command.inputsJSON
                    self.start((command.engine, command.call), title: self.text(definition.manifest.nameKey), content: content,
                        titleKey: "apps.script.run", statusKey: "apps.script.completed",
                        effect: .script(command.receipt, bindings: action.resultBindings ?? [:]), presentation: command.presentation,
                        versionCommand: command.versionCommand)
                } catch is CancellationError {
                    guard let self, self.isActive, self.generation == requestID else { return }
                    self.isBusy = false; self.isReviewingCode = false; self.remainingActions = []
                    self.statusKey = "apps.script.stopped"
                }
                catch {
                    guard let self, self.isActive, self.generation == requestID, !Task.isCancelled else { return }
                    self.error = L.errorDescription(error); self.isBusy = false; self.isReviewingCode = false; self.remainingActions = []
                    await self.refreshAuthorization()
                }
            }
        } catch { self.error = L.errorDescription(error); remainingActions = [] }
    }

    func selectResource(_ slot: String, id: UUID?) {
        guard isActive, !isBusy, definition.capabilities?.values.contains(where: { $0.resource == slot }) == true else { return }
        selectedResources[slot] = connections.first { $0.id == id }
        // Results from the previous resource must never be passed to the next connection.
        for query in queries.values where query.source.kind == .result { query.replaceDataset(nil) }
    }

    private func prepareCapability(_ actionID: String, action: NativeAppDefinition.Action) {
        guard !preview, let capabilityBridge, let workspace else { error = L.string("apps.error.unavailable"); remainingActions = []; return }
        guard let capability = definition.capabilities?[action.capability ?? ""],
              let descriptor = NativeAppCapabilityCatalog.descriptor(capability) else {
            error = L.string("apps.error.invalidDefinition"); remainingActions = []; return
        }
        let connection = capability.resource.flatMap { selectedResources[$0] }
        if capability.resource != nil && connection == nil { error = L.string("apps.capability.selectResource"); remainingActions = []; return }
        let inputs = (action.inputs ?? [:]).mapValues { resolve($0) }
        if let source = action.source { queries[source]?.replaceDataset(nil) }
        let definition = definition
        let requestID = generation
        isBusy = true; error = nil; statusKey = nil
        operationTask = Task { [weak self] in
            do {
                let command = try await capabilityBridge.prepare(definition: definition, workspace: workspace,
                    actionID: actionID, inputs: inputs, connection: connection)
                try Task.checkCancellation()
                guard let self, self.isActive, self.generation == requestID else { return }
                self.start((command.engine, command.call), title: L.string(descriptor.localizationKey),
                    content: command.summary, titleKey: "apps.capability.confirm", statusKey: "apps.capability.completed",
                    effect: .capability(command.receipt, source: action.source, bindings: action.resultBindings ?? [:]))
            } catch {
                guard let self, self.isActive, self.generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); self.isBusy = false; self.remainingActions = []
            }
        }
    }

    private func advanceSequence() {
        guard !remainingActions.isEmpty, isActive, !isBusy else { return }
        let next = remainingActions.removeFirst()
        performAction(next)
        if error != nil { remainingActions = [] }
    }

    func saveArtifact(_ artifact: NativeAppScriptArtifact) {
        guard isActive, !isBusy, !preview, let workspace,
              scriptArtifacts.contains(where: { $0.id == artifact.id }) else { return }
        do {
            start(try workspace.makeSaveFileCommand(space: space, name: artifact.name, data: artifact.data),
                title: artifact.name, content: L.format("apps.script.artifact.details", artifact.data.count, artifact.sha256),
                titleKey: "apps.script.saveArtifact", statusKey: "apps.files.saved", effect: .savedArtifact(artifact.id))
        } catch { self.error = L.errorDescription(error) }
    }

    private func refreshAuthorization() async {
        guard let scriptService else { return }
        let requestID = generation
        let state = (try? await scriptService.authorizationState(definition: definition)) ?? .unavailable
        guard isActive, generation == requestID, !Task.isCancelled else { return }
        authorizationState = state
        let grantedAt = try? await scriptService.authorizationGrantedAt(definition: definition)
        guard isActive, generation == requestID, !Task.isCancelled else { return }
        authorizationGrantedAt = grantedAt
    }

    func retryCodeReview() {
        guard isActive, !isBusy, let scriptService else { return }
        isBusy = true; isReviewingCode = true; error = nil
        let requestID = generation
        let definition = self.definition
        operationTask = Task { [weak self] in
            do {
                try await scriptService.reviewCode(definition: definition)
                try Task.checkCancellation()
            } catch {
                if let self, self.generation == requestID, self.isActive, !Task.isCancelled {
                    self.error = L.errorDescription(error)
                }
            }
            guard let self, self.generation == requestID, self.isActive, !Task.isCancelled else { return }
            await self.refreshAuthorization()
            self.isBusy = false; self.isReviewingCode = false
        }
    }

    func revokeCodeAuthorization() {
        guard isActive, !isBusy, let scriptService else { return }
        isBusy = true
        let requestID = generation
        operationTask = Task { [weak self] in
            do {
                guard let self else { return }
                let command = try await scriptService.makeRevokeCommand(definition: self.definition)
                guard self.generation == requestID, self.isActive, !Task.isCancelled else { return }
                self.start((command.engine, command.call), title: self.text(self.definition.manifest.nameKey),
                    content: L.string("apps.script.authorization.revokeScope"),
                    titleKey: "apps.script.authorization.revoke", statusKey: "apps.script.authorization.revoked")
            } catch {
                guard let self, self.generation == requestID, self.isActive, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); self.isBusy = false
            }
        }
    }

    func stopOperation() {
        remainingActions = []
        generation = UUID()
        commandEngine?.revokeTaskAuthorization(); commandEngine = nil
        pending?.versionApproval?.engine.revokeTaskAuthorization()
        operationTask?.cancel(); operationTask = nil; pending = nil; isBusy = false; isReviewingCode = false
        statusKey = "apps.script.stopped"
    }

    private func validateDraft(values: [String: NativeAppValue], editors: [String: NativeAppEditingContext], boards: [String: NativeAppBoardProgress]? = nil) throws {
        try definition.validateRuntimeState(values)
        let boards = boards ?? boardProgress
        try definition.validateRuntimeBoards(boards)
        let persistent = values.filter { definition.state[$0.key]?.persistent == true }
        let draft = NativeAppDraftState(values: persistent, editors: editors,
            boards: boards.filter { definition.boards?[$0.key]?.persistent == true })
        try definition.validateSavedDraft(draft)
        let data = try draft.encoded()
        guard data.count <= NativeAppDefinition.maximumStateBytes else { throw NativeAppError(.tooLarge) }
        _ = try NativeAppDraftState.decode(data)
    }

    private func start(_ command: (DispatcherEngine, ToolCallRaw), title: String, content: String,
                       titleKey: String = "apps.confirm.save", statusKey: String = "apps.saved", effect: NativeAppCommandEffect? = nil,
                       presentation: ToolApprovalPresentation? = nil, versionCommand: NativeAppScriptVersionCommand? = nil) {
        let (engine, call) = command
        commandEngine = engine; isBusy = true; error = nil; self.statusKey = nil
        let requestID = generation
        operationTask = Task { [weak self] in
            do {
                let outcome = try await engine.executeCommand(call)
                var versionApproval: NativeAppPendingVersionApproval?
                if case .needsConfirmation = outcome, let versionCommand {
                    let versionOutcome = try await versionCommand.engine.executeCommand(versionCommand.call)
                    guard case .needsConfirmation = versionOutcome, let id = versionCommand.engine.pendingApprovalID else {
                        throw NativeAppScriptError(.reviewChanged)
                    }
                    versionApproval = .init(id: id, engine: versionCommand.engine)
                }
                if Task.isCancelled { versionCommand?.engine.revokeTaskAuthorization() }
                try Task.checkCancellation()
                guard let self, self.generation == requestID, self.isActive else {
                    engine.revokeTaskAuthorization(); versionCommand?.engine.revokeTaskAuthorization(); return
                }
                if case .needsConfirmation(_, _, _, let requirement) = outcome, let id = engine.pendingApprovalID {
                    self.pending = NativeAppPendingCommand(id: id, engine: engine, title: title, content: content,
                        titleKey: titleKey, statusKey: statusKey, effect: effect, presentation: requirement.presentation ?? presentation, versionApproval: versionApproval)
                } else {
                    await self.refreshAuthorization()
                    guard self.generation == requestID, self.isActive, !Task.isCancelled else { return }
                    await self.finish(outcome, statusKey: statusKey, effect: effect)
                }
            } catch {
                engine.revokeTaskAuthorization(); versionCommand?.engine.revokeTaskAuthorization()
                guard let self, self.generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); self.isBusy = false; self.commandEngine = nil; self.remainingActions = []
            }
        }
    }

    func decide(_ command: NativeAppPendingCommand, approved: Bool, authorizeVersion: Bool = false) {
        guard pending?.id == command.id, isActive else { return }
        guard !authorizeVersion || (approved && command.versionApproval != nil) else { return }
        pending = nil
        let selected = authorizeVersion ? command.versionApproval! : NativeAppPendingVersionApproval(id: command.id, engine: command.engine)
        if authorizeVersion { command.engine.revokeTaskAuthorization() }
        else { command.versionApproval?.engine.revokeTaskAuthorization() }
        commandEngine = selected.engine
        let requestID = generation
        operationTask = Task { [weak self] in
            do {
                let outcome = try await selected.engine.resume(.confirmed(approvalID: selected.id, approved: approved, alwaysAllow: false, persistRule: false))
                try Task.checkCancellation()
                guard let self, self.generation == requestID, self.isActive else { return }
                if approved {
                    await self.refreshAuthorization()
                    guard self.generation == requestID, self.isActive, !Task.isCancelled else { return }
                    await self.finish(outcome, statusKey: command.statusKey, effect: command.effect)
                }
                else { self.isBusy = false; self.commandEngine = nil; self.remainingActions = [] }
            } catch {
                guard let self, self.generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); self.isBusy = false; self.commandEngine = nil; self.remainingActions = []
            }
        }
    }

    private func finish(_ outcome: DispatcherOutcome, statusKey: String, effect: NativeAppCommandEffect?) async {
        if case .capability(let receipt, let source, let bindings) = effect {
            let requestID = generation
            do {
                let result = try await receipt.result()
                guard case .finished(_, _, let trace, _, _, _, _) = outcome, trace.last?.succeeded == true,
                      let workspace else { throw NativeAppError(.unavailable) }
                try await workspace.validateScriptInstallation(definition)
                guard isActive, generation == requestID, !Task.isCancelled else { return }
                var candidate = values
                for (key, output) in bindings {
                    guard let value = result.values[output] else { throw NativeAppError(.invalidDefinition) }
                    candidate[key] = value
                }
                try validateDraft(values: candidate, editors: editors)
                values = candidate
                if let source { queries[source]?.replaceDataset(result.table) }
                self.statusKey = statusKey; scheduleSave()
            } catch {
                guard isActive, generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); remainingActions = []
            }
            isBusy = false; commandEngine = nil
            if error == nil { advanceSequence() }
            return
        }
        if case .script(let receipt, let bindings) = effect {
            let requestID = generation
            do {
                let result = try await receipt.result()
                guard isActive, generation == requestID, !Task.isCancelled else { return }
                guard case .finished(_, _, let trace, _, _, _, _) = outcome, trace.last?.succeeded == true else {
                    throw NativeAppScriptError(.executionFailed)
                }
                guard let workspace else { throw NativeAppError(.unavailable) }
                try await workspace.validateScriptInstallation(definition)
                guard isActive, generation == requestID, !Task.isCancelled else { return }
                var candidate = values
                for (key, output) in bindings {
                    guard let value = result.values[output], definition.state[key]?.initial.valueType == value.valueType else {
                        throw NativeAppScriptError(.invalidResult)
                    }
                    candidate[key] = value
                }
                try validateDraft(values: candidate, editors: editors)
                values = candidate; scriptArtifacts = result.artifacts; scriptDiagnostics = result.diagnostics
                self.statusKey = statusKey; scheduleSave(); refreshAll()
            } catch {
                guard isActive, generation == requestID, !Task.isCancelled else { return }
                self.error = L.errorDescription(error); remainingActions = []
            }
            isBusy = false; commandEngine = nil
            if error == nil { advanceSequence() }
            return
        }
        isBusy = false; commandEngine = nil
        if case .finished(_, _, let trace, _, _, _, _) = outcome, trace.last?.succeeded == true {
            self.statusKey = statusKey
            switch effect {
            case .savedRecord(let source, let id, let collection, let revision):
                editors[source] = NativeAppEditingContext(id: id, collection: collection, revision: revision)
                scheduleSave()
            case .deletedRecord(let id):
                editors = editors.filter { $0.value.id != id }; scheduleSave()
            case .savedArtifact(let id): scriptArtifacts.removeAll { $0.id == id }
            case .script: break
            case .capability: break
            case nil: break
            }
            refreshAll()
            refreshFiles()
            advanceSequence()
        } else { error = L.string("apps.command.failed"); remainingActions = [] }
    }

    private func refreshAll() {
        for query in queries.values { query.refresh(search: query.source.searchKey.flatMap { values[$0]?.string } ?? "") }
    }

    /// Invalidate before cancelling: late callbacks cannot reveal data or resume actions.
    func suspend() {
        remainingActions = []; selectedResources = [:]; connections = []
        for query in queries.values where query.source.kind == .result { query.replaceDataset(nil) }
        isActive = false; generation = UUID()
        closeFiles()
        queries.values.forEach { $0.cancel() }
        commandEngine?.revokeTaskAuthorization(); commandEngine = nil
        pending?.versionApproval?.engine.revokeTaskAuthorization()
        operationTask?.cancel(); operationTask = nil; pending = nil; isBusy = false
        fileQueryTask?.cancel(); fileQueryTask = nil
        scriptArtifacts = []; scriptDiagnostics = ""; availableFiles = []; authorizationState = .required; authorizationGrantedAt = nil; isReviewingCode = false
        saveTask?.cancel(); saveTask = nil
    }

    @discardableResult
    func flush() async -> Bool {
        guard isDirty, !preview else { return true }
        guard let workspace else { error = L.string("apps.error.unavailable"); return false }
        let snapshot = values.filter { definition.state[$0.key]?.persistent == true }
        let editors = self.editors
        let boards = boardProgress.filter { definition.boards?[$0.key]?.persistent == true }
        do {
            try await workspace.saveDraft(NativeAppDraftState(values: snapshot, editors: editors, boards: boards), for: definition)
            if values.filter({ definition.state[$0.key]?.persistent == true }) == snapshot && self.editors == editors
                && boardProgress.filter({ definition.boards?[$0.key]?.persistent == true }) == boards { isDirty = false }
            return true
        } catch is CancellationError { return false }
        catch { self.error = L.errorDescription(error); return false }
    }
}
