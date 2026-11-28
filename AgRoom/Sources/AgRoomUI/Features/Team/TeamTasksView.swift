import SwiftUI
import AgRoomCore

// MARK: - Team Tasks View

/// 多智体协作任务板：左侧任务列表，右侧计划、子任务、验证结论与产物。
/// 只读展示；P1 不支持从任务板恢复运行中的任务。
public struct TeamTasksView: View {
    let hub: Hub
    private let space: AppSpace
    private let source: ProductRoute?
    @Environment(\.globalSearchText) private var searchText

    @State private var tasks: [TeamTaskRecord] = []
    @State private var selectedTaskID: UUID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var taskPendingDeletion: TeamTaskRecord?
    @State private var pendingApprovals: [TeamApprovalRequest] = []
    @State private var progressEntries: [TeamProgressEntry] = []
    @State private var writeRecords: [TeamWriteRecord] = []
    @State private var revertingRecordID: UUID?
    @State private var isRevertingAll = false
    @State private var revertPrompt: RevertPrompt?
    @State private var taskPendingRetry: TeamTaskRecord?
    @State private var retryingTaskID: UUID?

    private enum RevertPrompt {
        case single(TeamWriteRecord)
        case all(taskID: UUID, count: Int)
    }

    public init(hub: Hub) {
        self.init(hub: hub, source: nil)
    }

