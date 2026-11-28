import AppKit
import SwiftUI
import AgRoomCore

struct ProductTaskDetailView: View {
    let hub: Hub
    @Bindable var model: ChatViewModel
    let item: ProductTaskCenterItem
    let job: BackgroundJob?
    var jobCenter: JobCenter = .shared
    var copyResult: (String) -> Void = {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string)
    }
    var onJobUpdated: (BackgroundJob) -> Void = { _ in }
    var onOpenIndexSettings: (() -> Void)? = nil
    let onOpen: () -> Void
    let onReuse: (ProductTaskRun) -> Void
    let onContinue: (TaskArtifact, ProductTaskRun) -> Void
    let onContinueSnapshot: (TaskArtifact, ProductTaskRun, URL) -> Void
    let onFollowUp: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var run: ProductTaskRun?
    @State private var team: TeamTaskRecord?
    @State private var scheduled: ScheduledRun?
    @State private var currentJob: BackgroundJob?
    @State private var error: String?
    @State private var loading = true
    @State private var updatingJobHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title.isEmpty ? L.string("chat.new") : item.title).font(.title2.bold()).lineLimit(2)
                    Label(item.source == .scheduled ? L.string("scheduled.status." + (scheduled?.status.rawValue ?? item.sourceStatus)) : ((currentJob ?? job)?.state.taskCenterLabel ?? currentStatus.label), systemImage: currentStatus.icon).font(.callout)
                }
                Spacer()
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent(L.string("product.tasks.started")) { Text(item.startedAt, format: .dateTime.year().month().day().hour().minute().second()) }
                    if let finished = run?.finishedAt ?? team?.finishedAt ?? scheduled?.finishedAt ?? currentJob?.finishedAt ?? job?.finishedAt ?? item.finishedAt {
                        LabeledContent(L.string("product.tasks.finished")) { Text(finished, format: .dateTime.year().month().day().hour().minute().second()) }
                    }
                    if let run { chatDetails(run) }
                    if let team { teamDetails(team) }
                    if let scheduled { scheduledDetails(scheduled) }
                    if let job = currentJob ?? job { jobDetails(job) }
                    if loading { ProgressView().controlSize(.small) }
                    if let error { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L.string("product.tasks.open_source"), action: onOpen)
                if let run { Button(L.string("product.tasks.reuse_request")) { onReuse(run) } }
                Spacer()
                if let text = resultText, !text.isEmpty {
                    Button(L.string("product.tasks.copy_result")) {
                        copyResult(text)
                    }
                    Button(L.string("product.tasks.follow_up")) { followUp(text) }
                }
            }
            Text(L.string("product.tasks.reuse.help")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 650)
        .task {
            await load()
            while !Task.isCancelled && (team?.isFinished == false || scheduled?.status.isTerminal == false) {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                await load()
            }
        }
        .task {
            guard item.source == .job else { return }
            let space = model.space
            for await values in jobCenter.stream(space: space) {
                guard !Task.isCancelled, model.space == space, hub.spaceStore.current == space else { break }
                if let value = values.first(where: { $0.id == item.sourceID && $0.state != .interrupted }) {
                    currentJob = value
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProductTaskRunStore.didChange)) { _ in
            if item.source == .chat { Task { await load() } }
        }
    }

    private var currentStatus: TaskRunStatus {
        if let run { return run.status.rawValue == item.sourceStatus ? item.status : run.status }
        if let team {
            if team.status.rawValue == item.sourceStatus { return item.status }
            switch team.status {
            case .completed: return .succeeded
            case .failed: return .failed
            case .cancelled: return .cancelled
            case .interrupted: return .recoveryRequired
            case .waitingForApproval: return .waitingForConfirmation
            case .waitingForUser: return .waitingForInput
            default: return .running
            }
        }
        if let scheduled {
            if scheduled.status.rawValue == item.sourceStatus { return item.status }
            switch scheduled.status {
            case .succeeded: return .succeeded
            case .cancelled, .skipped: return .cancelled
            case .interrupted: return .recoveryRequired
            case .pending, .running: return .running
            case .failed, .missed: return .failed
            }
        }
        if let job = currentJob ?? job { return job.state.taskCenterStatus }
        return item.status
    }

    private var resultText: String? {
        if let run { return run.answer }
        if let scheduled { return scheduled.outputText ?? scheduled.errorText }
        if let report = team?.report {
            return ([report.goal] + report.subtasks.map { $0.title + "\n" + $0.summary }
                + report.artifacts.map { $0.title + "\n" + $0.content } + report.openQuestions + report.errors).joined(separator: "\n\n")
        }
        return currentJob?.resultText ?? currentJob?.errorText ?? job?.resultText ?? job?.errorText
    }

    private func chatDetails(_ run: ProductTaskRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if run.isLegacy { Text(L.string("product.tasks.legacy.help")).font(.caption).foregroundStyle(.secondary) }
            if run.contentTruncated { Text(L.string("product.tasks.truncated")).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup(L.string("product.tasks.request")) { Text(run.prompt).textSelection(.enabled) }
            if let context = run.resourceContext { RunResourceContextView(context: context) }
            Text(L.string("product.tasks.result")).font(.headline)
            Text(run.answer.isEmpty ? L.string("product.tasks.no_result") : run.answer).textSelection(.enabled)
            LabeledContent(L.string("product.tasks.tokens"), value: tokenText(run))
            if !run.trace.isEmpty {
                DisclosureGroup(L.format("product.steps", run.toolCount)) {
                    ForEach(Array(run.trace.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(entry.toolName, systemImage: entry.succeeded ? "checkmark" : "xmark")
                            Text(entry.resultFull ?? entry.resultPreview).font(.caption).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !run.artifacts.isEmpty {
                let workspace = model.taskWorkspace(id: run.workspaceID)
                TaskResultArtifactsView(artifacts: run.artifacts, roots: workspace?.folderURLs ?? [], store: hub.makeArtifactStore(for: model.space),
                    undoScope: model.editUndoScope(sessionID: run.sessionID, runID: run.isLegacy ? nil : run.id, status: run.status),
                    canConfirmUndo: model.canConfirmEditUndo, onUse: { _ in
                    Task { await model.recordProductEvent(.artifactUsed, taskID: run.id) }
                }, onContinueSnapshot: { artifact, url in
                    onContinueSnapshot(artifact, run, url)
                }) { artifact in onContinue(artifact, run) }
            }
        }
    }

    private func teamDetails(_ task: TeamTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.goal).textSelection(.enabled)
            if let report = task.report {
                if let verification = report.verification {
                    Label(L.teamMessage(verification.summary), systemImage: verification.passed ? "checkmark.shield" : "exclamationmark.shield").textSelection(.enabled)
                }
                ForEach(Array(report.subtasks.enumerated()), id: \.offset) { _, subtask in
                    DisclosureGroup(subtask.title) {
                        Text(subtask.summary).textSelection(.enabled)
                        if let error = subtask.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                }
                ForEach(report.openQuestions, id: \.self) { question in Text(question).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(report.errors, id: \.self) { text in Text(text).foregroundStyle(.orange).textSelection(.enabled) }
            } else { Text(L.string("product.tasks.no_result")).foregroundStyle(.secondary) }
        }
    }

    private func scheduledDetails(_ run: ScheduledRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = run.summary { Text(summary).font(.headline).textSelection(.enabled) }
            Text(run.outputText ?? run.errorText ?? L.string("product.tasks.no_result")).textSelection(.enabled)
            if let error = ScheduledResultText.error(run) { Text(error).font(.caption).foregroundStyle(.orange) }
            ScheduledRunInfoView(hub: hub, space: model.space, run: run)
            if run.isTerminal, !(run.outputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScheduledResultActionsView(hub: hub, space: model.space, run: run, onDraft: onFollowUp)
            }
            if !run.toolNames.isEmpty { Text(run.toolNames.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func jobDetails(_ job: BackgroundJob) -> some View {
        let openSettings = KnowledgeIndexJobs.isIndexJob(job) ? onOpenIndexSettings : nil
        return VStack(alignment: .leading, spacing: 12) {
            if job.isActive { ProgressView(value: job.progress) }
            if job.historyTruncated == true { Text(L.string("product.tasks.truncated")).font(.caption).foregroundStyle(.orange) }
            if job.state == .interrupted {
                Text(L.string(openSettings == nil ? "jobs.interrupted.help" : "jobs.interrupted.index.help"))
            } else if job.state == .awaitingSave {
                Text(L.string("jobs.history.failed"))
            }
            Text(job.errorText ?? job.resultText ?? L.string("product.tasks.no_result")).textSelection(.enabled)
            if job.isActive { Button(L.string("jobs.cancel")) { jobCenter.cancel(id: job.id) } }
            if job.state == .interrupted {
                HStack {
                    if let openSettings { Button(L.string("jobs.interrupted.index.settings"), action: openSettings) }
                    Button(L.string("jobs.interrupted.acknowledge")) { Task { await acknowledgeInterruption(job) } }
                }.disabled(loading || updatingJobHistory)
            } else if job.state == .awaitingSave {
                Button(L.string("jobs.history.retry")) { Task { await retryJobHistory(job) } }
                    .disabled(loading || updatingJobHistory)
            }
            if updatingJobHistory { ProgressView().controlSize(.small) }
            if let path = job.resultPath, job.state == .succeeded {
                Button(L.string("files.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }

    private func acknowledgeInterruption(_ job: BackgroundJob) async {
        let space = model.space
        guard !updatingJobHistory, job.space == space, hub.spaceStore.current == space else { return }
        guard let store = hub.makeJobRunStore(for: space) else { error = L.string("error.database"); return }
        updatingJobHistory = true
        error = nil
        defer { updatingJobHistory = false }
        do {
            let updated = try await store.acknowledgeInterruption(id: job.id)
            guard model.space == space, hub.spaceStore.current == space else { return }
            currentJob = updated
            onJobUpdated(updated)
        } catch {
            guard model.space == space, hub.spaceStore.current == space else { return }
            self.error = L.string("jobs.interrupted.acknowledge_failed")
        }
    }

    private func retryJobHistory(_ job: BackgroundJob) async {
        let space = model.space
        guard !updatingJobHistory, job.space == space, hub.spaceStore.current == space else { return }
        updatingJobHistory = true
        error = nil
        defer { updatingJobHistory = false }
        let saved = await jobCenter.retryHistoryPersistence(id: job.id)
        guard model.space == space, hub.spaceStore.current == space else { return }
        if saved {
            await load()
            if let currentJob, model.space == space, hub.spaceStore.current == space { onJobUpdated(currentJob) }
        } else { error = L.string("jobs.history.retry_failed") }
    }

    private func liveJob(in space: AppSpace) -> BackgroundJob? {
        jobCenter.snapshot(space: space).first { $0.id == item.sourceID && $0.state != .interrupted }
    }

    private func followUp(_ text: String) {
        onFollowUp(L.format("product.tasks.follow_up.prompt", item.title, String(text.prefix(60_000))))
    }

    private func tokenText(_ run: ProductTaskRun) -> String {
        if run.inputTokens == nil && run.outputTokens == nil { return L.string("usage.unreported") }
        return (run.inputTokens.map(String.init) ?? L.string("usage.unreported")) + " / " + (run.outputTokens.map(String.init) ?? L.string("usage.unreported"))
    }

    private func load() async {
        error = nil
        do {
            switch item.source {
            case .chat:
                run = try await hub.makeTaskRunStore(for: model.space)?.run(id: item.sourceID)
                if run == nil { error = L.string("product.tasks.missing") }
            case .team:
                team = try await hub.makeTeamTaskStore(for: model.space)?.task(id: item.sourceID)
                if team == nil { error = L.string("product.tasks.missing") }
            case .scheduled:
                scheduled = try await hub.makeScheduledRunStore(for: model.space)?.run(id: item.sourceID)
                if scheduled == nil { error = L.string("product.tasks.missing") }
            case .job:
                let space = model.space
                if let live = liveJob(in: space) {
                    currentJob = live
                } else {
                    let saved = try await hub.makeJobRunStore(for: space)?.run(id: item.sourceID)
                    guard !Task.isCancelled, model.space == space, hub.spaceStore.current == space else { return }
                    currentJob = liveJob(in: space) ?? saved ?? job
                }
                if currentJob == nil { error = L.string("product.tasks.missing") }
            }
        } catch { self.error = L.errorDescription(error) }
        loading = false
    }
}
