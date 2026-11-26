import AppKit
import Combine
import SwiftUI
import AgRoomCore

typealias TaskCenterDaemonSnapshot = (Set<UUID>, [LocatedDaemonRecord], [UUID: [OperationJournal.Entry]])

private struct TaskHistoryClearRequest {
    let space: AppSpace
    let item: ProductTaskCenterItem?
}

struct TaskCenterPanel: View {
    let hub: Hub
    @Bindable var model: ChatViewModel
    var jobCenter: JobCenter = .shared
    var initialJobID: UUID? = nil
    var handoffStore: DaemonHandoffStore = .standard
    var daemonSnapshot: @Sendable (AppSpace) async -> TaskCenterDaemonSnapshot = { space in
        await Task.detached {
            let store = DaemonHandoffStore.standard
            let all = store.records(in: space)
            let activeIDs = store.isDaemonAlive() ? Set(all.filter { $0.record.state.isActionable }.compactMap { $0.record.settings.taskAuthorization?.runID }) : []
            let recovery = all.filter { if case .recoveryRequired = $0.record.state { return true }; return false }
            var unresolved: [UUID: [OperationJournal.Entry]] = [:]
            for located in recovery where unresolved[located.record.id] == nil {
                unresolved[located.record.id] = OperationJournal(
                    directory: store.runDirectory(id: located.record.id, origin: located.origin))
                    .unresolvedEntries()
            }
            return (activeIDs, recovery, unresolved)
        }.value
    }
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ProductTaskCenterItem] = []
    @State private var jobs: [BackgroundJob] = []
    @State private var group: ProductTaskGroup?
    @State private var source: ProductTaskSource?
    @State private var search = ""
    @State private var selected: ProductTaskCenterItem?
    @State private var hasMore = false
    @State private var loading = false
    @State private var generation = UUID()
    @State private var recoveries: [LocatedDaemonRecord] = []
    @State private var quarantinedEvidence: [DaemonHandoffStore.QuarantinedEvidence] = []
    @State private var scopedUnknownEvidence: [DaemonHandoffStore.QuarantinedEvidence] = []
    @State private var hasUnattributedEvidence = false
    @State private var duplicateRecordIDs: [UUID] = []
    @State private var unresolved: [UUID: [OperationJournal.Entry]] = [:]
    @State private var abandoning: LocatedDaemonRecord?
    @State private var abandoningEvidence: DaemonHandoffStore.QuarantinedEvidence?
    @State private var inspectingScopedEvidence: DaemonHandoffStore.QuarantinedEvidence?
    @State private var abandoningScopedEvidence: DaemonHandoffStore.QuarantinedEvidence?
    @State private var historyClearRequest: TaskHistoryClearRequest?
    @State private var clearingHistory = false
    @State private var clearFeedback: String?
    @State private var archivedLegacyJobs = false
    @State private var errorText: String?
    @State private var showingArtifacts = false
    @State private var showingGoals = false
    private let pageSize = 40

    private var filterKey: String { "\(model.space.rawValue):\(group?.rawValue ?? "all"):\(source?.rawValue ?? "all"):\(search):\(model.showHiddenSessions)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("product.tasks")).font(.title2.bold())
                Text(L.string(model.space.nameKey)).foregroundStyle(model.space.tint)
                Spacer()
                Button(L.string("goal.library")) { showingGoals = true }
                Button(L.string("product.artifact.library")) { showingArtifacts = true }
                Button(L.string("common.refresh")) { Task { await load(reset: true) } }.disabled(loading)
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(L.string("product.tasks.group"), selection: $group) {
                Text(L.string("product.tasks.all")).tag(Optional<ProductTaskGroup>.none)
                ForEach(ProductTaskGroup.allCases, id: \.self) { value in
                    Text(L.string("product.tasks.group." + value.rawValue)).tag(Optional(value))
                }
            }.pickerStyle(.segmented)
            HStack {
                TextField(L.string("product.tasks.search"), text: $search)
                    .accessibilityIdentifier("product.tasks.search")
                Picker(L.string("product.tasks.source"), selection: $source) {
                    Text(L.string("product.tasks.all_sources")).tag(Optional<ProductTaskSource>.none)
                    ForEach(ProductTaskSource.allCases, id: \.self) { value in
                        Text(L.string("product.tasks.source." + value.rawValue)).tag(Optional(value))
                    }
                }.frame(width: 220)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if (group == nil || group == .attention) && (source == nil || source == .chat) && search.isEmpty {
                        ForEach(recoveries, id: \.record.id) { record in recoveryRow(record) }
                        ForEach(quarantinedEvidence) { evidence in quarantinedRow(evidence) }
                        ForEach(scopedUnknownEvidence) { evidence in scopedEvidenceRow(evidence) }
                        ForEach(duplicateRecordIDs, id: \.self) { id in duplicateEvidenceRow(id) }
                        if hasUnattributedEvidence {
                            Label(L.string("product.recovery.global.settings_hint"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    ForEach(items) { item in taskRow(item); Divider() }
                    if items.isEmpty && recoveries.isEmpty && quarantinedEvidence.isEmpty &&
                        scopedUnknownEvidence.isEmpty && duplicateRecordIDs.isEmpty &&
                        !hasUnattributedEvidence && !loading {
                        Text(L.string("product.tasks.empty")).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    if hasMore {
                        Button(L.string("product.tasks.more")) { Task { await load(reset: false) } }.disabled(loading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if loading || clearingHistory { ProgressView().controlSize(.small) }
                Text(L.string("product.tasks.history.help")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L.string("product.tasks.clear_finished")) {
                    historyClearRequest = .init(space: model.space, item: nil)
                }
                .controlSize(.small).disabled(loading || clearingHistory)
            }
            if let clearFeedback { Text(clearFeedback).foregroundStyle(.secondary).font(.caption) }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }.padding(20).frame(width: 720, height: 640)
        .task(id: filterKey) {
            items = []; recoveries = []; quarantinedEvidence = []; scopedUnknownEvidence = []
            duplicateRecordIDs = []
            hasUnattributedEvidence = false
            unresolved = [:]; hasMore = false
            do { try await Task.sleep(for: .milliseconds(180)); await load(reset: true) } catch {}
        }
        .task(id: initialJobID) {
            guard let initialJobID else { return }
            do {
                guard let store = hub.makeJobRunStore(for: model.space) else { throw SpaceSearchError.unavailable }
                let saved = try await store.run(id: initialJobID)
                let live = jobCenter.snapshot(space: model.space).first { $0.id == initialJobID && $0.state != .interrupted }
                guard !Task.isCancelled, hub.spaceStore.current == model.space else { return }
                guard let job = live ?? saved else { throw SpaceSearchError.missing }
                selected = .job(job)
            } catch { if !Task.isCancelled { errorText = L.errorDescription(error) } }
        }
        .task(id: model.space) {
            let space = model.space
            for await values in jobCenter.stream(space: space) {
                guard !Task.isCancelled, model.space == space else { break }
                jobs = values
                if !loading && !clearingHistory && items.count <= pageSize { await load(reset: true) }
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                if !loading && !clearingHistory && items.count <= pageSize { await load(reset: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProductTaskRunStore.didChange)
            .merge(with: NotificationCenter.default.publisher(for: ProductTaskCenterStore.didChange))
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            if !loading && !clearingHistory && items.count <= pageSize { Task { await load(reset: true) } }
        }
        .sheet(item: $selected) { item in
            ProductTaskDetailView(hub: hub, model: model, item: item, job: item.source == .job ? jobs.first { $0.id == item.sourceID } : nil, jobCenter: jobCenter,
                onJobUpdated: { job in
                    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                    let updated = ProductTaskCenterItem.job(job)
                    if let group, group != updated.status.taskGroup { items.remove(at: index) }
                    else { items[index] = updated }
                }, onOpenIndexSettings: {
                    let space = model.space
                    guard hub.spaceStore.current == space else { return }
                    ProductRoute.post(.init(space: space, page: HubNavItem.settings.rawValue, settingsTab: .knowledge))
                    dismiss()
                }) {
                openSource(item)
            } onReuse: { run in
                let workspace = model.taskWorkspace(id: run.workspaceID)
                ProductRoute.open(space: model.space, page: "chat", draft: run.prompt, workspaceID: workspace?.id, draftMode: run.mode)
                dismiss()
            } onContinue: { artifact, run in
                continueArtifact(artifact, run: run)
            } onContinueSnapshot: { artifact, run, url in
                continueArtifact(artifact, run: run, snapshot: url)
            } onFollowUp: { draft in
                let workspace = model.taskWorkspace(id: item.workspaceID)
                ProductRoute.open(space: model.space, page: "chat", draft: draft, workspaceID: workspace?.id, draftMode: item.mode)
                dismiss()
            }
        }
        .sheet(isPresented: $showingArtifacts) {
            if let store = hub.makeArtifactStore(for: model.space) {
                ArtifactLibraryView(store: store, includeHidden: model.showHiddenSessions,
                    roots: { model.taskWorkspace(id: $0.workspaceID)?.folderURLs ?? [] },
                    onOpenSource: { record in
                        let space = model.space
                        Task {
                            let run = try? await hub.makeTaskRunStore(for: space)?.run(id: record.runID)
                            let message = run?.sessionID == record.sessionID ? run?.messageID : nil
                            ProductRoute.open(space: space, page: "chat", sessionID: record.sessionID, messageID: message)
                            showingArtifacts = false; dismiss()
                        }
                    },
                    onUse: { record in Task { await model.recordProductEvent(.artifactUsed, taskID: record.runID) } },
                    onContinue: { artifact, url, record in
                        let space = model.space
                        Task {
                            guard await model.prepareArtifactContinuation(artifact, sessionID: record.sessionID,
                                workspaceID: record.workspaceID, snapshot: url, store: store) else { return }
                            ProductRoute.open(space: space, page: "chat", sessionID: model.activeSessionId)
                            showingArtifacts = false; dismiss()
                        }
                    })
            } else { Text(L.string("error.database")).padding() }
        }
        .sheet(isPresented: $showingGoals) {
            if let store = hub.makeGoalStore(for: model.space) {
                GoalsPanel(store: store, includeHidden: model.showHiddenSessions) { goal in
                    guard hub.spaceStore.current == model.space else { return }
                    ProductRoute.open(space: model.space, page: "chat", sessionID: goal.sessionID)
                    showingGoals = false; dismiss()
                }
            } else { Text(L.string("error.database")).padding() }
        }
        .confirmationDialog(L.string(historyClearRequest?.item == nil ? "product.tasks.clear_finished" : "product.tasks.clear_one"),
            isPresented: Binding(get: { historyClearRequest != nil }, set: { if !$0 { historyClearRequest = nil } }),
            titleVisibility: .visible, presenting: historyClearRequest) { request in
            Button(L.string(request.item == nil ? "product.tasks.clear_finished" : "product.tasks.clear_one"), role: .destructive) {
                Task { await clearHistory(request) }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { request in
            if let item = request.item {
                Text(L.format("product.tasks.clear_one.help", item.title.isEmpty ? L.string("chat.new") : item.title))
            } else {
                Text(L.string("product.tasks.clear_finished.help"))
            }
        }
        .confirmationDialog(L.string("product.recovery.abandon"), isPresented: Binding(get: { abandoning != nil }, set: { if !$0 { abandoning = nil } })) {
            Button(L.string("product.recovery.abandon"), role: .destructive) {
                guard let located = abandoning else { return }
                let record = located.record
                abandoning = nil
                let originalSpace = model.space
                Task {
                    do {
                        guard record.space == originalSpace, hub.spaceStore.current == originalSpace,
                              let service = hub.makeSessionService(for: originalSpace) else { throw ProductTaskHistoryError.invalidRecord }
                        let before = try await service.getMessagesDetailed(id: record.sessionId)
                        guard before.health == .healthy,
                              let original = before.messages.first(where: { $0.id == record.assistantMessageId }),
                              record.settings.taskAuthorization?.runID == nil ||
                                original.taskRun?.id == record.settings.taskAuthorization?.runID,
                              hub.spaceStore.current == originalSpace else { throw ProductTaskHistoryError.invalidRecord }
                        try await service.updateMessage(sessionId: record.sessionId, messageId: record.assistantMessageId,
                            expectedTaskRunID: original.taskRun?.id, clearPendingForMessage: true) { $0.runStatus = .cancelled }
                        let after = try await service.getMessagesDetailed(id: record.sessionId)
                        guard after.health == .healthy,
                              after.messages.first(where: { $0.id == record.assistantMessageId })?.runStatus == .cancelled,
                              after.pendingConfirmation == nil, after.pendingQuestion == nil,
                              hub.spaceStore.current == originalSpace else { throw ProductTaskHistoryError.invalidRecord }
                        let handoffStore = handoffStore
                        let resolved = await Task.detached { handoffStore.abandonRecovery(id: record.id, space: record.space) }.value
                        guard resolved else { throw ProductTaskHistoryError.invalidRecord }
                        guard model.space == originalSpace, hub.spaceStore.current == originalSpace else { return }
                        await model.refreshFromDatabase()
                        await load(reset: true)
                    } catch {
                        if model.space == originalSpace, hub.spaceStore.current == originalSpace {
                            errorText = L.string("product.recovery.failed")
                        }
                    }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.recovery.abandon.help")) }
        .confirmationDialog(L.string("product.recovery.abandon"), isPresented: Binding(get: { abandoningEvidence != nil }, set: { if !$0 { abandoningEvidence = nil } })) {
            Button(L.string("product.recovery.abandon"), role: .destructive) {
                guard let evidence = abandoningEvidence else { return }
                abandoningEvidence = nil
                let originalSpace = model.space
                let store = handoffStore
                let service = evidence.space == originalSpace ? hub.makeSessionService(for: originalSpace) : nil
                Task {
                    let resolved = await store.abandonQuarantinedEvidence(evidence,
                        space: originalSpace, sessionService: service)
                    guard !Task.isCancelled, model.space == originalSpace, hub.spaceStore.current == originalSpace else { return }
                    if resolved {
                        await model.refreshFromDatabase()
                        await load(reset: true)
                    } else { errorText = L.string("product.recovery.failed") }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.recovery.quarantined.abandon_help")) }
        .confirmationDialog(L.string("product.recovery.global.title"), isPresented: Binding(get: { inspectingScopedEvidence != nil }, set: { if !$0 { inspectingScopedEvidence = nil } })) {
            Button(L.string("product.recovery.global.open")) {
                guard let evidence = inspectingScopedEvidence else { return }
                inspectingScopedEvidence = nil
                let currentSpace = model.space
                guard hub.spaceStore.current == currentSpace,
                      evidence.origin == .space(currentSpace) else { return }
                openEvidenceCopy(evidence, in: currentSpace)
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.recovery.global.help")) }
        .confirmationDialog(L.string("product.recovery.abandon"), isPresented: Binding(get: { abandoningScopedEvidence != nil }, set: { if !$0 { abandoningScopedEvidence = nil } })) {
            Button(L.string("product.recovery.abandon"), role: .destructive) {
                guard let evidence = abandoningScopedEvidence else { return }
                abandoningScopedEvidence = nil
                let currentSpace = model.space
                guard hub.spaceStore.current == currentSpace,
                      evidence.origin == .space(currentSpace) else { return }
                let store = handoffStore
                Task {
                    let resolved = await Task.detached {
                        store.abandonUnattributedEvidence(evidence, in: currentSpace)
                    }.value
                    guard model.space == currentSpace,
                          hub.spaceStore.current == currentSpace else { return }
                    if resolved {
                        await model.refreshFromDatabase()
                        await load(reset: true)
                    } else { errorText = L.string("product.recovery.failed") }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.recovery.global.abandon_help")) }
    }

    private func taskRow(_ item: ProductTaskCenterItem) -> some View {
        let jobState = item.source == .job ? BackgroundJob.State(rawValue: item.sourceStatus) : nil
        let needsJobAction = item.source == .job && item.status == .recoveryRequired
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title.isEmpty ? L.string("chat.new") : item.title).font(.headline).lineLimit(2)
                Spacer()
                Label(jobState?.taskCenterLabel ?? item.status.label, systemImage: item.status.icon).font(.caption)
                    .foregroundStyle(item.status.taskGroup == .attention ? .orange : .secondary)
            }
            HStack {
                Text(L.string("product.tasks.source." + item.source.rawValue))
                Text(item.startedAt, format: .dateTime.year().month().day().hour().minute())
            }.font(.caption).foregroundStyle(.secondary)
            if !item.preview.isEmpty { Text(item.preview).font(.callout).lineLimit(3).textSelection(.enabled) }
            HStack {
                Button(L.string(needsJobAction ? "jobs.history.handle" : "product.tasks.details")) { selected = item }
                    .accessibilityIdentifier("product.tasks.details." + item.id)
                Button(L.string("product.tasks.open_source")) { openSource(item) }
                    .accessibilityIdentifier("product.tasks.source." + item.id)
                if item.source == .job, let job = jobs.first(where: { $0.id == item.sourceID }), job.isActive {
                    Button(L.string("jobs.cancel")) { jobCenter.cancel(id: job.id) }
                }
                if item.canClearHistory {
                    Spacer()
                    Button(L.string("product.tasks.clear_one")) {
                        historyClearRequest = .init(space: model.space, item: item)
                    }
                    .accessibilityIdentifier("product.tasks.clear." + item.id)
                    .disabled(clearingHistory)
                }
            }.controlSize(.small)
        }
    }

    private func openSource(_ item: ProductTaskCenterItem) {
        ProductRoute.post(.source(item, space: model.space))
        dismiss()
    }

    private func continueArtifact(_ artifact: TaskArtifact, run: ProductTaskRun, snapshot: URL? = nil) {
        let space = model.space
        Task {
            guard await model.prepareArtifactContinuation(artifact, sessionID: run.sessionID, workspaceID: run.workspaceID,
                mode: run.mode, snapshot: snapshot) else { return }
            ProductRoute.open(space: space, page: "chat", sessionID: model.activeSessionId)
            dismiss()
        }
    }

    private func clearHistory(_ request: TaskHistoryClearRequest) async {
        let space = request.space
        guard !clearingHistory, model.space == space, hub.spaceStore.current == space else { return }
        guard let store = hub.makeTaskCenterStore(for: space) else { errorText = L.string("error.database"); return }
        clearingHistory = true; clearFeedback = nil; errorText = nil
        defer { clearingHistory = false }
        do {
            let count = try await store.clearFinished(only: request.item, jobs: jobCenter.snapshot(space: space))
            guard !Task.isCancelled, model.space == space, hub.spaceStore.current == space else { return }
            await load(reset: true)
            guard !Task.isCancelled, model.space == space, hub.spaceStore.current == space else { return }
            clearFeedback = count > 0 ? L.format("product.tasks.clear_finished.result", count)
                : L.string(request.item == nil ? "product.tasks.clear_finished.none" : "product.tasks.clear_one.unavailable")
        } catch {
            guard model.space == space, hub.spaceStore.current == space else { return }
            errorText = L.string("product.tasks.clear_finished.failed")
        }
    }

    private func load(reset: Bool) async {
        guard let store = hub.makeTaskCenterStore(for: model.space) else { errorText = L.string("error.database"); return }
        let ticket = UUID(); generation = ticket; loading = true
        let space = model.space
        defer { if generation == ticket { loading = false } }
        do {
            guard let jobStore = hub.makeJobRunStore(for: space) else { throw ProductTaskHistoryError.invalidRecord }
            if !archivedLegacyJobs {
                try await jobCenter.archiveHistory(to: jobStore)
                guard model.space == space else { return }
                archivedLegacyJobs = true
            }
            let daemon = await daemonSnapshot(space)
            let handoffStore = handoffStore
            let evidence = await Task.detached {
                let ownership = handoffStore.ownershipSnapshot()
                return (handoffStore.quarantinedEvidence(in: space),
                    handoffStore.unattributedEvidence(in: space), ownership)
            }.value
            let teamIDs = await TeamRunRegistry.shared.activeTaskIDs(in: space)
            let page = try await store.page(group: group, source: source, search: search, before: reset ? nil : items.last,
                limit: pageSize, activeChatRunIDs: model.activeTaskRunIDs.union(daemon.0), activeTeamTaskIDs: teamIDs,
                activeScheduledRunIDs: ScheduledTaskCenter.shared.activeRunIDs(in: space), jobs: jobs, includeHidden: model.showHiddenSessions)
            guard !Task.isCancelled, generation == ticket, model.space == space else { return }
            if reset { items = page.items }
            else { let existing = Set(items.map(\.id)); items += page.items.filter { !existing.contains($0.id) } }
            hasMore = page.hasMore; recoveries = daemon.1; unresolved = daemon.2
            quarantinedEvidence = evidence.0
            scopedUnknownEvidence = evidence.1
            duplicateRecordIDs = Array(evidence.2.ambiguousRunIDsBySpace[space] ?? []).sorted { $0.uuidString < $1.uuidString }
            hasUnattributedEvidence = (evidence.2.unattributedSpaces.contains(space) && evidence.1.isEmpty) ||
                evidence.2.hasUnattributedQuarantine
            errorText = nil
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            errorText = L.errorDescription(error)
        }
    }

    private func recoveryRow(_ located: LocatedDaemonRecord) -> some View {
        let record = located.record
        return VStack(alignment: .leading, spacing: 8) {
            Label(L.string("product.task.recoveryRequired"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(L.string("product.recovery.help")).font(.caption)
            ForEach(unresolved[record.id] ?? [], id: \.operationID) { operation in Text(operation.toolName).font(.caption) }
            HStack {
                Button(L.string("product.task.open")) {
                    guard record.space == model.space, hub.spaceStore.current == record.space else { return }
                    ProductRoute.open(space: record.space, page: "chat", sessionID: record.sessionId,
                        messageID: record.assistantMessageId)
                    dismiss()
                }
                Button(L.string("product.recovery.records")) {
                    guard record.space == model.space, hub.spaceStore.current == record.space else { return }
                    openRecoveryJournalCopy(located)
                }
                Button(L.string("product.recovery.abandon"), role: .destructive) {
                    guard record.space == model.space, hub.spaceStore.current == record.space else { return }
                    abandoning = located
                }
            }.controlSize(.small)
        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func quarantinedRow(_ evidence: DaemonHandoffStore.QuarantinedEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("product.recovery.quarantined.title"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if let sessionID = evidence.sessionID, let session = model.session(id: sessionID) {
                Text(session.title.isEmpty ? L.string("chat.new") : session.title).font(.headline).lineLimit(2)
            } else if evidence.sessionID == nil {
                Text(L.string("product.recovery.quarantined.unknown")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L.string("product.recovery.quarantined.help")).font(.caption)
            HStack {
                if let sessionID = evidence.sessionID, evidence.space == model.space {
                    Button(L.string("product.task.open")) {
                        guard evidence.space == model.space,
                              hub.spaceStore.current == model.space else { return }
                        ProductRoute.open(space: model.space, page: "chat", sessionID: sessionID,
                            messageID: evidence.assistantMessageID)
                        dismiss()
                    }
                }
                if evidence.origin == .space(model.space) {
                    Button(L.string("product.recovery.records")) {
                        guard evidence.space == model.space,
                              evidence.origin == .space(model.space),
                              hub.spaceStore.current == model.space else { return }
                        openEvidenceCopy(evidence, in: model.space)
                    }
                }
                Button(L.string("product.recovery.abandon"), role: .destructive) {
                    guard evidence.space == model.space,
                          hub.spaceStore.current == model.space else { return }
                    abandoningEvidence = evidence
                }
            }.controlSize(.small)
        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Finder only receives a private snapshot. The Core store reopens the
    /// original through pinned directories and checks the scanned fingerprint.
    private func openEvidenceCopy(_ evidence: DaemonHandoffStore.QuarantinedEvidence,
                                  in requestedSpace: AppSpace?) {
        let displayedSpace = model.space
        guard hub.spaceStore.current == displayedSpace,
              requestedSpace == nil || requestedSpace == displayedSpace else { return }
        let store = handoffStore
        Task {
            let copy = await Task.detached(priority: .userInitiated) {
                store.inspectionCopy(of: evidence, in: requestedSpace)
            }.value
            guard model.space == displayedSpace, hub.spaceStore.current == displayedSpace else { return }
            if let copy {
                NSWorkspace.shared.activateFileViewerSelecting([copy])
            } else {
                await load(reset: true)
                guard model.space == displayedSpace,
                      hub.spaceStore.current == displayedSpace else { return }
                errorText = L.string("product.recovery.inspect_failed")
            }
        }
    }

    private func openRecoveryJournalCopy(_ located: LocatedDaemonRecord) {
        let displayedSpace = model.space
        guard located.record.space == displayedSpace,
              hub.spaceStore.current == displayedSpace else { return }
        let store = handoffStore
        Task {
            let copy = await Task.detached(priority: .userInitiated) {
                store.inspectionCopy(of: located, in: displayedSpace)
            }.value
            guard model.space == displayedSpace, hub.spaceStore.current == displayedSpace else { return }
            if let copy {
                NSWorkspace.shared.activateFileViewerSelecting([copy])
            } else {
                await load(reset: true)
                guard model.space == displayedSpace,
                      hub.spaceStore.current == displayedSpace else { return }
                errorText = L.string("product.recovery.inspect_failed")
            }
        }
    }

    private func scopedEvidenceRow(_ evidence: DaemonHandoffStore.QuarantinedEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("product.recovery.scoped.title"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(L.string("product.recovery.scoped.help")).font(.caption)
            HStack {
                Button(L.string("product.recovery.records")) {
                    guard evidence.origin == .space(model.space),
                          hub.spaceStore.current == model.space else { return }
                    inspectingScopedEvidence = evidence
                }
                Button(L.string("product.recovery.abandon"), role: .destructive) {
                    guard evidence.origin == .space(model.space),
                          hub.spaceStore.current == model.space else { return }
                    abandoningScopedEvidence = evidence
                }
            }.controlSize(.small)
        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func duplicateEvidenceRow(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("product.recovery.duplicate"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            // At least one duplicate may live in the shared legacy root.
            // Opening that directory from a space page would reveal other
            // spaces' old files, so this row is review-only.
        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