    init(hub: Hub, source: ProductRoute?) {
        self.hub = hub; self.space = hub.spaceStore.current
        self.source = source?.space == hub.spaceStore.current ? source : nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !pendingApprovals.isEmpty {
                approvalInbox
                Divider()
            }
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 310)
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source?.id) {
            if let requested = source?.taskID { selectedTaskID = requested }
            await load()
            guard !Task.isCancelled, let requested = source?.taskID else { return }
            if tasks.contains(where: { $0.id == requested }) { selectedTaskID = requested }
            else { selectedTaskID = nil; presentError(L.string("product.tasks.source_unavailable")) }
        }
        .task { await pollApprovals() }
        .task(id: selectedTaskID) {
            await loadWriteRecords()
            await loadProgress()
        }
        .confirmationDialog(
            L.string("team.delete_confirm.title"),
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let task = taskPendingDeletion { delete(task) }
                taskPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let task = taskPendingDeletion {
                Text(L.format("team.delete_confirm.message", task.goal))
            }
        }
        .confirmationDialog(
            L.string(taskPendingRetry?.retryAction == .revise ? "team.revise.confirm.title" : "team.retry.confirm.title"),
            isPresented: Binding(
                get: { taskPendingRetry != nil },
                set: { if !$0 { taskPendingRetry = nil } }
            ),
            titleVisibility: .visible,
            presenting: taskPendingRetry
        ) { task in
            Button(L.string(task.retryAction == .revise ? "team.revise" : "team.retry")) { retry(task) }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { task in
            Text(L.format(task.retryAction == .revise ? "team.revise.confirm.message" : "team.retry.confirm.message", task.goal))
            if let scope = task.plan.retryScope {
                Text(L.format("team.retry.workspace", scope.workspaceName.isEmpty ? L.string("workspace.default.name") : scope.workspaceName))
            }
        }
        .confirmationDialog(
            revertTitle,
            isPresented: Binding(
                get: { revertPrompt != nil },
                set: { if !$0 { revertPrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch revertPrompt {
            case .single(let record):
                Button(L.string("team.writes.revert"), role: .destructive) {
                    revert(record)
                    revertPrompt = nil
                }
            case .all(let taskID, _):
                Button(L.string("team.writes.revert_all"), role: .destructive) {
                    revertAll(taskID: taskID)
                    revertPrompt = nil
                }
            case nil:
                EmptyView()
            }
            Button(L.string("common.cancel"), role: .cancel) { revertPrompt = nil }
        } message: {
            switch revertPrompt {
            case .single(let record):
                Text(record.oldContent == nil
                    ? L.format("team.writes.revert_confirm.message_new", record.path)
                    : L.format("team.writes.revert_confirm.message", record.path))
            case .all(_, let count):
                Text(L.format("team.writes.revert_all_confirm.message", count))
            case nil:
                EmptyView()
            }
        }
        .alert(L.string("common.error"), isPresented: $showError) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Data

    private var store: TeamTaskStore? {
        hub.makeTeamTaskStore(for: space)
    }

    private var selectedTask: TeamTaskRecord? {
        tasks.first { $0.id == selectedTaskID }
    }

    private var filteredTasks: [TeamTaskRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tasks }
        return tasks.filter {
            $0.goal.localizedCaseInsensitiveContains(query)
                || statusText($0.status).localizedCaseInsensitiveContains(query)
        }
    }

    private func load() async {
        guard let store else {
            presentError(L.string("team.load_failed"))
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            var loaded = try await store.listTasks(limit: 200)
            let requested = source?.taskID ?? selectedTaskID
            if let requested, !loaded.contains(where: { $0.id == requested }), let older = try await store.task(id: requested) {
                loaded.append(older)
            }
            // 重启/切空间后没有本进程运行宿主的非终态任务：标记中断，不能长期显示运行中。
            for task in loaded where !task.status.isTerminal {
                let running = await TeamRunRegistry.shared.isRunning(
                    taskID: task.id, space: space
                )
                if !running {
                    try? await store.markInterrupted(id: task.id)
                }
            }
            let selectedOlder = loaded.first { $0.id == requested }
            loaded = try await store.listTasks(limit: 200)
            if let selectedOlder, !loaded.contains(where: { $0.id == selectedOlder.id }),
               let refreshed = try await store.task(id: selectedOlder.id) { loaded.append(refreshed) }
            guard !Task.isCancelled else { return }
            tasks = loaded
            if selectedTaskID == nil || !tasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = source?.taskID == nil ? tasks.first?.id : nil
            }
            await loadWriteRecords()
        } catch {
            presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
        }
    }

    private func canRetry(_ task: TeamTaskRecord) -> Bool {
        task.retryAction != nil && task.plan.retryScope != nil && !writeRecords.contains { $0.taskID == task.id }
    }

    private func retry(_ task: TeamTaskRecord) {
        guard retryingTaskID == nil, canRetry(task) else { return }
        retryingTaskID = task.id
        Task {
            defer { retryingTaskID = nil }
            do {
                let result = try await EngineAssembly.retryTeamPlan(
                    spaceStore: hub.spaceStore,
                    space: space,
                    plan: task.plan,
                    parentTaskID: task.id,
                    workspacePath: task.plan.retryScope?.directories.first?.canonicalPath ?? "",
                    revisionTitle: L.string("team.revise.subtask")
                )
                await load()
                if selectedTaskID == task.id, tasks.contains(where: { $0.id == result.taskID }) {
                    selectedTaskID = result.taskID
                }
            } catch {
                presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
            }
        }
    }

    private func delete(_ task: TeamTaskRecord) {
        guard let store else { return }
        Task {
            do {
                await TeamApprovalCenter.shared.cancel(taskID: task.id)
                // 先阻止新调用并等待运行收尾，再删除记录；避免删除后迟到回调复活任务。
                _ = await TeamRunRegistry.shared.cancel(
                    taskID: task.id, space: space
                )
                try await store.delete(id: task.id)
                // 写快照不随任务记录级联删除：仍有恢复价值的失败/未确认写历史
                // 不能被“删除任务”静默丢弃；清理需要独立的保留期与对账入口。
                writeRecords = []
                await load()
            } catch {
                presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    private var revertTitle: String {
        switch revertPrompt {
        case .single:
            return L.string("team.writes.revert_confirm.title")
        case .all:
            return L.string("team.writes.revert_all_confirm.title")
        case nil:
            return L.string("team.writes.revert_confirm.title")
        }
    }

    // MARK: - Approvals

    private var approvalInbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(L.string("team.approvals.title"), systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("\(pendingApprovals.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(pendingApprovals) { request in
                        approvalRow(request)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private func approvalRow(_ request: TeamApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(request.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(request.expiresAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(request.taskGoal)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text(request.subtaskTitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            DisclosureGroup(L.string("team.approvals.details")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.string("team.approvals.current"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(request.oldContent ?? L.string("team.approvals.new_file"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    Text(L.string("team.approvals.proposed"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(request.newContent)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.top, 4)
            }
            .font(.caption)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L.string("team.approvals.deny"), role: .destructive) {
                    resolve(request, approved: false)
                }
                .controlSize(.small)
                Button(L.string("team.approvals.approve")) {
                    resolve(request, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .meetCard()
    }

    private func resolve(_ request: TeamApprovalRequest, approved: Bool) {
        Task {
            _ = await TeamApprovalCenter.shared.resolve(
                id: request.id,
                space: request.space,
                approved: approved
            )
            await loadApprovals()
            await load()
        }
    }

    private func loadApprovals() async {
        pendingApprovals = await TeamApprovalCenter.shared.pendingRequests(
            space: space.rawValue
        )
    }

    /// 页面可见期间轮询审批请求：Worker 在中心挂起，任务板负责把决定送回去。
    private func pollApprovals() async {
        while !Task.isCancelled {
            await loadApprovals()
            await loadProgress()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("nav.team"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L.string("team.refresh"))
                .disabled(isLoading)
            }
            .padding(.horizontal, 12)
            .columnHeader()

            Divider()

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label(L.string("team.empty"), systemImage: "person.3")
                } description: {
                    Text(L.string("team.empty.desc"))
                }
            } else if filteredTasks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredTasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func taskRow(_ task: TeamTaskRecord) -> some View {
        let isSelected = selectedTaskID == task.id
        return Button {
            selectedTaskID = task.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.goal)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    StatusBadge(
                        text: statusText(task.status),
                        color: statusColor(task.status),
                        isSelected: isSelected
                    )
                    Text(task.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    Spacer(minLength: 0)
                    if let report = task.report {
                        Text("\(report.usage.tokens) tokens")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
        .contextMenu {
            Button(L.string("common.delete"), role: .destructive) {
                taskPendingDeletion = task
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let task = selectedTask {
            taskDetail(task).id(task.id)
        } else {
            ContentUnavailableView {
                Label(L.string("team.empty"), systemImage: "person.3")
            } description: {
                Text(L.string("team.empty.desc"))
            }
        }
    }

    private func taskDetail(_ task: TeamTaskRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(task)
                if !task.plan.acceptance.isEmpty {
                    acceptanceCard(task.plan.acceptance)
                }
                if let verification = task.report?.verification {
                    verificationCard(verification)
                }
                if !task.status.isTerminal, !progressEntries.isEmpty {
                    progressSection
                }
                subtasksSection(task)
                writeChangesSection(task)
                artifactsSection(task)
                issuesSection(task)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func header(_ task: TeamTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.goal)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                retryButton(task)
                StatusBadge(text: statusText(task.status), color: statusColor(task.status))
            }
            HStack(spacing: 12) {
                Label(
                    task.startedAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                if let estimated = task.report?.estimatedTokens ?? task.plan.estimatedTokens, estimated > 0 {
                    Label(
                        L.format("team.usage.estimated", estimated),
                        systemImage: "gauge"
                    )
                }
                if let report = task.report {
                    Label(
                        L.format(
                            "team.usage.value",
                            report.usage.tokens,
                            report.usage.toolCalls
                        ),
                        systemImage: "chart.bar"
                    )
                    Label(
                        String(format: "%.1fs", report.usage.duration),
                        systemImage: "clock"
                    )
                }
                Spacer(minLength: 0)
                Button(L.string("common.delete"), role: .destructive) {
                    taskPendingDeletion = task
                }
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .meetCard()
    }

    @ViewBuilder
    private func retryButton(_ task: TeamTaskRecord) -> some View {
        if canRetry(task) {
            let revises = task.retryAction == .revise
            Button {
                taskPendingRetry = task
            } label: {
                Label {
                    Text(L.string(revises ? "team.revise" : "team.retry"))
                } icon: {
                    if retryingTaskID == task.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: revises ? "pencil" : "arrow.clockwise")
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(retryingTaskID != nil)
        } else if task.retryAction != nil && task.plan.retryScope == nil {
            Text(L.string("team.retry.legacy")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func acceptanceCard(_ criteria: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.string("team.acceptance"))
                .font(.headline)
            ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                Text("• \(criterion)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private func verificationCard(_ verification: TeamVerification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L.string("team.verification"))
                    .font(.headline)
                StatusBadge(
                    text: L.string(verification.passed ? "team.verification.passed" : "team.verification.failed"),
                    color: verification.passed ? .green : .red
                )
            }
            Text(L.teamMessage(verification.summary))
                .font(.subheadline)
                .textSelection(.enabled)
            if !verification.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.string("team.verification.issues"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(verification.issues.enumerated()), id: \.offset) { _, issue in
                        Text("• \(L.teamMessage(issue))")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private func subtasksSection(_ task: TeamTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.string("team.subtasks"))
                .font(.headline)
            ForEach(task.plan.subtasks) { subtask in
                let report = task.report?.subtasks.first { $0.id == subtask.id }
                subtaskRow(subtask, report: report)
            }
        }
    }

    private func subtaskRow(
        _ subtask: TeamSubtask,
        report: TeamSubtaskReport?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(subtask.title)
                    .font(.subheadline.weight(.medium))
                StatusBadge(
                    text: report.map { outcomeText($0.outcome) } ?? L.string("team.status.pending"),
                    color: report.map { outcomeColor($0.outcome) } ?? .secondary
                )
                Spacer(minLength: 0)
                Text(subtask.role.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let report {
                Text(L.teamMessage(report.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !report.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.string("team.evidence"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(report.evidence.prefix(4).enumerated()), id: \.offset) { _, item in
                            Text("• \(item)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text(L.string("team.subtask.pending_hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.string("team.progress.title"))
                .font(.headline)
            ForEach(progressEntries) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.subtaskTitle)
                            .font(.subheadline.weight(.medium))
                        Text(entry.agentName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(entry.toolName == "starting"
                            ? L.string("team.progress.starting")
                            : entry.toolName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.updatedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .meetCard()
            }
        }
    }

    @ViewBuilder
    private func writeChangesSection(_ task: TeamTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L.string("team.writes"))
                    .font(.headline)
                Spacer(minLength: 0)
                if writeRecords.contains(where: { !$0.isReverted }) {
                    Button(isRevertingAll
                        ? L.string("team.writes.reverting")
                        : L.string("team.writes.revert_all")) {
                        revertPrompt = .all(
                            taskID: task.id,
                            count: writeRecords.filter { !$0.isReverted }.count
                        )
                    }
                    .controlSize(.small)
                    .disabled(revertingRecordID != nil || isRevertingAll)
                }
            }
            if writeRecords.isEmpty {
                Text(L.string("team.writes.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(writeRecords) { record in
                    writeRow(record)
                }
            }
        }
    }

    private func writeRow(_ record: TeamWriteRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                StatusBadge(
                    text: L.string(record.isReverted ? "team.writes.reverted" : "team.writes.available"),
                    color: record.isReverted ? .secondary : .orange
                )
            }
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            DisclosureGroup(L.string("team.writes.preview")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.string("team.writes.previous"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(record.oldContent ?? L.string("team.writes.new_file"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    Text(L.string("team.writes.current"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(record.newContent)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            if !record.isReverted {
                HStack {
                    Spacer(minLength: 0)
                    Button(revertingRecordID == record.id
                        ? L.string("team.writes.reverting")
                        : L.string("team.writes.revert")) {
                        revertPrompt = .single(record)
                    }
                    .controlSize(.small)
                    .disabled(revertingRecordID != nil || isRevertingAll)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private func loadProgress() async {
        guard let taskID = selectedTaskID else {
            progressEntries = []
            return
        }
        progressEntries = await TeamProgressCenter.shared.progress(taskID: taskID)
    }

    private func loadWriteRecords() async {
        guard let taskID = selectedTaskID, let store = hub.makeTeamWriteStore(for: space) else {
            writeRecords = []
            return
        }
        do {
            let records = try await store.records(taskID: taskID)
            guard !Task.isCancelled, selectedTaskID == taskID else { return }
            writeRecords = Array(records.reversed())
        } catch {
            guard !Task.isCancelled, selectedTaskID == taskID else { return }
            writeRecords = []
            presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
        }
    }

    private func revert(_ record: TeamWriteRecord) {
        guard let store = hub.makeTeamWriteStore(for: space) else { return }
        revertingRecordID = record.id
        Task {
            do {
                _ = try await TeamWriteRevertService(store: store).revert(record)
                await loadWriteRecords()
                await load()
            } catch {
                await loadWriteRecords()
                presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
            }
            revertingRecordID = nil
        }
    }

    private func revertAll(taskID: UUID) {
        guard let store = hub.makeTeamWriteStore(for: space) else { return }
        isRevertingAll = true
        Task {
            do {
                _ = try await TeamWriteRevertService(store: store).revertAll(taskID: taskID)
                await loadWriteRecords()
                await load()
            } catch {
                // Applying an already-preflighted batch can fail partway through.
                // Show the persisted per-file states before explaining what remains.
                await loadWriteRecords()
                presentError(L.actionableError(error, fallbackKey: "error.actionable.team"))
            }
            isRevertingAll = false
        }
    }

    @ViewBuilder
    private func artifactsSection(_ task: TeamTaskRecord) -> some View {
        let artifacts = task.report?.artifacts ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text(L.string("team.artifacts"))
                .font(.headline)
            if artifacts.isEmpty {
                Text(L.string("team.artifacts.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(artifacts) { artifact in
                    DisclosureGroup {
                        Text(artifact.excerpt(maxCharacters: 8_000))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Text("[\(artifact.kind)]")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(artifact.title)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 0)
                            Text(artifact.producer)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .meetCard()
                }
            }
        }
    }

    @ViewBuilder
    private func issuesSection(_ task: TeamTaskRecord) -> some View {
        let report = task.report
        if let report, !report.openQuestions.isEmpty || !report.errors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !report.openQuestions.isEmpty {
                    Text(L.string("team.open_questions"))
                        .font(.headline)
                    ForEach(Array(report.openQuestions.enumerated()), id: \.offset) { _, question in
                        Text("• \(question)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                if !report.errors.isEmpty {
                    Text(L.string("team.errors"))
                        .font(.headline)
                    ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                        Text("• \(L.teamMessage(error))")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if task.retryAction == .revise {
                        retryButton(task)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .meetCard()
        }
    }

    // MARK: - Labels

    private func statusText(_ status: TeamTaskStatus) -> String {
        L.string("team.status.\(status.rawValue)")
    }

    private func statusColor(_ status: TeamTaskStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .running: return .blue
        case .waitingForUser, .waitingForApproval: return .orange
        case .verifying: return .purple
        case .cancelling: return .orange
        case .interrupted: return .orange
        case .planning: return .secondary
        }
    }

    private func outcomeText(_ outcome: TeamSubtaskOutcome) -> String {
        L.string("team.outcome.\(outcome.rawValue)")
    }

    private func outcomeColor(_ outcome: TeamSubtaskOutcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .needsInput: return .orange
        case .blocked: return .orange
        case .failed: return .red
        }
    }
}
